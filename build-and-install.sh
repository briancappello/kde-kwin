#!/usr/bin/env bash
# build-and-install.sh
#
# Builds and installs a patched kwin. Two distros, two native packaging
# backends, one entry point. Both paths now produce a REAL PACKAGE that the
# system package manager tracks:
#
#   Arch   -> delegates to pkg/update.sh        (makepkg + pacman -U)
#   Fedora -> delegates to pkg-fedora/update.sh (rpmbuild + dnf install)
#
# WHY BOTH PATHS DELEGATE:
#   This script originally used a raw cmake + `sudo cmake --install` path on
#   every distro. That is wrong on any distro: it writes files into /usr behind
#   the package manager's back, so the package database no longer describes
#   what is on disk, and the next upgrade silently overwrites the patched build,
#   reverting every patch with no warning.
#
#   On Arch that showed up loudly (`pacman -Qkk kwin` reports mismatches).
#   On Fedora it showed up silently: the 6.7.0 build installed here in August
#   was erased by the routine 6.7.4-2.fc44 update, and `rpm -V kwin` came back
#   clean afterwards because rpm had simply restored its own files. Nothing
#   indicated the patches were gone.
#
#   pkg/update.sh fixed this for Arch; pkg-fedora/update.sh now does the same
#   for Fedora. The raw cmake path has been removed — it has no remaining users.
#
# BOTH PIPELINES SHARE THE SAME SHAPE:
#   1. Fetch the DISTRO'S OWN official recipe (Arch PKGBUILD / Fedora SRPM spec).
#   2. Replay a version-agnostic overlay.patch onto it. If it does not apply,
#      the distro changed their packaging -> STOP and show the diff. This is the
#      loud gate for packaging drift.
#   3. Build with the native tool, applying our patches with NO FUZZ, so a
#      patch that no longer matches aborts the build instead of silently
#      applying at the wrong offset.
#   4. Install as a tracked package, then pin it (Arch: IgnorePkg,
#      Fedora: dnf versionlock) so a routine upgrade cannot silently revert it.
#
#   Because each side starts from its own distro's recipe, distro-specific
#   downstream patches are inherited automatically rather than hand-copied.
#   (Example: the upstream cherry-pick 2d0613ac, "apps may get disconnected on
#   mesa 26+", is carried by Arch in its PKGBUILD and by Fedora as Patch0 in
#   its spec. Neither overlay has to know about it.)
#
# OUR PATCHES (identical on both distros; the packaging dirs symlink to these):
#   1. swap-gesture-fingers.patch    -- 3-finger up/down -> Overview/Grid View;
#                                       3-finger left/right -> switch desktops;
#                                       all 4-finger gestures removed.
#   2. screen-edge-corners.patch     -- geometry-aware perimeter corner
#                                       detection, so non-rectangular
#                                       multi-monitor layouts get corners only
#                                       at true convex vertices; also disables
#                                       edge barriers at interior boundaries so
#                                       the cursor moves freely between screens.
#   3. virtual-desktops-debug.patch  -- [VDBUG] stderr traces in the Virtual
#                                       Desktops KCM. Mute by setting
#                                       VDBUG_ENABLED to 0 in desktopsmodel.cpp.
#                                       kcmshell6 kcm_kwin_virtualdesktops 2>&1 | tee /tmp/vdbug.log
#   4. virtual-desktops-fix.patch    -- VirtualDesktopManager::load() used to
#                                       read persisted Id_N values verbatim,
#                                       including legacy non-UUID strings like
#                                       "Desktop". Duplicate ids made desktops
#                                       collapse in the KCM (renaming one
#                                       renamed both). Now each id is validated
#                                       as a unique UUID, reassigned if not,
#                                       and the heal is persisted once.
#
# Usage:
#   ./build-and-install.sh              # build + install
#   ./build-and-install.sh --clean      # wipe build artifacts first
#   ./build-and-install.sh --build-only # build only, do not install
#   ./build-and-install.sh --force      # rebuild even if already current
#
# All flags are forwarded to the distro's update.sh; see those scripts for the
# full set (Fedora additionally supports --srpm and --skip-builddep).
#
# NOTE: the target kwin version is NOT set here. Each side tracks whatever its
# own distro currently ships, which is the whole point of starting from the
# distro's recipe.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "!! $*" >&2; exit 1; }
note() { echo "==> $*"; }

# ---------------------------------------------------------------------------
# 1. Detect distro family
#
# Some systems (e.g. Fedora with the Arch pacman package installed) have *both*
# dnf and pacman on PATH, so `command -v pacman` alone cannot be trusted.
# Prefer /etc/os-release, which reliably identifies the actual distribution,
# and only fall back to probing for a package manager binary.
# ---------------------------------------------------------------------------
DISTRO_FAMILY=""
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case " ${ID:-} ${ID_LIKE:-} " in
        *" fedora "*|*" rhel "*|*" centos "*) DISTRO_FAMILY="fedora" ;;
        *" arch "*)                           DISTRO_FAMILY="arch"   ;;
    esac
fi

if [[ -z "$DISTRO_FAMILY" ]]; then
    if command -v dnf &>/dev/null; then
        DISTRO_FAMILY="fedora"
    elif command -v pacman &>/dev/null; then
        DISTRO_FAMILY="arch"
    fi
fi

note "Distro family: ${DISTRO_FAMILY:-unknown}"

# ---------------------------------------------------------------------------
# 2. Route to the matching packaged build pipeline
# ---------------------------------------------------------------------------
case "$DISTRO_FAMILY" in
    arch)
        UPDATE_SH="$SCRIPT_DIR/pkg/update.sh"
        [[ -x "$UPDATE_SH" ]] || die "cannot find executable $UPDATE_SH"

        PASS_ARGS=()
        for arg in "$@"; do
            case "$arg" in
                --clean)
                    # pkg/update.sh has no --clean; makepkg -Cf rebuilds but
                    # reuses the extracted src/ and pkg/ trees. Wipe them so the
                    # next build starts from a freshly extracted tarball.
                    note "--clean: removing makepkg build artifacts (pkg/src, pkg/pkg)..."
                    rm -rf "$SCRIPT_DIR/pkg/src" "$SCRIPT_DIR/pkg/pkg"
                    ;;
                *)
                    PASS_ARGS+=("$arg")
                    ;;
            esac
        done
        ;;

    fedora)
        # pkg-fedora/update.sh understands --clean itself (it wipes its own
        # rpmbuild tree), so everything is forwarded verbatim.
        UPDATE_SH="$SCRIPT_DIR/pkg-fedora/update.sh"
        [[ -x "$UPDATE_SH" ]] || die "cannot find executable $UPDATE_SH"
        PASS_ARGS=("$@")
        ;;

    *)
        die "unsupported distro '${DISTRO_FAMILY:-unknown}'. Supported: arch, fedora."
        ;;
esac

note "Delegating to ${UPDATE_SH#"$SCRIPT_DIR"/} ${PASS_ARGS[*]:-(no args)}"
exec "$UPDATE_SH" "${PASS_ARGS[@]}"
