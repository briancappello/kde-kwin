#!/usr/bin/env bash
# update.sh — build the patched `kwin` package, tracking upstream Arch releases.
#
# Pipeline (every step fails loudly; on any failure your currently-installed
# kwin is left untouched, because pacman -U only swaps files after a clean build):
#
#   1. Fetch the latest official Arch kwin PKGBUILD.
#   2. Replay our overlay.patch onto it. If it does NOT apply, upstream changed
#      their packaging (new dep, restructured prepare/source) -> STOP and show
#      the diff so you can re-overlay. This is the "loud" gate for packaging drift.
#      The overlay is version-agnostic: it never edits pkgver or the tarball
#      sha256 line, so routine point releases no longer trip this gate.
#   3. Refresh ONLY the upstream tarball checksum in the primary sha256sums
#      array (our overlay patch checksums live in a separate `sha256sums+=(...)`
#      that must be preserved — `updpkgsums` would clobber it, so we don't use it).
#   4. makepkg     (prepare() applies our patches with -F0 = no fuzz; a patch that
#                   no longer applies aborts the build loudly -> rebase it).
#   5. Publish to the arches-local repo and install (needs sudo).
#
# Usage:
#   ./update.sh              # fetch latest upstream, overlay, build, publish, install
#   ./update.sh --build-only # build only; skip repo publish + pacman install
#   ./update.sh --no-install # build + publish to arches-local, but don't pacman -U
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

PKG=kwin
REPO_DIR=/opt/arches-repo
REPO_DB=arches-local.db.tar.gz
UPSTREAM_RAW='https://gitlab.archlinux.org/archlinux/packaging/packages/kwin/-/raw/main/PKGBUILD'

BUILD_ONLY=0
NO_INSTALL=0
FORCE=0
for a in "$@"; do
  case "$a" in
    --build-only) BUILD_ONLY=1 ;;
    --no-install) NO_INSTALL=1 ;;
    --force) FORCE=1 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

die() { echo "!! $*" >&2; exit 1; }
note() { echo "==> $*"; }

# --- 1. fetch latest upstream PKGBUILD ------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
note "Fetching latest upstream kwin PKGBUILD..."
curl -fsSL "$UPSTREAM_RAW" -o "$tmp/PKGBUILD.upstream.new" \
  || die "could not fetch upstream PKGBUILD from $UPSTREAM_RAW"

# --- 1b. skip early if already at the latest upstream version -------------
newver="$(. "$tmp/PKGBUILD.upstream.new"; echo "$pkgver-$pkgrel")"
installed="$(pacman -Q "$PKG" 2>/dev/null | awk '{print $2}' || true)"
if [[ "$installed" == "$newver" && "$FORCE" != 1 ]]; then
  note "$PKG already at $newver (patched) — nothing to do. (--force to rebuild)"
  exit 0
fi
note "Update: ${installed:-none} -> $newver"

# --- 2. replay overlay; loud-fail on packaging drift ----------------------
cp "$tmp/PKGBUILD.upstream.new" "$tmp/PKGBUILD"
if ! patch -p1 -d "$tmp" --no-backup-if-mismatch <overlay.patch >/dev/null 2>&1; then
  echo "------------------------------------------------------------------" >&2
  echo "!! overlay.patch did NOT apply to the new upstream PKGBUILD." >&2
  echo "!! Upstream changed their packaging. Review and re-overlay:" >&2
  echo "------------------------------------------------------------------" >&2
  diff -u PKGBUILD.upstream "$tmp/PKGBUILD.upstream.new" >&2 || true
  die "packaging drift — see diff above; update PKGBUILD + PKGBUILD.upstream + overlay.patch"
fi

# adopt the refreshed files (only after the overlay applied cleanly)
cp "$tmp/PKGBUILD.upstream.new" PKGBUILD.upstream
cp "$tmp/PKGBUILD" PKGBUILD

# --- 3. refresh checksums -------------------------------------------------
# The overlay keeps two sha256sums arrays: the upstream primary array
# (tarball + 'SKIP' for the sig) and our appended `sha256sums+=(...)` for the
# local overlay patches. We deliberately DO NOT run `updpkgsums` here: it
# collapses both arrays into one and drops the `+=` line. Instead we refresh
# ONLY the tarball checksum in the primary array, leaving the sig 'SKIP' and
# our patch checksums untouched. This is what keeps the overlay version-agnostic.
note "Refreshing upstream tarball checksum (targeted; preserves split array)..."
_tarurl="$(. ./PKGBUILD; echo "${source[0]%%::*}")"
_tarfile="$(. ./PKGBUILD; echo "$pkgname-$pkgver.tar.xz")"
curl -fsSL "$_tarurl" -o "$tmp/$_tarfile" \
  || die "could not download source tarball for checksumming: $_tarurl"
_tarsum="$(sha256sum "$tmp/$_tarfile" | awk '{print $1}')"
[[ -n "$_tarsum" ]] || die "failed to compute tarball sha256"
# Replace only the first sha256sums entry (the tarball) in the primary array.
sed -i -E "0,/^sha256sums=\('[0-9a-fA-F]{64}'/s//sha256sums=('$_tarsum'/" PKGBUILD
# Sanity: the primary array must now start with our freshly computed sum.
grep -q "sha256sums=('$_tarsum'" PKGBUILD \
  || die "failed to update tarball checksum in PKGBUILD (array format changed?)"

# --- 3b. verify KDE signing keys are present (loud) -----------------------
note "Checking KDE signing keys are in the gpg keyring..."
mapfile -t keys < <(. ./PKGBUILD; printf '%s\n' "${validpgpkeys[@]}")
missing=()
for k in "${keys[@]}"; do
  gpg --list-keys "$k" >/dev/null 2>&1 || missing+=("$k")
done
if ((${#missing[@]})); then
  echo "!! Missing KDE signing keys: ${missing[*]}" >&2
  echo "   Import with:  gpg --recv-keys ${missing[*]}" >&2
  die "refusing to build without source signature verification"
fi

# --- 4. build (patches applied in prepare with -F0) -----------------------
note "Building package (makepkg)..."
# -C/--cleanbuild wipes $srcdir first: without it a stale build/CMakeCache.txt
# from the previous version aborts the build ("source does not match ... used to
# generate cache"), and old kwin-<oldver>/ trees pile up in src/.
makepkg -Cf

pkgfile="$(ls -t ${PKG}-*-x86_64.pkg.tar.zst | head -1)"
[[ -f "$pkgfile" ]] || die "build reported success but no package file found"
note "Built: $pkgfile"

if ((BUILD_ONLY)); then
  note "--build-only: stopping before publish/install."
  exit 0
fi

# --- 5. publish to arches-local + install (sudo) --------------------------
note "Publishing to arches-local ($REPO_DIR) [sudo]..."
sudo cp "$pkgfile" "$REPO_DIR/"
sudo repo-add "$REPO_DIR/$REPO_DB" "$REPO_DIR/$pkgfile"

if ((NO_INSTALL)); then
  note "--no-install: published to repo but not installing. Run: sudo pacman -U $REPO_DIR/$pkgfile"
  exit 0
fi

note "Installing (sudo pacman -U)..."
sudo pacman -U --noconfirm "$REPO_DIR/$pkgfile"

cat <<EOF

Done. Installed kwin $newver (patched) from arches-local.
  - 'IgnorePkg = kwin' in /etc/pacman.conf keeps -Syu from overwriting it.
  - Re-run this script whenever you want to pick up a new upstream release.
Restart KWin to activate:  kwin_wayland --replace &   (or log out/in)
EOF
