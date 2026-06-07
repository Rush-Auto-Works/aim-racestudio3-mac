#!/bin/bash
# build-ws2_32.sh — build a patched Wine ws2_32.dll (PE) that redirects the AiM dash
# subnet (10.0.0.0/28) to 127.0.0.1, so RS3-under-Wine stays on loopback (outside the
# macOS Local Network gate) and the root aim-bridge daemon relays to the real dash.
#
# Produces only ws2_32.dll (PE) — NOT a full Wine. The result is swapped into the prebuilt
# Gcenx bundle (lib/wine/{x86_64,i386}-windows/ws2_32.dll). Verified ABI-compatible with the
# pinned wine-staging build (same Wine version; ws2_32 PE ABI is stable).
#
# Deps: mingw-w64, bison, flex (brew). zig not needed here.
# Usage: build-ws2_32.sh [wine_version]   (default: RS3 pins.env WINE_PINNED_VER)
# Output: $OUT/{x86_64,i386}-windows/ws2_32.dll  (OUT defaults to ./build/ws2_32)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$HERE/ws2_32-localnet.patch"
SRC_PINS="$HERE/../../src/pins.env"

VER="${1:-}"
if [ -z "$VER" ] && [ -f "$SRC_PINS" ]; then
  VER="$(sed -nE 's/^WINE_PINNED_VER="(.*)"/\1/p' "$SRC_PINS")"
fi
VER="${VER:?wine version not given and not found in pins.env}"
MAJOR="${VER%%.*}"

OUT="${OUT:-$HERE/build/ws2_32}"
WORK="${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/wine-ws2.XXXXXX")}"
ARCHS="${ARCHS:-i386,x86_64}"   # the bundle ships both; RS3-64 needs x86_64

echo "[build-ws2_32] wine $VER, archs $ARCHS"
for t in x86_64-w64-mingw32-gcc bison flex curl; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing dep: $t (brew install mingw-w64 bison flex)"; exit 2; }
done
export PATH="$(brew --prefix bison 2>/dev/null)/bin:$(brew --prefix flex 2>/dev/null)/bin:$PATH"

cd "$WORK"
TARBALL="wine-$VER.tar.xz"
if [ ! -f "$TARBALL" ]; then
  echo "[build-ws2_32] fetching source"
  curl -fsSL -o "$TARBALL" "https://dl.winehq.org/wine/source/$MAJOR.x/wine-$VER.tar.xz"
fi
rm -rf "wine-$VER"; tar xf "$TARBALL"
cd "wine-$VER"

echo "[build-ws2_32] applying patch"
patch -p1 < "$PATCH"
grep -q 'aim_loopback_redirect' dlls/ws2_32/socket.c || { echo "patch did not apply"; exit 1; }

echo "[build-ws2_32] configure"
./configure --enable-archs="$ARCHS" --without-x --disable-tests >configure.out 2>&1 \
  || { tail -20 configure.out; echo "configure failed"; exit 1; }

echo "[build-ws2_32] building tools + ws2_32.dll"
make -j"$(sysctl -n hw.ncpu)" __tooldeps__ >build.out 2>&1
mkdir -p "$OUT"
IFS=',' read -ra A <<< "$ARCHS"
for arch in "${A[@]}"; do
  tgt="dlls/ws2_32/${arch}-windows/ws2_32.dll"
  make -j"$(sysctl -n hw.ncpu)" "$tgt" >>build.out 2>&1 || { tail -25 build.out; echo "build $tgt failed"; exit 1; }
  strings "$tgt" | grep -q 'AiM: redirecting' || { echo "patch not in $tgt"; exit 1; }
  mkdir -p "$OUT/${arch}-windows"
  cp "$tgt" "$OUT/${arch}-windows/ws2_32.dll"
  echo "[build-ws2_32] built $OUT/${arch}-windows/ws2_32.dll"
done
echo "[build-ws2_32] done -> $OUT"
