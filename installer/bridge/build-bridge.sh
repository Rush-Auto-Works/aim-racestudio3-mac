#!/bin/bash
# build-bridge.sh — compile the aim-bridge loopback relay AND its SMAppService control tool.
#
# Output: installer/bridge/build/{aim-bridge, aim-bridge-ctl}
# Env:
#   CODESIGN_IDENTITY   Developer ID to sign with (default: ad-hoc "-").
#   HARDENED_RUNTIME=1  sign with the hardened runtime (release path; CI sets this).
#   SKIP_SIGN=1         compile only, do not sign (fast inner loop / tests).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/build"
mkdir -p "$OUT"

echo "compiling aim-bridge (arm64) ..."
swiftc -O -target arm64-apple-macos13.0 -o "$OUT/aim-bridge" "$HERE/aim-bridge.swift"
echo "compiling aim-bridge-ctl (arm64, ServiceManagement) ..."
swiftc -O -target arm64-apple-macos13.0 -o "$OUT/aim-bridge-ctl" "$HERE/aim-bridge-ctl.swift"

if [ "${SKIP_SIGN:-0}" = "1" ]; then
  echo "SKIP_SIGN=1 — not signing"; echo "built: $OUT/aim-bridge, $OUT/aim-bridge-ctl"; exit 0
fi

IDENT="${CODESIGN_IDENTITY:--}"
ARGS=(--force --sign "$IDENT" --options=runtime --timestamp)
if [ "${HARDENED_RUNTIME:-0}" != "1" ]; then
  # local/dev: ad-hoc, no hardened runtime, no timestamp server round-trip
  ARGS=(--force --sign "$IDENT")
fi
for bin in aim-bridge aim-bridge-ctl; do
  echo "signing $bin with identity: $IDENT"
  codesign "${ARGS[@]}" "$OUT/$bin"
done
echo "built: $OUT/aim-bridge, $OUT/aim-bridge-ctl"
