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
#   2b. Assert structural invariants on the overlaid result (exactly one
#      prepare(), source/sha256sums counts in step, our 4 patches wired in).
#      Context matching is blind to ADDITIVE upstream drift; without this a
#      re-added upstream prepare() would silently shadow ours (or ours theirs).
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

# --- 1c. reuse an already-built package if present -------------------------
# A previous run may have built cleanly but failed BEFORE installing (classic
# case: sudo's cached credentials expired at the publish/install step and the
# prompt timed out). makepkg only emits the final .pkg.tar.zst after a clean
# build, so its presence means "already built for this version" — no need to
# fetch/overlay/checksum/rebuild; just re-publish and install it.
prebuilt="${PKG}-${newver}-x86_64.pkg.tar.zst"
if [[ -f "$prebuilt" && "$FORCE" != 1 ]]; then
  note "Reusing already-built $prebuilt (previous run built but didn't install) — skipping rebuild. (--force to rebuild)"
  pkgfile="$prebuilt"
else

# --- 2. replay overlay; loud-fail on packaging drift ----------------------
drift_die() {
  echo "------------------------------------------------------------------" >&2
  echo "!! $1" >&2
  echo "!! Upstream changed their packaging. Review and re-overlay:" >&2
  echo "------------------------------------------------------------------" >&2
  diff -u PKGBUILD.upstream "$tmp/PKGBUILD.upstream.new" >&2 || true
  die "packaging drift — see diff above; update PKGBUILD + PKGBUILD.upstream + overlay.patch"
}

cp "$tmp/PKGBUILD.upstream.new" "$tmp/PKGBUILD"
if ! patch -p1 -d "$tmp" --no-backup-if-mismatch <overlay.patch >/dev/null 2>&1; then
  drift_die "overlay.patch did NOT apply to the new upstream PKGBUILD."
fi

# --- 2b. structural invariants on the overlaid result ---------------------
# Context matching alone only catches drift that *collides* with our hunks. It
# is blind to ADDITIVE upstream changes, and one of those fails silently:
# if upstream re-adds its own prepare() (as 6.7.4-6 did for a mesa backport),
# overlay.patch still applies, the file ends up with TWO prepare() definitions,
# bash keeps the LAST one (ours) — and upstream's backport is dropped from a
# perfectly green build. These asserts turn that into a loud stop.
note "Checking overlaid PKGBUILD invariants..."
_nprep="$(grep -c '^prepare() {' "$tmp/PKGBUILD" || true)"
[[ "$_nprep" == 1 ]] \
  || drift_die "expected exactly 1 prepare() in the overlaid PKGBUILD, found $_nprep (upstream likely added its own; merge it into ours by hand)."

# Every source entry needs a checksum; a mismatch means upstream added or
# removed a source and our appended sha256sums+=() no longer lines up.
_nsrc="$(. "$tmp/PKGBUILD"; echo "${#source[@]}")"
_nsum="$(. "$tmp/PKGBUILD"; echo "${#sha256sums[@]}")"
[[ "$_nsrc" == "$_nsum" ]] \
  || drift_die "source=() has $_nsrc entries but sha256sums has $_nsum."

# Our patches must actually be wired into source=() and applied in prepare().
# NB: the LAST source entry carries the array's closing paren, hence `)?`.
for _p in swap-gesture-fingers screen-edge-corners virtual-desktops-debug virtual-desktops-fix; do
  grep -qE "^ *$_p\.patch\)?\$" "$tmp/PKGBUILD" \
    || drift_die "local patch $_p.patch is missing from source=() after overlay."
  grep -q "patch -Np1 -F0 -i \.\./$_p\.patch\$" "$tmp/PKGBUILD" \
    || drift_die "local patch $_p.patch is never applied in prepare() after overlay."
done

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

# Name the file exactly: a `${PKG}-*` glob also matches the split
# `${PKG}-debug-*` package (makepkg's default `debug` option), and that one is
# usually written last, so "newest match" would publish the debug package.
pkgfile="$(. ./PKGBUILD; echo "${pkgname}-${pkgver}-${pkgrel}-x86_64.pkg.tar.zst")"
[[ -f "$pkgfile" ]] || die "build reported success but $pkgfile was not found"
note "Built: $pkgfile"
fi  # end reuse-vs-build

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
