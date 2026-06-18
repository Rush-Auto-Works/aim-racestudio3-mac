#!/bin/bash
# build-wineusb-so.sh — build the libusb-backed wineusb.sys + wineusb.so that let RaceStudio 3
# reach AiM USB devices (notably the USB-only PDM) under Wine on macOS.
#
# WHY THIS EXISTS:
#   AiM devices are vendor-class WinUSB (Class=USBDevice, VID 0x11CC; PID 0x0130 = "AiM Device
#   1.3"). On Windows RS3 opens them via WinUsb_Initialize. Wine implements WinUSB as:
#       winusb.dll  (the WinUsb_* API — ALREADY in the Gcenx bundle)
#       wineusb.sys (the raw-USB *bus* driver, libusb-backed — its unixlib is wineusb.so)
#   configure DISABLES wineusb.sys entirely when libusb-1.0 isn't found ("USB devices won't be
#   supported"). The Gcenx wine-staging osx64 build shipped WITHOUT libusb, so wineusb.{sys,so}
#   are absent and winusb.dll has no device to bind to. This script rebuilds them WITH libusb.
#   No source patch — a pure rebuild with --with-usb. (Confirmed: dlls/wineusb.sys/unixlib.c is
#   plain cross-platform libusb, no __APPLE__ gating.)
#
# WHY SEPARATE / WHY ROSETTA (same reasoning as build-winemac-so.sh):
#   wineusb.so is a UNIX host dylib; it must be x86_64 to drop into the Gcenx osx64 bundle
#   (lib/wine/x86_64-unix/), which runs under Rosetta. So configure + build run under
#   `arch -x86_64`. Homebrew libusb is arm64-only, so we cross-build an x86_64 libusb from
#   source and bundle that dylib next to wineusb.so (loaded via @loader_path).
#
# Deps: mingw-w64, bison, flex (brew), Rosetta 2 on Apple Silicon.
# Usage: build-wineusb-so.sh [wine_version]
# Output: $OUT/x86_64-unix/{wineusb.so,libusb-1.0.0.dylib}
#         $OUT/x86_64-windows/wineusb.sys   (PE bus driver; i386 too if ARCHS includes it)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_PINS="$HERE/../src/pins.env"

# --- libusb pin (supply-chain: verify before building release-critical source) ---
LIBUSB_VER="${LIBUSB_VER:-1.0.27}"
LIBUSB_SHA256="${LIBUSB_SHA256:-ffaa41d741a8a3bee244ac8e54a72ea05bf2879663c098c82fc5757853441575}"
LIBUSB_URL="https://github.com/libusb/libusb/releases/download/v${LIBUSB_VER}/libusb-${LIBUSB_VER}.tar.bz2"

VER="${1:-}"
if [ -z "$VER" ] && [ -f "$SRC_PINS" ]; then
  VER="$(sed -nE 's/^WINE_PINNED_VER="(.*)"/\1/p' "$SRC_PINS")"
fi
VER="${VER:?wine version not given and not found in pins.env}"
MAJOR="${VER%%.*}"
WINE_SRC_SHA256="${WINE_SRC_SHA256:-}"
[ -n "$WINE_SRC_SHA256" ] || { [ -f "$SRC_PINS" ] && WINE_SRC_SHA256="$(sed -nE 's/^WINE_SRC_SHA256="([0-9a-fA-F]{64})"/\1/p' "$SRC_PINS")"; }

OUT="${OUT:-$HERE/build/wineusb}"
WORK="${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/wineusb-so.XXXXXX")}"
ARCHS="${ARCHS:-i386,x86_64}"   # PE driver per-arch; RS3-64 needs x86_64

echo "[build-wineusb-so] wine $VER + libusb $LIBUSB_VER (x86_64 / Rosetta)"
arch -x86_64 /usr/bin/true 2>/dev/null || { echo "ERROR: cannot run x86_64 (Rosetta 2 required: softwareupdate --install-rosetta)"; exit 2; }
for t in x86_64-w64-mingw32-gcc bison flex curl; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing dep: $t (brew install mingw-w64 bison flex)"; exit 2; }
done
bison_prefix="$(brew --prefix bison)"; flex_prefix="$(brew --prefix flex)"
export PATH="$bison_prefix/bin:$flex_prefix/bin:$PATH"

cd "$WORK"

# ---------------------------------------------------------------------------
# 1) Cross-build x86_64 libusb from source (brew's is arm64-only). Running the
#    whole autotools build under `arch -x86_64` makes clang default to x86_64
#    objects (same trick as the Wine unix build below), so no -arch flags needed.
# ---------------------------------------------------------------------------
LIBUSB_TARBALL="libusb-${LIBUSB_VER}.tar.bz2"
LIBUSB_PREFIX="$WORK/libusb-x86"
if [ ! -f "$LIBUSB_TARBALL" ]; then
  echo "[build-wineusb-so] fetching libusb"
  curl -fsSL --proto '=https' -L -o "$LIBUSB_TARBALL" "$LIBUSB_URL"
fi
echo "$LIBUSB_SHA256  $LIBUSB_TARBALL" | shasum -a 256 -c - >/dev/null 2>&1 \
  || { echo "sha256 mismatch for $LIBUSB_TARBALL (expected $LIBUSB_SHA256)"; exit 1; }
echo "[build-wineusb-so] libusb source sha256 verified"
rm -rf "libusb-${LIBUSB_VER}"; tar xf "$LIBUSB_TARBALL"
( cd "libusb-${LIBUSB_VER}"
  arch -x86_64 ./configure --prefix="$LIBUSB_PREFIX" --enable-shared --disable-static --disable-udev \
    >configure.out 2>&1 || { tail -25 configure.out; echo "libusb configure failed"; exit 1; }
  arch -x86_64 make -j"$(sysctl -n hw.ncpu)" >build.out 2>&1 || { tail -25 build.out; echo "libusb build failed"; exit 1; }
  arch -x86_64 make install >>build.out 2>&1 || { echo "libusb install failed"; exit 1; }
)
LIBUSB_DYLIB="$LIBUSB_PREFIX/lib/libusb-1.0.0.dylib"
[ -f "$LIBUSB_DYLIB" ] || { echo "libusb dylib not produced"; exit 1; }
la="$(lipo -archs "$LIBUSB_DYLIB" 2>/dev/null || true)"
[ "$la" = "x86_64" ] || { echo "built libusb is '$la', not x86_64 — refusing"; exit 1; }
echo "[build-wineusb-so] libusb x86_64 -> $LIBUSB_DYLIB"

# ---------------------------------------------------------------------------
# 2) Wine source (pinned + verified)
# ---------------------------------------------------------------------------
TARBALL="wine-$VER.tar.xz"
if [ ! -f "$TARBALL" ]; then
  echo "[build-wineusb-so] fetching wine source"
  curl -fsSL --proto '=https' -o "$TARBALL" "https://dl.winehq.org/wine/source/$MAJOR.x/wine-$VER.tar.xz"
fi
[ -n "$WINE_SRC_SHA256" ] || { echo "missing WINE_SRC_SHA256 for wine-$VER.tar.xz"; exit 2; }
echo "$WINE_SRC_SHA256  $TARBALL" | shasum -a 256 -c - >/dev/null 2>&1 \
  || { echo "sha256 mismatch for $TARBALL (expected $WINE_SRC_SHA256)"; exit 1; }
echo "[build-wineusb-so] wine source sha256 verified"
rm -rf "wine-$VER"; tar xf "$TARBALL"
cd "wine-$VER"

# ---------------------------------------------------------------------------
# 3) configure with libusb. PKG_CONFIG_PATH points at the x86_64 libusb so the
#    AC_CHECK_LIB(usb-1.0,...) probe links the right arch. --without-freetype:
#    arm64 brew has no x86_64 freetype (would abort an x86_64 configure).
# ---------------------------------------------------------------------------
export PKG_CONFIG_PATH="$LIBUSB_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
echo "[build-wineusb-so] configure (x86_64, --with-usb)"
arch -x86_64 ./configure --enable-archs="$ARCHS" --with-usb --without-x --disable-tests --without-freetype \
  >configure.out 2>&1 || { tail -30 configure.out; echo "configure failed"; exit 1; }
# Hard assert libusb was actually detected — otherwise wineusb.sys silently won't build.
grep -q "ac_cv_lib_usb_1_0_libusb_interrupt_event_handler=yes" config.log \
  || { grep -i "libusb" configure.out config.log | tail -10; echo "ERROR: configure did NOT detect libusb-1.0 — wineusb would be disabled"; exit 1; }
echo "[build-wineusb-so] libusb detected by configure"

echo "[build-wineusb-so] building tools"
arch -x86_64 make -j"$(sysctl -n hw.ncpu)" __tooldeps__ >build.out 2>&1 || { tail -25 build.out; echo "tooldeps failed"; exit 1; }

# unix host module
echo "[build-wineusb-so] building dlls/wineusb.sys/wineusb.so (unix)"
arch -x86_64 make -j"$(sysctl -n hw.ncpu)" dlls/wineusb.sys/wineusb.so >>build.out 2>&1 \
  || { tail -30 build.out; echo "wineusb.so build failed"; exit 1; }
SO="dlls/wineusb.sys/wineusb.so"
[ -f "$SO" ] || { echo "wineusb.so not produced"; exit 1; }
a="$(lipo -archs "$SO" 2>/dev/null || true)"
[ "$a" = "x86_64" ] || { echo "built wineusb.so is '$a', not x86_64 — refusing"; exit 1; }
otool -L "$SO" | grep -qi "libusb" || { echo "wineusb.so does not link libusb — build is wrong"; exit 1; }

mkdir -p "$OUT/x86_64-unix"
cp "$SO" "$OUT/x86_64-unix/wineusb.so"
cp "$LIBUSB_DYLIB" "$OUT/x86_64-unix/libusb-1.0.0.dylib"
# Make wineusb.so load the bundled libusb relative to itself, and the dylib self-id likewise.
oldref="$(otool -L "$OUT/x86_64-unix/wineusb.so" | awk '/libusb-1.0/{print $1; exit}')"
install_name_tool -id @loader_path/libusb-1.0.0.dylib "$OUT/x86_64-unix/libusb-1.0.0.dylib"
[ -n "$oldref" ] && install_name_tool -change "$oldref" @loader_path/libusb-1.0.0.dylib "$OUT/x86_64-unix/wineusb.so"
install_name_tool -id wineusb.so "$OUT/x86_64-unix/wineusb.so" 2>/dev/null || true
echo "[build-wineusb-so] unix -> $OUT/x86_64-unix/wineusb.so (libusb: @loader_path/libusb-1.0.0.dylib)"

# PE bus driver(s)
IFS=',' read -ra A <<< "$ARCHS"
for arch in "${A[@]}"; do
  tgt="dlls/wineusb.sys/${arch}-windows/wineusb.sys"
  echo "[build-wineusb-so] building $tgt (PE)"
  arch -x86_64 make -j"$(sysctl -n hw.ncpu)" "$tgt" >>build.out 2>&1 \
    || { tail -30 build.out; echo "build $tgt failed"; exit 1; }
  mkdir -p "$OUT/${arch}-windows"
  cp "$tgt" "$OUT/${arch}-windows/wineusb.sys"
  echo "[build-wineusb-so] PE -> $OUT/${arch}-windows/wineusb.sys"
done

# wineusb.inf — wine.inf references it (@%12%\wineusb.sys) to register the root\wineusb bus device
# + the wineusb service. The stock bundle omits it (built without libusb), so a fresh prefix can't
# self-register the bus. Ship it alongside so wineboot wires up USB on prefix (re)creation.
cp "dlls/wineusb.sys/wineusb.inf" "$OUT/wineusb.inf"
echo "[build-wineusb-so] inf -> $OUT/wineusb.inf"

echo "[build-wineusb-so] done -> $OUT"
echo "  x86_64-unix/wineusb.so       ($(lipo -archs "$OUT/x86_64-unix/wineusb.so"))"
echo "  x86_64-unix/libusb-1.0.0.dylib ($(lipo -archs "$OUT/x86_64-unix/libusb-1.0.0.dylib"))"
ls "$OUT"/*-windows/wineusb.sys 2>/dev/null | sed 's/^/  /'