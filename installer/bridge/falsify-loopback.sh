#!/bin/bash
# falsify-loopback.sh — Phase 1.5 gate: does a Wine guest's loopback traffic escape the
# macOS 15+/26 Local Network privacy gate?
#
# The entire A2 bridge architecture rests on this unverified premise. This harness falsifies
# it CHEAPLY, before any Phase 2 code: a win32 Winsock probe runs under the REAL bundled Wine
# (the exact unix-loader macOS gates) and sends a token to a native listener on 127.0.0.1.
# If the token arrives, the gate does not drop Wine's loopback traffic → premise holds.
# We also stream the `nehelper` log to see whether the gate even engages (expected: silence
# for loopback).
#
# Run on macOS 15 AND 26; record the build numbers (sw_vers) in the commit.
# Needs: zig (cross-compiles the probe, no mingw), the bundled Wine, and real system access
# (run OUTSIDE the Claude sandbox: `log stream` + Wine networking need it).
#
# Env:
#   WINE_BIN   path to the bundled `wine` (default: installed RaceStudio 3.app)
#   TCP_PORT   default 2000        UDP_PORT default 36002
#   LAN_IP     optional contrast target (a real LAN address) — also probed for comparison
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$HERE/test"
BUILD="$HERE/build"; mkdir -p "$BUILD"

WINE_BIN="${WINE_BIN:-/Applications/AiM/RaceStudio 3.app/Contents/Resources/wine/bin/wine}"
TCP_PORT="${TCP_PORT:-2000}"
UDP_PORT="${UDP_PORT:-36002}"
TOKEN="LNP$$"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }

command -v zig >/dev/null 2>&1 || { echo "zig not found (brew install zig)"; exit 77; }
[ -x "$WINE_BIN" ] || { echo "bundled wine not found at: $WINE_BIN (set WINE_BIN=)"; exit 77; }

echo "== environment =="
sw_vers | sed 's/^/  /'
echo "  wine: $WINE_BIN"

echo "== build win32 probe (zig cc) =="
PROBE="$BUILD/loopback_probe.exe"
zig cc -target x86_64-windows-gnu -O2 "$T/loopback_probe.c" -o "$PROBE" -lws2_32 \
  && ok "probe cross-compiled" || { bad "probe cross-compile"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lnp-falsify.XXXXXX")"
RECEIPTS="$WORK/received.txt"; : > "$RECEIPTS"
NEHELPER_LOG="$WORK/nehelper.log"
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT
PIDS=()

echo "== start native loopback listener =="
python3 "$T/loopback_listener.py" "$TCP_PORT" "$UDP_PORT" "$RECEIPTS" & PIDS+=($!)
ready=0
for _ in $(seq 1 30); do
  python3 -c "import socket; socket.create_connection(('127.0.0.1',$TCP_PORT),0.2).close()" 2>/dev/null && { ready=1; break; }
  sleep 0.1
done
[ "$ready" = 1 ] && ok "listener up on 127.0.0.1:$TCP_PORT/$UDP_PORT" || { bad "listener up"; exit 1; }

echo "== start nehelper log stream =="
log stream --debug --predicate 'process == "nehelper" OR subsystem == "com.apple.mdns"' \
  > "$NEHELPER_LOG" 2>/dev/null & PIDS+=($!)
sleep 2   # let the stream attach

echo "== run probe UNDER WINE (token=$TOKEN) =="
WINEPREFIX="$WORK/wineprefix" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=" \
  arch -x86_64 "$WINE_BIN" "$PROBE" 127.0.0.1 "$TCP_PORT" "$UDP_PORT" "$TOKEN" 2>&1 \
  | grep -iE 'PASS|FAIL|errno|created the conf' | sed 's/^/  probe: /'
probe_rc=${PIPESTATUS[0]}

# optional contrast: same probe to a real LAN address (expected to be gated → no receipt)
if [ -n "${LAN_IP:-}" ]; then
  echo "== contrast: probe UNDER WINE -> $LAN_IP (expected gated) =="
  WINEPREFIX="$WORK/wineprefix" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=" \
    arch -x86_64 "$WINE_BIN" "$PROBE" "$LAN_IP" "$TCP_PORT" "$UDP_PORT" "${TOKEN}LAN" 2>&1 \
    | grep -iE 'PASS|FAIL|errno' | sed 's/^/  contrast: /'
fi

sleep 2   # let datagrams + log flush
for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done

echo "== results =="
grep -q "TCP:$TOKEN" "$RECEIPTS" && ok "Wine->loopback TCP bytes ARRIVED (gate did not drop)" \
                                 || bad "Wine->loopback TCP bytes did NOT arrive"
grep -q "UDP:$TOKEN" "$RECEIPTS" && ok "Wine->loopback UDP bytes ARRIVED (gate did not drop)" \
                                 || bad "Wine->loopback UDP bytes did NOT arrive"

echo "== nehelper activity during the run (expected: little/none for loopback) =="
neh_lines=$(grep -ciE 'denied|local network|blocked|drop' "$NEHELPER_LOG" 2>/dev/null)
neh_lines=${neh_lines:-0}
echo "  nehelper gate-related lines: $neh_lines  (full log: see below if nonzero)"
[ "$neh_lines" -gt 0 ] && grep -iE 'denied|local network|blocked|drop' "$NEHELPER_LOG" | head -10 | sed 's/^/    /'

echo "falsify-loopback: $PASS passed, $FAIL failed (probe exit $probe_rc)"
if [ "$FAIL" -eq 0 ]; then
  echo "VERDICT: loopback exemption HOLDS under Wine — A2 architecture viable. Proceed to Phase 2."
else
  echo "VERDICT: loopback traffic did NOT survive under Wine — STOP. Re-evaluate; ship SD/USB import."
fi
[ "$FAIL" -eq 0 ]
