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
# Mirrors the official Arch kwin PKGBUILD with our gesture patch added.
#
# Usage:
#   ./build-and-install.sh          # build + install
#   ./build-and-install.sh --clean  # wipe build dir first, then build + install

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
KWIN_VERSION="6.6.4"
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
# 1. Install build dependencies (Arch Linux / pacman)
# ---------------------------------------------------------------------------
BUILD_DEPS=(
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
)

echo "==> Checking build dependencies..."
MISSING=()
for pkg in "${BUILD_DEPS[@]}"; do
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
