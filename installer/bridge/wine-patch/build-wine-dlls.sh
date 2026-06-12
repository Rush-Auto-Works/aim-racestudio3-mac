#!/bin/bash
# build-wine-dlls.sh — build the patched Wine PE DLLs that make RaceStudio 3 reach an AiM dash
# over WiFi under Wine on macOS 15+/26 (the Local Network gate). Two DLLs, both required:
#
#   ws2_32.dll  — redirects the dash subnet 10.0.0.0/24 AND the discovery target 0.0.0.0:36002
#                 to 127.0.0.1 (port 36002->36003), and rewrites the relay's reply source back
#                 to 10.0.0.1 so RS3 accepts it. (ws2_32-localnet.patch)
#   wlanapi.dll — presents one synthetic, connected Wi-Fi interface so RS3 starts dash discovery
#                 at all (Wine's wlanapi reports zero interfaces). (wlanapi-synth-iface.patch)
#
# Produces only these two PE DLLs — NOT a full Wine. They are swapped into the prebuilt Gcenx
# bundle (lib/wine/{x86_64,i386}-windows/) by build-apps.sh. ABI-compatible with the pinned
# wine-staging build (same Wine version; the PE ABI is stable within a version).
#
# Deps: mingw-w64, bison, flex (brew). Usage: build-wine-dlls.sh [wine_version]
# Output: $OUT/{x86_64,i386}-windows/{ws2_32,wlanapi}.dll  (OUT defaults to ./build/wine-dlls)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_PINS="$HERE/../../src/pins.env"

# DLL -> patch file -> marker string that must appear in the built DLL (drift guard).
DLLS=( ws2_32 wlanapi )
declare -A PATCHFILE=( [ws2_32]="$HERE/ws2_32-localnet.patch" [wlanapi]="$HERE/wlanapi-synth-iface.patch" )
declare -A PATCHED_FILE=( [ws2_32]="dlls/ws2_32/socket.c" [wlanapi]="dlls/wlanapi/main.c" )
declare -A MARKER=( [ws2_32]="AiM: redirecting" [wlanapi]="AiM synthetic" )

VER="${1:-}"
if [ -z "$VER" ] && [ -f "$SRC_PINS" ]; then
  VER="$(sed -nE 's/^WINE_PINNED_VER="(.*)"/\1/p' "$SRC_PINS")"
fi
VER="${VER:?wine version not given and not found in pins.env}"
MAJOR="${VER%%.*}"

OUT="${OUT:-$HERE/build/wine-dlls}"
WORK="${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/wine-dlls.XXXXXX")}"
ARCHS="${ARCHS:-i386,x86_64}"   # the bundle ships both; RS3-64 needs x86_64

echo "[build-wine-dlls] wine $VER, archs $ARCHS, dlls ${DLLS[*]}"
for t in x86_64-w64-mingw32-gcc bison flex curl; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing dep: $t (brew install mingw-w64 bison flex)"; exit 2; }
done
export PATH="$(brew --prefix bison 2>/dev/null)/bin:$(brew --prefix flex 2>/dev/null)/bin:$PATH"

cd "$WORK"
TARBALL="wine-$VER.tar.xz"
if [ ! -f "$TARBALL" ]; then
  echo "[build-wine-dlls] fetching source"
  curl -fsSL -o "$TARBALL" "https://dl.winehq.org/wine/source/$MAJOR.x/wine-$VER.tar.xz"
fi
rm -rf "wine-$VER"; tar xf "$TARBALL"
cd "wine-$VER"

for dll in "${DLLS[@]}"; do
  echo "[build-wine-dlls] applying ${PATCHFILE[$dll]##*/}"
  patch -p1 < "${PATCHFILE[$dll]}"
  grep -q 'AiM' "${PATCHED_FILE[$dll]}" || { echo "patch did not apply for $dll"; exit 1; }
done

echo "[build-wine-dlls] configure"
./configure --enable-archs="$ARCHS" --without-x --disable-tests >configure.out 2>&1 \
  || { tail -20 configure.out; echo "configure failed"; exit 1; }

echo "[build-wine-dlls] building tools"
make -j"$(sysctl -n hw.ncpu)" __tooldeps__ >build.out 2>&1
mkdir -p "$OUT"
IFS=',' read -ra A <<< "$ARCHS"
for arch in "${A[@]}"; do
  mkdir -p "$OUT/${arch}-windows"
  for dll in "${DLLS[@]}"; do
    tgt="dlls/${dll}/${arch}-windows/${dll}.dll"
    make -j"$(sysctl -n hw.ncpu)" "$tgt" >>build.out 2>&1 || { tail -25 build.out; echo "build $tgt failed"; exit 1; }
    # plain grep (NOT -q): under `set -o pipefail`, grep -q exits early -> strings gets SIGPIPE
    # -> the pipeline reports failure even on a match. grep without -q reads all input, no SIGPIPE.
    strings "$tgt" | grep -F "${MARKER[$dll]}" >/dev/null || { echo "patch marker missing in $tgt"; exit 1; }
    cp "$tgt" "$OUT/${arch}-windows/${dll}.dll"
    echo "[build-wine-dlls] built $OUT/${arch}-windows/${dll}.dll"
  done
done
echo "[build-wine-dlls] done -> $OUT"
