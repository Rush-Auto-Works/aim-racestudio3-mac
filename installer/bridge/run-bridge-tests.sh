#!/bin/bash
# run-bridge-tests.sh — run every aim-bridge test, print a summary, exit nonzero if any failed.
# Hermetic: all tests use loopback + fakes (no dash, no sudo, no gate). Run before committing
# bridge changes (the engine suite is installer/test/run-all.sh).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE" || exit 2

TESTS=(
  test-ws2-redirect.sh        # patch redirect logic (10.0.0.0/28) + drift guard
  test-patch.sh               # ws2_32 patch is well-formed + rewrites 3 entry points
  test-pack.sh                # daemon plist / label / path consistency across files
  test-bridge.sh              # basic TCP+UDP round trip through the relay
  test-bridge-keepalive.sh    # realistic keepalive-gated transfer + ~1s TCP close
  test-bridge-concurrent.sh   # many simultaneous connections (RS3 uses 2)
  test-bridge-dash-absent.sh  # graceful degradation + relay resilience when dash absent
  test-bridge-ctl.sh          # SMAppService control tool contract
)

fail=0
for t in "${TESTS[@]}"; do
  echo "=============================================================="
  echo "RUN $t"
  if bash "$t"; then echo "PASS $t"; else echo "FAIL $t"; fail=$((fail+1)); fi
done
echo "=============================================================="
[ "$fail" -eq 0 ] && echo "ALL BRIDGE TESTS PASSED" || echo "$fail BRIDGE TEST FILE(S) FAILED"
exit "$fail"
