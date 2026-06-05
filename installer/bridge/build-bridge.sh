#!/bin/bash
# build-bridge.sh — compile the aim-bridge loopback relay to a signed arm64 binary.
#
# Output: installer/bridge/build/aim-bridge
# Env:
#   CODESIGN_IDENTITY   Developer ID to sign with (default: ad-hoc "-").
#   HARDENED_RUNTIME=1  sign with the hardened runtime (release path; CI sets this).
#   SKIP_SIGN=1         compile only, do not sign (fast inner loop / tests).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/build"
mkdir -p "$OUT"
BIN="$OUT/aim-bridge"

echo "compiling aim-bridge (arm64) ..."
swiftc -O -target arm64-apple-macos13.0 -o "$BIN" "$HERE/aim-bridge.swift"

if [ "${SKIP_SIGN:-0}" = "1" ]; then
  echo "SKIP_SIGN=1 — not signing"; echo "built: $BIN"; exit 0
fi

IDENT="${CODESIGN_IDENTITY:--}"
ARGS=(--force --sign "$IDENT" --options=runtime --timestamp)
if [ "${HARDENED_RUNTIME:-0}" != "1" ]; then
  # local/dev: ad-hoc, no hardened runtime, no timestamp server round-trip
  ARGS=(--force --sign "$IDENT")
fi
echo "signing with identity: $IDENT"
codesign "${ARGS[@]}" "$BIN"
codesign -dvv "$BIN" 2>&1 | grep -E 'Identifier|TeamIdentifier|flags' || true
echo "built: $BIN"
