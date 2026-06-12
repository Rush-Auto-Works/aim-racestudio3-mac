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

# DLL -> patch file / patched source / marker string that must appear in the built DLL (drift
# guard). macOS /bin/bash is 3.2 (no associative arrays), so map via case functions, not declare -A.
DLLS=( ws2_32 wlanapi )
dll_patch()  { case "$1" in ws2_32) echo "$HERE/ws2_32-localnet.patch";; wlanapi) echo "$HERE/wlanapi-synth-iface.patch";; esac; }
dll_source() { case "$1" in ws2_32) echo "dlls/ws2_32/socket.c";;        wlanapi) echo "dlls/wlanapi/main.c";;            esac; }
dll_marker() { case "$1" in ws2_32) echo "AiM: redirecting";;            wlanapi) echo "AiM synthetic";;                  esac; }

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
bison_prefix="$(brew --prefix bison)" || { echo "bison not found (brew install bison)"; exit 2; }
flex_prefix="$(brew --prefix flex)" || { echo "flex not found (brew install flex)"; exit 2; }
export PATH="$bison_prefix/bin:$flex_prefix/bin:$PATH"

cd "$WORK"
TARBALL="wine-$VER.tar.xz"
if [ ! -f "$TARBALL" ]; then
  echo "[build-wine-dlls] fetching source"
  curl -fsSL -o "$TARBALL" "https://dl.winehq.org/wine/source/$MAJOR.x/wine-$VER.tar.xz"
fi
rm -rf "wine-$VER"; tar xf "$TARBALL"
cd "wine-$VER"

for dll in "${DLLS[@]}"; do
  patchfile="$(dll_patch "$dll")"
  echo "[build-wine-dlls] applying ${patchfile##*/}"
  patch -p1 < "$patchfile"
  grep -q 'AiM' "$(dll_source "$dll")" || { echo "patch did not apply for $dll"; exit 1; }
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
    strings "$tgt" | grep -F "$(dll_marker "$dll")" >/dev/null || { echo "patch marker missing in $tgt"; exit 1; }
    cp "$tgt" "$OUT/${arch}-windows/${dll}.dll"
    echo "[build-wine-dlls] built $OUT/${arch}-windows/${dll}.dll"
  done
done
echo "[build-wine-dlls] done -> $OUT"
