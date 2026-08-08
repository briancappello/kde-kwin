#!/usr/bin/env bash
# build-and-install.sh
#
# Builds a patched kwin package with the following changes:
#
# 1. Gesture swap (swap-gesture-fingers.patch):
#    3-finger swipe up/down    -> Overview / Grid View  (was desktop switching)
#    3-finger swipe left/right -> Switch virtual desktops (unchanged)
#    All 4-finger gesture registrations are removed.
#
# 2. Screen edge corners fix (screen-edge-corners.patch):
#    Replaces the "corners on every monitor" approach with geometry-aware
#    perimeter corner detection.  Corners are only created at the actual
#    convex vertices of the combined display polygon, so non-rectangular
#    multi-monitor layouts get the correct set of active corners.
#    Also disables edge barriers at interior screen boundaries so the
#    cursor moves freely between monitors.
#
# 3. Virtual Desktops KCM diagnostic logging (virtual-desktops-debug.patch):
#    Adds [VDBUG]-tagged stderr traces to the KCM that drives
#    System Settings > Window Management > Virtual Desktops, so we can
#    capture exact state transitions while reproducing rename bugs.
#    Disable by editing desktopsmodel.cpp and setting VDBUG_ENABLED to 0.
#    See: kcmshell6 kcm_kwin_virtualdesktops 2>&1 | tee /tmp/vdbug.log
#
# 4. Virtual Desktops id-heal fix (virtual-desktops-fix.patch):
#    VirtualDesktopManager::load() previously read the persisted
#    Id_N entries verbatim, including legacy non-UUID values like the
#    literal string "Desktop" that older Plasma versions sometimes
#    wrote. Multiple desktops sharing the same id silently collapsed
#    in the KCM (renaming one desktop renamed both, etc).  The patch
#    validates each id is a well-formed unique UUID and assigns a
#    fresh UUID otherwise, then persists the heal so it only happens
#    once.
#
# Mirrors the official Arch kwin PKGBUILD with our patches added.
#
# Usage:
#   ./build-and-install.sh          # build + install
#   ./build-and-install.sh --clean  # wipe build dir first, then build + install

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
KWIN_VERSION="6.7.0"
UPSTREAM_TAG="v${KWIN_VERSION}"
UPSTREAM_REPO="https://invent.kde.org/plasma/kwin"
UPSTREAM_CLONE="$BUILD_DIR/kwin-src"

# ---------------------------------------------------------------------------
# 0. Optional --clean
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--clean" ]]; then
    echo "==> Removing build directory..."
    rm -rf "$BUILD_DIR"
fi

# ---------------------------------------------------------------------------
# 1. Install build dependencies (Arch Linux / pacman or Fedora / dnf)
# ---------------------------------------------------------------------------
ARCH_DEPS=(
    cmake extra-cmake-modules gcc
    kdoctools krunner
    plasma-wayland-protocols python wayland-protocols xorg-xwayland
    # Runtime deps that are also needed at build time
    kauth kcmutils kcolorscheme kconfig kcoreaddons kcrash kdbusaddons
    kdeclarative kdecoration kglobalaccel kglobalacceld kguiaddons
    ki18n kidletime kirigami kitemmodels knewstuff knighttime
    knotifications kpackage kquickcharts kscreenlocker kservice ksvg
    kwayland kwidgetsaddons kwindowsystem kxmlgui
    lcms2 libcanberra libdisplay-info libdrm libei libepoxy libevdev
    libinput libpipewire libqaccessibilityclient-qt6 libxcb libxcvt
    libxkbcommon mesa milou libplasma plasma-activities
    qt6-5compat qt6-base qt6-declarative qt6-svg qt6-tools
    systemd-libs wayland xcb-util-keysyms xcb-util-wm
    vulkan-headers vulkan-icd-loader
)

# Fedora package names, derived from the official Fedora `kwin` BuildRequires
# (dnf repoquery --srpm --requires kwin) with the cmake()/pkgconfig() virtual
# provides resolved to their concrete -devel packages.
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

# Determine the distro family. Some systems (e.g. Fedora with the Arch
# pacman package installed) have *both* dnf and pacman on PATH, so we cannot
# rely on `command -v pacman` alone. Prefer /etc/os-release, which reliably
# identifies the actual distribution, and only fall back to binary probing.
DISTRO_FAMILY=""
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case " ${ID:-} ${ID_LIKE:-} " in
        *" fedora "*|*" rhel "*|*" centos "*) DISTRO_FAMILY="fedora" ;;
        *" arch "*)                           DISTRO_FAMILY="arch"   ;;
    esac
fi

# Fall back to detecting the package manager binary if os-release was
# inconclusive.
if [[ -z "$DISTRO_FAMILY" ]]; then
    if command -v dnf &>/dev/null; then
        DISTRO_FAMILY="fedora"
    elif command -v pacman &>/dev/null; then
        DISTRO_FAMILY="arch"
    fi
fi

echo "==> Checking build dependencies (distro: ${DISTRO_FAMILY:-unknown})..."
if [[ "$DISTRO_FAMILY" == "fedora" ]]; then
    MISSING=()
    for pkg in "${FEDORA_DEPS[@]}"; do
        if ! rpm -q "$pkg" &>/dev/null; then
            MISSING+=("$pkg")
        fi
    done

    if [[ ${#MISSING[@]} -gt 0 ]]; then
        echo "==> Installing missing build dependencies: ${MISSING[*]}"
        sudo dnf install -y "${MISSING[@]}"
    else
        echo "==> All build dependencies already installed."
    fi
elif [[ "$DISTRO_FAMILY" == "arch" ]]; then
    MISSING=()
    for pkg in "${ARCH_DEPS[@]}"; do
        if ! pacman -Qi "$pkg" &>/dev/null; then
            MISSING+=("$pkg")
        fi
    done

    if [[ ${#MISSING[@]} -gt 0 ]]; then
        echo "==> Installing missing build dependencies: ${MISSING[*]}"
        sudo pacman -S --noconfirm --needed "${MISSING[@]}"
    else
        echo "==> All build dependencies already installed."
    fi
else
    echo "==> Could not identify distro (no fedora/arch match); assuming build dependencies are already installed."
fi

# ---------------------------------------------------------------------------
# 2. Fetch upstream kwin source
# ---------------------------------------------------------------------------
mkdir -p "$BUILD_DIR"

if [[ ! -d "$UPSTREAM_CLONE" ]]; then
    echo "==> Cloning upstream kwin at tag $UPSTREAM_TAG..."
    git clone --depth 1 --branch "$UPSTREAM_TAG" \
        "$UPSTREAM_REPO" "$UPSTREAM_CLONE"
else
    echo "==> Upstream clone already present at $UPSTREAM_CLONE"
fi

# ---------------------------------------------------------------------------
# 3. Apply patches
# ---------------------------------------------------------------------------
echo "==> Applying patches..."
# Reset any previous patch application
git -C "$UPSTREAM_CLONE" checkout -- . 2>/dev/null || true
patch -p1 -d "$UPSTREAM_CLONE" < "$SCRIPT_DIR/swap-gesture-fingers.patch"
echo "    gesture swap patch applied cleanly"
patch -p1 -d "$UPSTREAM_CLONE" < "$SCRIPT_DIR/screen-edge-corners.patch"
echo "    screen edge corners patch applied cleanly"
patch -p1 -d "$UPSTREAM_CLONE" < "$SCRIPT_DIR/virtual-desktops-debug.patch"
echo "    virtual-desktops diagnostic logging patch applied cleanly"
patch -p1 -d "$UPSTREAM_CLONE" < "$SCRIPT_DIR/virtual-desktops-fix.patch"
echo "    virtual-desktops id-heal fix applied cleanly"

# ---------------------------------------------------------------------------
# 4. Configure + build
# ---------------------------------------------------------------------------
CMAKE_BUILD="$BUILD_DIR/cmake-build"
mkdir -p "$CMAKE_BUILD"
rm -f "$CMAKE_BUILD/CMakeCache.txt"

echo "==> Configuring..."
cmake -S "$UPSTREAM_CLONE" -B "$CMAKE_BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBEXECDIR=lib \
    -DBUILD_TESTING=OFF

echo "==> Building (this may take a while)..."
cmake --build "$CMAKE_BUILD" --parallel "$(nproc)"

# ---------------------------------------------------------------------------
# 5. Install system-wide
# ---------------------------------------------------------------------------
echo "==> Installing (requires sudo)..."
sudo cmake --install "$CMAKE_BUILD"
sudo setcap CAP_SYS_NICE=+ep /usr/bin/kwin_wayland

# ---------------------------------------------------------------------------
# 6. Done
# ---------------------------------------------------------------------------
echo ""
echo "Done! Changes applied:"
echo "  Gestures:"
echo "    3-finger swipe up/down    -> Overview / Grid View"
echo "    3-finger swipe left/right -> Switch virtual desktops"
echo "  Screen edges:"
echo "    Corners are now placed at the true outer perimeter of your"
echo "    multi-monitor layout instead of at every monitor's corners."
echo ""
echo "To activate, either:"
echo "  - Log out and back in"
echo "  - Or restart KWin: kwin_wayland --replace &"
