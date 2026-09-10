#!/usr/bin/env bash
# update.sh — build the patched `kwin` RPM, tracking upstream Fedora releases.
#
# This is the Fedora counterpart to pkg/update.sh (Arch). It exists for exactly
# the same reason: the old Fedora path in build-and-install.sh ran
# `sudo cmake --install` straight into /usr, which writes files behind rpm's
# back. rpm then no longer describes what is on disk, and the next
# `dnf upgrade kwin` silently overwrites the patched build, reverting every
# patch with no warning. (That is not hypothetical — it is what happened to the
# 6.7.0 build installed here in August, which the 6.7.4-2.fc44 update erased.)
#
# Pipeline (every step fails loudly; on any failure your currently-installed
# kwin is left untouched, because dnf only swaps files after a clean build):
#
#   1. Query Fedora for the latest official kwin SRPM; skip early if the
#      installed patched build already tracks it.
#   2. Download that SRPM. dnf verifies its Fedora signature on download.
#   3. Replay our overlay.patch onto the spec it carries. If it does NOT apply,
#      Fedora changed their packaging -> STOP and show the diff so you can
#      re-overlay. This is the "loud" gate for packaging drift, and it is the
#      direct analogue of the Arch overlay gate.
#      The overlay is version-agnostic: it only inserts PatchNNNN lines into the
#      spec's empty "## proposed patches" slot and never touches Version,
#      Release, Source0 or Fedora's own PatchN entries, so neither point
#      releases nor upstream cherry-pick churn trip this gate.
#   4. rpmbuild -bb. Our patches are applied by the spec's own `%autosetup -p1`;
#      because Fedora sets %_default_patch_fuzz to 0, a patch that no longer
#      applies aborts the build loudly -> rebase it. Same no-fuzz contract as
#      makepkg's prepare() on Arch.
#   5. Install the freshly built RPMs with dnf and re-apply a versionlock, so
#      the result is a real package that rpm tracks and `dnf upgrade` will not
#      silently replace.
#
# WHY THE BUILD IS NOT SANDBOXED: like makepkg on Arch, this builds against the
# host's installed -devel packages rather than in a clean chroot. If you want
# the chroot guarantee, build the SRPM in mock instead; see --srpm.
#
# NOTE ON SOURCE VERIFICATION: Fedora's spec ships the upstream tarball's .sig
# as Source1 but never actually calls %{gpgverify} on it, so — unlike the Arch
# path, which gates on validpgpkeys — the KDE signature is not checked here.
# What is checked is the Fedora signature on the SRPM itself, verified by dnf
# at download time. We inherit Fedora's trust model rather than inventing one.
#
# Usage:
#   ./update.sh              # fetch latest Fedora SRPM, overlay, build, install
#   ./update.sh --build-only # build only; skip the dnf install
#   ./update.sh --no-install # alias for --build-only (parity with pkg/update.sh)
#   ./update.sh --force      # rebuild even if already current
#   ./update.sh --clean      # wipe the rpmbuild tree first
#   ./update.sh --srpm       # produce a .src.rpm only (feed it to mock)
#   ./update.sh --skip-builddep  # never invoke sudo dnf builddep
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

PKG=kwin

# Appended to %dist so our build is distinguishable from Fedora's and sorts
# ABOVE it (2.fc44.kdekwin > 2.fc44), making `dnf install` an upgrade rather
# than a downgrade. A genuinely newer Fedora build (3.fc44) still sorts above
# ours, which is what we want: it means "Fedora moved on, re-run this script".
LOCAL_SUFFIX=".kdekwin"

# Fedora ships source repos disabled by default; enable them just for our queries.
SRC_REPOS=(--enablerepo=fedora-source --enablerepo=updates-source)

TOPDIR="$HERE/rpmbuild"
OVERLAY_PATCHES=(
  swap-gesture-fingers
  screen-edge-corners
  virtual-desktops-debug
  virtual-desktops-fix
)

BUILD_ONLY=0
FORCE=0
DO_CLEAN=0
SRPM_ONLY=0
SKIP_BUILDDEP=0
for a in "$@"; do
  case "$a" in
    --build-only|--no-install) BUILD_ONLY=1 ;;
    --force)                   FORCE=1 ;;
    --clean)                   DO_CLEAN=1 ;;
    --srpm)                    SRPM_ONLY=1 ;;
    --skip-builddep)           SKIP_BUILDDEP=1 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

die() { echo "!! $*" >&2; exit 1; }
note() { echo "==> $*"; }

command -v rpmbuild >/dev/null || die "rpmbuild not found — install rpm-build"
dnf builddep --help >/dev/null 2>&1 || die "'dnf builddep' unavailable — install dnf5-plugins"

if ((DO_CLEAN)); then
  note "--clean: removing $TOPDIR..."
  rm -rf "$TOPDIR"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- 1. what does Fedora currently ship? ----------------------------------
note "Querying Fedora for the latest official $PKG SRPM..."
avail="$(dnf -q repoquery "${SRC_REPOS[@]}" --arch=src --latest-limit=1 \
           --qf '%{version}-%{release}\n' "$PKG" 2>/dev/null \
         | grep -E '^[0-9]' | tail -1 || true)"
[[ -n "$avail" ]] || die "could not determine the latest $PKG SRPM from the Fedora source repos"

installed="$(rpm -q --qf '%{version}-%{release}' "$PKG" 2>/dev/null || true)"
installed_base="${installed%"$LOCAL_SUFFIX"}"

if [[ "$installed_base" == "$avail" && "$installed" == *"$LOCAL_SUFFIX" && $FORCE -ne 1 ]]; then
  note "$PKG already at $avail (patched) — nothing to do. (--force to rebuild)"
  exit 0
fi
note "Update: ${installed:-none} -> ${avail}${LOCAL_SUFFIX}"

# --- 2. fetch the official SRPM -------------------------------------------
mkdir -p "$TOPDIR"/{SOURCES,SPECS,SRPMS,RPMS,BUILD}
srpmdir="$TOPDIR/srpm"
rm -rf "$srpmdir"; mkdir -p "$srpmdir"

note "Downloading $PKG-$avail.src.rpm..."
dnf download --source "$PKG" "${SRC_REPOS[@]}" --destdir "$srpmdir" >/dev/null \
  || die "could not download the $PKG SRPM"
srpm="$(find "$srpmdir" -name "${PKG}-*.src.rpm" | head -1)"
[[ -n "$srpm" ]] || die "SRPM download reported success but no .src.rpm was found"

note "Unpacking SRPM into $TOPDIR..."
rpm -i --define "_topdir $TOPDIR" "$srpm" 2>/dev/null \
  || die "failed to unpack $srpm"

specfile="$TOPDIR/SPECS/$PKG.spec"
[[ -f "$specfile" ]] || die "SRPM did not contain $PKG.spec"

# --- 3. replay overlay; loud-fail on packaging drift ----------------------
cp "$specfile" "$tmp/kwin.spec.upstream.new"
cp "$specfile" "$tmp/kwin.spec"
if ! patch -p1 -d "$tmp" --no-backup-if-mismatch <overlay.patch >/dev/null 2>&1; then
  echo "------------------------------------------------------------------" >&2
  echo "!! overlay.patch did NOT apply to the new Fedora kwin.spec." >&2
  echo "!! Fedora changed their packaging. Review and re-overlay:" >&2
  echo "------------------------------------------------------------------" >&2
  diff -u kwin.spec.upstream "$tmp/kwin.spec.upstream.new" >&2 || true
  die "packaging drift — see diff above; update kwin.spec + kwin.spec.upstream + overlay.patch"
fi

# adopt the refreshed files (only after the overlay applied cleanly)
cp "$tmp/kwin.spec.upstream.new" kwin.spec.upstream
cp "$tmp/kwin.spec"              kwin.spec
cp kwin.spec "$specfile"
note "Overlay applied cleanly onto Fedora's $PKG-$avail spec."

# --- 3b. assert the spec still APPLIES the patches it declares -------------
# The overlay only *declares* PatchNNNN lines; it relies entirely on the spec's
# `%autosetup -p1` to apply them. That assumption is load-bearing and invisible
# to the patch-based drift gate above, because %prep is far from the patch list
# and our hunk carries no context there.
#
# Concretely: if Fedora ever restructures %prep (say to `%setup` plus explicit
# `%patch -P0`), overlay.patch STILL applies, our Patch lines are STILL
# declared, the build STILL succeeds — and every one of our patches is silently
# dropped, producing a stock kwin that we would then install as "patched".
# That is the exact silent-revert failure this whole pipeline exists to prevent,
# so it gets an explicit assertion rather than an assumption.
autosetup="$(grep -E '^%autosetup' kwin.spec || true)"
[[ -n "$autosetup" ]] || die "spec drift: %prep no longer uses %autosetup, so the declared PatchNNNN lines would never be applied — re-overlay against the new %prep"
[[ "$autosetup" == *-p1* ]] || die "spec drift: %autosetup lost its -p1 strip level ('$autosetup') — our patches are -p1 and would misapply"
[[ "$autosetup" != *-N* ]] || die "spec drift: %autosetup now uses -N (automatic patch application disabled), so our patches would never be applied"

for n in 1000 1001 1002 1003; do
  grep -qE "^Patch${n}:" kwin.spec || die "overlay applied but Patch${n} is missing from the generated spec"
done

# --- 4. stage our patches as SOURCES --------------------------------------
# -L dereferences the symlinks that point back at the repo root, so the spec
# and the Arch PKGBUILD consume byte-identical patch files.
for p in "${OVERLAY_PATCHES[@]}"; do
  [[ -r "$HERE/$p.patch" ]] || die "missing overlay patch: $HERE/$p.patch"
  cp -L "$HERE/$p.patch" "$TOPDIR/SOURCES/"
done

if ((SRPM_ONLY)); then
  note "Building SRPM only..."
  rpmbuild -bs --define "_topdir $TOPDIR" \
               --define "dist $(rpm --eval '%{?dist}')${LOCAL_SUFFIX}" "$specfile"
  note "SRPM written to $TOPDIR/SRPMS. Build it in a clean chroot with:"
  echo "    mock -r fedora-$(rpm --eval '%{fedora}')-$(uname -m) $TOPDIR/SRPMS/${PKG}-*${LOCAL_SUFFIX}.src.rpm"
  exit 0
fi

# --- 5. build --------------------------------------------------------------
target_nvr="${avail}${LOCAL_SUFFIX}"

# Reuse an already-built set if present. rpmbuild only writes the final RPMs
# after a clean build, so their presence means "already built for this NVR" —
# no need to rebuild. This matters because the build and the install are two
# separate sudo moments: a run that built fine but stopped at the install (or
# was run as --build-only) should not cost a second 15-minute compile.
mapfile -t built < <(find "$TOPDIR/RPMS" -name "*-${target_nvr}.*.rpm" 2>/dev/null | sort)

if ((${#built[@]})) && ((!FORCE)); then
  note "Reusing ${#built[@]} already-built RPM(s) for $target_nvr — skipping rebuild. (--force to rebuild)"
else
  # rpmbuild enforces BuildRequires itself and aborts with an exact list of what
  # is missing, so we only pay the sudo prompt when a cheap pre-check suggests
  # something is genuinely absent. The pre-check matches on provide name and
  # ignores version constraints; if it guesses wrong, rpmbuild still catches it.
  if ((SKIP_BUILDDEP)); then
    note "--skip-builddep: assuming build dependencies are satisfied."
  else
    missing=()
    while read -r req; do
      [[ -n "$req" ]] || continue
      rpm -q --whatprovides "${req%% *}" >/dev/null 2>&1 || missing+=("$req")
    done < <(rpmspec -q --buildrequires "$specfile" 2>/dev/null)

    if ((${#missing[@]})); then
      note "Missing build dependencies: ${missing[*]}"
      note "Installing build dependencies (sudo)..."
      sudo dnf builddep -y "$specfile" || die "dnf builddep failed"
    else
      note "All build dependencies already satisfied."
    fi
  fi

  note "Building RPMs (rpmbuild -bb; this takes a while)..."
  rpmbuild -bb --define "_topdir $TOPDIR" \
               --define "dist $(rpm --eval '%{?dist}')${LOCAL_SUFFIX}" "$specfile"

  mapfile -t built < <(find "$TOPDIR/RPMS" -name "*-${target_nvr}.*.rpm" 2>/dev/null | sort)
  ((${#built[@]})) || die "build reported success but no RPMs were produced"
fi

note "Package set for $target_nvr (${#built[@]}):"
printf '      %s\n' "${built[@]##*/}"

# --- 5b. prove our patches are actually IN the binaries -------------------
# Belt-and-braces end-to-end check behind the static assertions in 3b: grep the
# built payload for a string that only exists because our patches were applied.
# virtual-desktops-debug.patch adds [VDBUG] traces to the Virtual Desktops KCM,
# so the literal survives compilation into kwin-common. If this is absent, the
# patches did not make it in, whatever the build said.
note "Verifying our patches are present in the built binaries..."
found=0
for f in "${built[@]}"; do
  case "${f##*/}" in *-debuginfo-*|*-debugsource-*) continue ;; esac
  # NB: grep -c, not grep -q. Under `set -o pipefail`, grep -q exits on the
  # first match, SIGPIPEs rpm2cpio, and the whole pipeline reports failure —
  # which reads as "sentinel absent" even when it is present. grep -c consumes
  # all input, so no SIGPIPE; `|| true` absorbs its exit 1 on zero matches.
  if [[ "$(rpm2cpio "$f" 2>/dev/null | grep -ac 'VDBUG' || true)" != 0 ]]; then
    found=1
    break
  fi
done
((found)) || die "built RPMs contain no trace of our patches (VDBUG sentinel missing) — refusing to install a package that only looks patched"
note "Sentinel found — patches are in the build."

if ((BUILD_ONLY)); then
  note "--build-only: stopping before install."
  exit 0
fi

# --- 6. install ------------------------------------------------------------
# Install exactly the subpackages that are already present, so we preserve the
# system's current shape instead of pulling in -devel/-doc nobody asked for.
to_install=()
for f in "${built[@]}"; do
  n="$(rpm -qp --qf '%{name}' "$f" 2>/dev/null)"
  if rpm -q "$n" &>/dev/null; then
    to_install+=("$f")
  fi
done
if ((!${#to_install[@]})); then
  note "No patched subpackages are currently installed; falling back to the base set."
  for f in "${built[@]}"; do
    case "$(rpm -qp --qf '%{name}' "$f" 2>/dev/null)" in
      "$PKG"|"$PKG-common"|"$PKG-libs") to_install+=("$f") ;;
    esac
  done
fi

# A versionlock from a previous run would block installing the new build, so
# drop our locks first and re-apply them afterwards.
note "Clearing previous kwin versionlocks..."
sudo dnf versionlock delete "$PKG" "$PKG-*" >/dev/null 2>&1 || true

note "Installing (sudo dnf install)..."
# --allow-vendor-change is required, not incidental. Fedora's packages carry
# Vendor "Fedora Project"; ours are built by rpmbuild on this host and carry no
# vendor at all. dnf5 defaults allow_vendor_change=False and will otherwise
# refuse the swap, reporting it as an unsolvable "cannot install both ..."
# conflict whose actual cause is buried in a trailing "Skipping N packages due
# to vendor change restriction" line.
#
# We deliberately do NOT paper over this by stamping a fake "Fedora Project"
# vendor on our build: the empty vendor is an honest signal that this is not a
# distro package (rpm -qi shows it), and the resulting vendor mismatch is a
# useful second barrier — on top of the versionlock below — against a routine
# dnf upgrade silently swapping our patched build back to Fedora's stock one.
# Passing the flag here scopes the exception to this one deliberate install.
sudo dnf install -y --allow-vendor-change "${to_install[@]}"

lock_names=()
for f in "${to_install[@]}"; do
  lock_names+=("$(rpm -qp --qf '%{name}' "$f" 2>/dev/null)")
done
note "Locking ${lock_names[*]} against silent replacement by dnf upgrade..."
sudo dnf versionlock add "${lock_names[@]}" >/dev/null

cat <<EOF

Done. Installed $PKG ${avail}${LOCAL_SUFFIX} (patched), tracked by rpm.
  - Verify ownership:   rpm -qf /usr/bin/kwin_wayland
  - Confirm the lock:   dnf versionlock list
  - The versionlock stops 'dnf upgrade' from silently reverting the patches.
    Re-run this script to pick up a new Fedora release; it drops the lock,
    rebuilds on top of the new spec, and re-locks.
Restart KWin to activate:  kwin_wayland --replace &   (or log out/in)
EOF
