#!/bin/bash
# test-ws2-redirect.sh — compile + run the ws2_32 redirect-logic unit test, and assert the tested
# logic still matches the shipped patch (so the two can't silently drift). Hermetic, fast, native.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HERE/build"; mkdir -p "$BUILD"
PATCH="$HERE/wine-patch/ws2_32-localnet.patch"
SRC="$HERE/test/ws2_redirect_unit.c"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }

echo "== compile + run the redirect unit test =="
if cc -O2 -Wall -o "$BUILD/ws2_redirect_unit" "$SRC" 2>"$BUILD/ws2cc.log"; then ok "compiles"; else bad "compile (see $BUILD/ws2cc.log)"; exit 1; fi
if "$BUILD/ws2_redirect_unit"; then ok "all boundary/guard cases pass"; else bad "unit assertions"; fi

echo "== drift guard: tested logic matches the shipped patch =="
for line in \
  'b[0] == 10 && b[1] == 0 && b[2] == 0 && b[3] <= 15' \
  'd[0] = 127; d[1] = 0; d[2] = 0; d[3] = 1;' \
  'addr->sa_family == AF_INET'; do
  if grep -Fq "$line" "$SRC" && grep -Fq "$line" "$PATCH"; then ok "patch matches: ${line:0:32}…"
  else bad "drift: '$line' not in both unit test and patch"; fi
done

echo "ws2-redirect: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
