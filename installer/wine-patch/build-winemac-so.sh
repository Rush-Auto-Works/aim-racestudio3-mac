#!/bin/bash
# build-winemac-so.sh — build the patched unix-side winemac.so that adds RaceStudio 3's native
# macOS app-menu items (Import / Uninstall / Show Logs) and the ⌘Q Quit shortcut. Source patch:
# winemac-native-menu.patch (a diff of dlls/winemac.drv/cocoa_app.m).
#
# WHY THIS IS SEPARATE FROM bridge/wine-patch/build-wine-dlls.sh:
#   The bridge builds PE DLLs (ws2_32/wlanapi) with mingw — host-arch-independent, so it configures
#   natively (arm64 on Apple Silicon CI) and must NOT be disturbed. winemac.so is a UNIX host dylib:
#   it must be x86_64 to drop into the Gcenx osx64 bundle (lib/wine/x86_64-unix/winemac.so), which
#   runs under Rosetta. On an arm64 host a native build yields aarch64-unix — NOT swappable. So this
#   script configures + builds the WHOLE thing under `arch -x86_64`. Requires Rosetta 2 on arm64.
#
# Deps: mingw-w64, bison, flex (brew), Rosetta 2 on Apple Silicon. Usage: build-winemac-so.sh [wine_version]
# Output: $OUT/x86_64-unix/winemac.so  (OUT defaults to ./build/winemac)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_PINS="$HERE/../src/pins.env"
PATCHFILE="$HERE/winemac-native-menu.patch"
MARKER="wine_rs3OpenAuxApp"   # drift guard: must appear in the built winemac.so

VER="${1:-}"
if [ -z "$VER" ] && [ -f "$SRC_PINS" ]; then
  VER="$(sed -nE 's/^WINE_PINNED_VER="(.*)"/\1/p' "$SRC_PINS")"
fi
VER="${VER:?wine version not given and not found in pins.env}"
MAJOR="${VER%%.*}"
# Supply-chain integrity: pin the winehq source tarball's sha256 (pins.env, override via env).
# This is release-critical source consumed by the build, so verify before extracting.
WINE_SRC_SHA256="${WINE_SRC_SHA256:-}"
[ -n "$WINE_SRC_SHA256" ] || { [ -f "$SRC_PINS" ] && WINE_SRC_SHA256="$(sed -nE 's/^WINE_SRC_SHA256="([0-9a-fA-F]{64})"/\1/p' "$SRC_PINS")"; }

OUT="${OUT:-$HERE/build/winemac}"
WORK="${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/winemac-so.XXXXXX")}"

echo "[build-winemac-so] wine $VER (x86_64 / Rosetta)"
# x86_64 toolchain capability — fail loud rather than silently emit an arm64 (un-swappable) module.
arch -x86_64 /usr/bin/true 2>/dev/null || { echo "ERROR: cannot run x86_64 (Rosetta 2 required on Apple Silicon: softwareupdate --install-rosetta)"; exit 2; }
for t in x86_64-w64-mingw32-gcc bison flex curl; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing dep: $t (brew install mingw-w64 bison flex)"; exit 2; }
done
bison_prefix="$(brew --prefix bison)"; flex_prefix="$(brew --prefix flex)"
export PATH="$bison_prefix/bin:$flex_prefix/bin:$PATH"
[ -f "$PATCHFILE" ] || { echo "missing patch: $PATCHFILE"; exit 2; }

cd "$WORK"
TARBALL="wine-$VER.tar.xz"
if [ ! -f "$TARBALL" ]; then
  echo "[build-winemac-so] fetching source"
  curl -fsSL --proto '=https' -o "$TARBALL" "https://dl.winehq.org/wine/source/$MAJOR.x/wine-$VER.tar.xz"
fi
[ -n "$WINE_SRC_SHA256" ] || { echo "missing WINE_SRC_SHA256 for wine-$VER.tar.xz (set in pins.env or env)"; exit 2; }
echo "$WINE_SRC_SHA256  $TARBALL" | shasum -a 256 -c - >/dev/null 2>&1 \
  || { echo "sha256 mismatch for $TARBALL (expected $WINE_SRC_SHA256)"; exit 1; }
echo "[build-winemac-so] source sha256 verified"
rm -rf "wine-$VER"; tar xf "$TARBALL"
cd "wine-$VER"

echo "[build-winemac-so] applying ${PATCHFILE##*/}"
patch -p1 < "$PATCHFILE"
grep -q "$MARKER" dlls/winemac.drv/cocoa_app.m || { echo "patch did not apply (marker '$MARKER' absent)"; exit 1; }

# --without-freetype: winemac.so links no FreeType, and an arm64 Homebrew has no x86_64 FreeType,
# which would otherwise abort an x86_64 configure. Other optional libs only warn.
echo "[build-winemac-so] configure (x86_64)"
arch -x86_64 ./configure --enable-archs=i386,x86_64 --without-x --disable-tests --without-freetype \
  >configure.out 2>&1 || { tail -25 configure.out; echo "configure failed"; exit 1; }

echo "[build-winemac-so] building tools"
arch -x86_64 make -j"$(sysctl -n hw.ncpu)" __tooldeps__ >build.out 2>&1 || { tail -25 build.out; echo "tooldeps failed"; exit 1; }

echo "[build-winemac-so] building dlls/winemac.drv/winemac.so"
arch -x86_64 make -j"$(sysctl -n hw.ncpu)" dlls/winemac.drv/winemac.so >>build.out 2>&1 \
  || { tail -30 build.out; echo "winemac.so build failed"; exit 1; }

SO="dlls/winemac.drv/winemac.so"
[ -f "$SO" ] || { echo "winemac.so not produced"; exit 1; }
# Hard arch guard: never ship a non-x86_64 module into the osx64 bundle.
a="$(lipo -archs "$SO" 2>/dev/null || true)"
[ "$a" = "x86_64" ] || { echo "built winemac.so is '$a', not x86_64 — refusing (need Rosetta/x86_64 build)"; exit 1; }
# Drift guard: the patched selectors must be present.
strings "$SO" | grep -F "$MARKER" >/dev/null || { echo "patch marker '$MARKER' missing in built winemac.so"; exit 1; }
# Match the Gcenx bundle's install_name exactly (it ships plain 'winemac.so'; vanilla uses @rpath).
# Harmless either way (Wine dlopens by path), but keeps the swap a byte-for-byte-intent drop-in.
install_name_tool -id winemac.so "$SO" 2>/dev/null || true

mkdir -p "$OUT/x86_64-unix"
cp "$SO" "$OUT/x86_64-unix/winemac.so"
echo "[build-winemac-so] done -> $OUT/x86_64-unix/winemac.so ($(lipo -archs "$OUT/x86_64-unix/winemac.so"))"
