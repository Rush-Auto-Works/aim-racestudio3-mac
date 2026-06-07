#!/bin/bash
# test-bridge-ctl.sh — aim-bridge-ctl behavior (compiles, valid status tokens, exit codes, usage).
# Runs standalone (not inside an installed app bundle), so the daemon is unregistered: status is
# "notFound"/"notRegistered" and registration can't succeed — we test the CONTRACT, not a live
# daemon (that's the on-device Phase 4 test).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTL="$HERE/build/aim-bridge-ctl"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
valid_status() { case "$1" in notRegistered|enabled|requiresApproval|notFound|unknown) return 0;; *) return 1;; esac; }

SKIP_SIGN=1 bash "$HERE/build-bridge.sh" >/dev/null 2>&1 && [ -x "$CTL" ] && ok "built" || { bad build; exit 1; }

echo "== status prints a valid token =="
out="$("$CTL" status 2>/dev/null)"; rc=$?
valid_status "$out" && ok "status -> '$out' (valid token)" || bad "status -> '$out' (not a known token)"
# standalone: not enabled, so nonzero exit (0 is reserved for 'enabled')
[ "$rc" -ne 0 ] && ok "status exit nonzero when not enabled ($rc)" || bad "status exit should be nonzero standalone"

echo "== no-arg defaults to status =="
out2="$("$CTL" 2>/dev/null)"; valid_status "$out2" && ok "no-arg -> '$out2'" || bad "no-arg invalid: '$out2'"

echo "== unknown subcommand -> usage, exit 2 =="
ERRF="$(mktemp "${TMPDIR:-/tmp}/ctlerr.XXXXXX")"
"$CTL" bogus >/dev/null 2>"$ERRF"; rc=$?
[ "$rc" -eq 2 ] && ok "bogus exits 2" || bad "bogus exit was $rc (want 2)"
grep -q 'usage' "$ERRF" && ok "bogus prints usage (stderr)" || bad "bogus missing usage text"
rm -f "$ERRF"

echo "== register is non-crashing + reports a status =="
out3="$("$CTL" register 2>/dev/null)"; rc=$?
valid_status "$out3" && ok "register -> '$out3' (no crash)" || bad "register output invalid: '$out3'"
[ "$rc" -ne 139 ] && ok "register did not segfault" || bad "register crashed"

echo "bridge-ctl: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
