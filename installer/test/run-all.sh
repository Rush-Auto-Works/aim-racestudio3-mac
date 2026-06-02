#!/bin/bash
# run-all.sh — run every unit/dry-run test, print a summary, exit nonzero if any failed.
# Does NOT run e2e-local.sh (that one does a real offline install; run it explicitly).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE" || exit 2

TESTS=(unit-validators.sh unit-net.sh unit-ledger.sh unit-preflight.sh unit-data.sh unit-launcher.sh dryrun-test.sh)
fail=0
for t in "${TESTS[@]}"; do
  echo "=============================================================="
  echo "RUN $t"
  if bash "$t"; then echo "PASS $t"; else echo "FAIL $t"; fail=$((fail+1)); fi
done
echo "=============================================================="
if [ "$fail" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "$fail TEST FILE(S) FAILED"; fi
exit "$fail"
