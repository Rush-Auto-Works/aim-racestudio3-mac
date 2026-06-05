#!/bin/bash
# run-all.sh — run every unit/dry-run test, print a summary, exit nonzero if any failed.
# Does NOT run e2e-local.sh (that one does a real offline install; run it explicitly).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE" || exit 2

TESTS=(unit-validators.sh unit-net.sh unit-ledger.sh unit-preflight.sh unit-data.sh unit-launcher.sh unit-wine.sh unit-pins-online.sh dryrun-test.sh)
fail=0; skip=0
for t in "${TESTS[@]}"; do
  echo "=============================================================="
  echo "RUN $t"
  bash "$t"; rc=$?
  case "$rc" in
    0)  echo "PASS $t" ;;
    77) echo "SKIP $t"; skip=$((skip+1)) ;;
    *)  echo "FAIL $t"; fail=$((fail+1)) ;;
  esac
done
echo "=============================================================="
if [ "$fail" -eq 0 ]; then echo "ALL TESTS PASSED${skip:+ ($skip skipped)}"; else echo "$fail TEST FILE(S) FAILED"; fi
exit "$fail"
