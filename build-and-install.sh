#!/usr/bin/env bash
# build-and-install.sh
#
# Builds and installs a patched kwin. Two distros, two very different backends,
# one entry point.
#
#   Arch   -> delegates to pkg/update.sh (makepkg + pacman). This is the
#             preferred path: the result is a real package, tracked by the
#             package manager, installed with `pacman -U`.
#   Fedora -> builds from an upstream git checkout with cmake and installs
#             straight into /usr.
#
# WHY THE TWO PATHS DIFFER:
#   This script originally used the cmake+`sudo cmake --install` path on every
#   distro, including Arch. That was wrong on Arch: it wrote files into /usr
#   behind pacman's back, so the package database no longer described what was
#   on disk (`pacman -Qkk kwin` reports mismatches) and the next `pacman -Syu`
#   would silently overwrite the patched build. pkg/update.sh exists precisely
#   to fix that, so Arch now routes there and the raw cmake path is reserved
#   for distros that do not yet have a packaged equivalent.
#
#   The old cmake path also pinned a HARDCODED kwin 6.7.0, which predates the
#   NVIDIA color-pipeline crash fix (CCBUG 520842) and SIGSEGVs on NVIDIA,
#   taking the SDDM greeter down with it. The version is no longer hardcoded:
#   it is read from pkg/PKGBUILD so both distros build the same release.
#
# KNOWN GAP (Fedora): the Fedora path still installs unpackaged files into
#   /usr, which has the same "invisible to the package manager" problem
#   described above -- rpm just complains less loudly than pacman. It needs an
#   rpmbuild-based equivalent of pkg/update.sh. Until then the script warns
#   before doing it.
#
# OUR PATCHES (identical on both distros; applied from the repo root):
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
#   ./build-and-install.sh --no-install # Arch: publish to arches-local, no pacman -U
#   ./build-and-install.sh --force      # Arch: rebuild even if already current
#
#   KWIN_VERSION=6.7.5 ./build-and-install.sh   # override the target release
#
#   On Arch, unrecognized flags are passed through to pkg/update.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_SH="$SCRIPT_DIR/pkg/update.sh"
BUILD_DIR="$SCRIPT_DIR/build"
UPSTREAM_REPO="https://invent.kde.org/plasma/kwin"
UPSTREAM_CLONE="$BUILD_DIR/kwin-src"

die() { echo "!! $*" >&2; exit 1; }
note() { echo "==> $*"; }

# ---------------------------------------------------------------------------
# 0. Detect distro family
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
# 1. Arch: delegate to the packaged build pipeline and stop here.
#
# pkg/update.sh fetches the current official Arch PKGBUILD, replays our
# overlay.patch (loud-failing on upstream packaging drift), refreshes only the
# upstream tarball checksum, verifies the KDE signing keys, builds with makepkg
# (patches applied in prepare() with -F0, so a stale patch aborts the build),
# publishes to the arches-local repo and installs with pacman -U.
# ---------------------------------------------------------------------------
if [[ "$DISTRO_FAMILY" == "arch" ]]; then
    [[ -x "$UPDATE_SH" ]] || die "cannot find executable $UPDATE_SH"

    PASS_ARGS=()
    for arg in "$@"; do
        case "$arg" in
            --clean)
                # update.sh has no --clean; makepkg -Cf rebuilds but reuses the
                # extracted src/ and pkg/ trees. Wipe them so the next build
                # starts from a freshly extracted tarball.
                note "--clean: removing makepkg build artifacts (pkg/src, pkg/pkg)..."
                rm -rf "$SCRIPT_DIR/pkg/src" "$SCRIPT_DIR/pkg/pkg"
                ;;
            *)
                PASS_ARGS+=("$arg")
                ;;
        esac
    done

    note "Delegating to pkg/update.sh ${PASS_ARGS[*]:-(no args)}"
    exec "$UPDATE_SH" "${PASS_ARGS[@]}"
fi

# ---------------------------------------------------------------------------
# 2. Non-Arch: parse flags for the source-build path
# ---------------------------------------------------------------------------
DO_CLEAN=0
BUILD_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --clean)      DO_CLEAN=1 ;;
        --build-only) BUILD_ONLY=1 ;;
        --no-install) BUILD_ONLY=1 ;;
        --force)      note "--force has no effect on the source-build path; ignoring." ;;
        *)            die "unknown flag for the ${DISTRO_FAMILY:-unknown} build path: $arg" ;;
    esac
done

[[ "$DISTRO_FAMILY" == "fedora" ]] || \
    die "unsupported distro '${DISTRO_FAMILY:-unknown}'. Supported: arch (packaged), fedora (source build)."

# ---------------------------------------------------------------------------
# 3. Resolve the kwin version
#
# Single source of truth: pkg/PKGBUILD's pkgver, so the Fedora source build
# tracks the exact release the Arch package tracks. Overridable via the
# KWIN_VERSION environment variable.
# ---------------------------------------------------------------------------
if [[ -z "${KWIN_VERSION:-}" ]]; then
    pkgbuild="$SCRIPT_DIR/pkg/PKGBUILD"
    [[ -r "$pkgbuild" ]] || die "cannot read $pkgbuild to determine the kwin version (set KWIN_VERSION to override)"
    KWIN_VERSION="$(sed -n 's/^pkgver=\([0-9][0-9.]*\)[[:space:]]*$/\1/p' "$pkgbuild" | head -1)"
    [[ -n "$KWIN_VERSION" ]] || die "could not parse pkgver from $pkgbuild (set KWIN_VERSION to override)"
fi
UPSTREAM_TAG="v${KWIN_VERSION}"
note "Target kwin version: $KWIN_VERSION (tag $UPSTREAM_TAG)"

if [[ $DO_CLEAN -eq 1 ]]; then
    note "--clean: removing build directory $BUILD_DIR..."
    rm -rf "$BUILD_DIR"
fi

# ---------------------------------------------------------------------------
# 4. Install build dependencies
#
# Fedora package names, derived from the official Fedora `kwin` BuildRequires
# (dnf repoquery --srpm --requires kwin) with the cmake()/pkgconfig() virtual
# provides resolved to their concrete -devel packages.
# ---------------------------------------------------------------------------
FEDORA_DEPS=(
    cmake extra-cmake-modules gcc-c++ ninja-build
    kf6-kdoctools-devel kf6-krunner-devel
    plasma-wayland-protocols-devel python3 wayland-protocols-devel xorg-x11-server-Xwayland
    kf6-kauth-devel kf6-kcmutils-devel kf6-kcolorscheme-devel kf6-kconfig-devel kf6-kcoreaddons-devel kf6-kcrash-devel kf6-kdbusaddons-devel
    kf6-kdeclarative-devel kdecoration-devel kf6-kglobalaccel-devel kglobalacceld-devel kf6-kguiaddons-devel
    kf6-ki18n-devel kf6-kidletime-devel kf6-kirigami-devel kf6-kitemmodels-devel kf6-knewstuff-devel knighttime-devel
    kf6-knotifications-devel kf6-kpackage-devel kf6-kquickcharts-devel kscreenlocker-devel kf6-kservice-devel kf6-ksvg-devel
    kwayland-devel kf6-kwidgetsaddons-devel kf6-kwindowsystem-devel kf6-kxmlgui-devel
    kf6-kcompletion-devel kf6-kconfigwidgets-devel kf6-kiconthemes-devel kf6-ktextwidgets-devel
    lcms2-devel libcanberra-devel libdisplay-info-devel libdrm-devel libeis-devel libepoxy-devel libevdev-devel
    libinput-devel pipewire-devel qaccessibilityclient-qt6-devel libxcb-devel libxcvt-devel
    libxkbcommon-devel libxkbcommon-x11-devel mesa-libEGL-devel mesa-libGL-devel mesa-libgbm-devel
    libplasma-devel plasma-activities-devel plasma-breeze
    qt6-qt5compat-devel qt6-qtbase-devel qt6-qtbase-private-devel qt6-qtbase-static qt6-qtdeclarative-devel
    qt6-qtsvg-devel qt6-qttools-devel qt6-qttools-static qt6-qtwayland-devel
    systemd-devel systemd-libs wayland-devel xcb-util-keysyms-devel xcb-util-wm-devel xcb-util-devel xcb-util-image-devel xcb-util-cursor-devel
    vulkan-headers vulkan-loader
    glib2-devel libICE-devel libSM-devel libX11-devel libXcursor-devel libXi-devel libcap-devel
)

note "Checking build dependencies..."
MISSING=()
for pkg in "${FEDORA_DEPS[@]}"; do
    if ! rpm -q "$pkg" &>/dev/null; then
        MISSING+=("$pkg")
    fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    note "Installing missing build dependencies: ${MISSING[*]}"
    sudo dnf install -y "${MISSING[@]}"
else
    note "All build dependencies already installed."
fi

# ---------------------------------------------------------------------------
# 5. Fetch upstream kwin source
# ---------------------------------------------------------------------------
mkdir -p "$BUILD_DIR"

if [[ ! -d "$UPSTREAM_CLONE" ]]; then
    # Verify the tag exists before cloning, so a version bump that upstream
    # has not tagged yet fails here with a clear message instead of inside a
    # confusing `git clone --branch` error.
    git ls-remote --exit-code --tags "$UPSTREAM_REPO" "refs/tags/$UPSTREAM_TAG" >/dev/null 2>&1 || \
        die "upstream tag $UPSTREAM_TAG does not exist at $UPSTREAM_REPO"

    note "Cloning upstream kwin at tag $UPSTREAM_TAG..."
    git clone --depth 1 --branch "$UPSTREAM_TAG" "$UPSTREAM_REPO" "$UPSTREAM_CLONE"
else
    note "Upstream clone already present at $UPSTREAM_CLONE"
    existing_tag="$(git -C "$UPSTREAM_CLONE" describe --tags --exact-match 2>/dev/null || echo "")"
    if [[ -n "$existing_tag" && "$existing_tag" != "$UPSTREAM_TAG" ]]; then
        die "existing clone is at $existing_tag but $UPSTREAM_TAG was requested; re-run with --clean"
    fi
fi

# ---------------------------------------------------------------------------
# 6. Apply patches
#
# -F0 = no fuzz: if a patch no longer matches the tree exactly, fail loudly
# rather than silently applying it at the wrong offset. Mirrors the makepkg
# prepare() step in pkg/PKGBUILD.
# ---------------------------------------------------------------------------
note "Applying patches..."
git -C "$UPSTREAM_CLONE" checkout -- . 2>/dev/null || true
for p in swap-gesture-fingers screen-edge-corners virtual-desktops-debug virtual-desktops-fix; do
    patch -p1 -F0 -d "$UPSTREAM_CLONE" < "$SCRIPT_DIR/$p.patch" || die "$p.patch did not apply cleanly to $UPSTREAM_TAG"
    echo "    $p.patch applied cleanly"
done

# ---------------------------------------------------------------------------
# 7. Configure + build
# ---------------------------------------------------------------------------
CMAKE_BUILD="$BUILD_DIR/cmake-build"
mkdir -p "$CMAKE_BUILD"
rm -f "$CMAKE_BUILD/CMakeCache.txt"

note "Configuring..."
cmake -S "$UPSTREAM_CLONE" -B "$CMAKE_BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBEXECDIR=lib \
    -DBUILD_TESTING=OFF

note "Building (this may take a while)..."
cmake --build "$CMAKE_BUILD" --parallel "$(nproc)"

if [[ $BUILD_ONLY -eq 1 ]]; then
    note "Build complete; stopping before install as requested."
    exit 0
fi

# ---------------------------------------------------------------------------
# 8. Install system-wide
# ---------------------------------------------------------------------------
cat >&2 <<'WARN'

!! WARNING: installing unpackaged files directly into /usr.
!! rpm will not know about these files. A later `dnf upgrade` of kwin will
!! overwrite them without warning, silently reverting the patches. This path
!! needs an rpmbuild-based equivalent of pkg/update.sh.

WARN

note "Installing (requires sudo)..."
sudo cmake --install "$CMAKE_BUILD"
sudo setcap CAP_SYS_NICE=+ep /usr/bin/kwin_wayland

# ---------------------------------------------------------------------------
# 9. Done
# ---------------------------------------------------------------------------
cat <<'DONE'

Done! Changes applied:
  Gestures:
    3-finger swipe up/down    -> Overview / Grid View
    3-finger swipe left/right -> Switch virtual desktops
  Screen edges:
    Corners are now placed at the true outer perimeter of your
    multi-monitor layout instead of at every monitor's corners.

To activate, either:
  - Log out and back in
  - Or restart KWin: kwin_wayland --replace &
DONE
