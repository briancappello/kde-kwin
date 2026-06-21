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
#   3. updpkgsums  (regenerates checksums incl. the new tarball + our patches).
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
case "${1:-}" in
  --build-only) BUILD_ONLY=1 ;;
  --no-install) NO_INSTALL=1 ;;
  '') ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
esac

die() { echo "!! $*" >&2; exit 1; }
note() { echo "==> $*"; }

# --- 1. fetch latest upstream PKGBUILD ------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
note "Fetching latest upstream kwin PKGBUILD..."
curl -fsSL "$UPSTREAM_RAW" -o "$tmp/PKGBUILD.upstream.new" \
  || die "could not fetch upstream PKGBUILD from $UPSTREAM_RAW"

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

newver="$(. "$tmp/PKGBUILD"; echo "$pkgver-$pkgrel")"
note "Upstream target: kwin $newver"

# adopt the refreshed files (only after the overlay applied cleanly)
cp "$tmp/PKGBUILD.upstream.new" PKGBUILD.upstream
cp "$tmp/PKGBUILD" PKGBUILD

# --- 3. refresh checksums -------------------------------------------------
note "Refreshing checksums (updpkgsums)..."
updpkgsums

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
makepkg -f

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
