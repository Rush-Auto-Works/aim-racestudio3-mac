#!/bin/bash
# test-bridge-concurrent.sh — many simultaneous TCP connections through the relay.
# RS3 uses 2 concurrent connections (control + data); this drives 12 at once to confirm the
# relay's per-accept fan-out keeps each stream's bytes correct (no cross-talk, no dropped conns).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$HERE/test"; BIN="$HERE/build/aim-bridge"
D_TCP=24050; D_UDP=24051; R_TCP=24052; R_UDP=24053; N=12

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
PIDS=(); trap 'for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null||true; done' EXIT

SKIP_SIGN=1 bash "$HERE/build-bridge.sh" >/dev/null 2>&1 && [ -x "$BIN" ] && ok "built" || { bad build; exit 1; }
python3 "$T/fake_dash.py" "$D_TCP" "$D_UDP" & PIDS+=($!)
DASH_ADDR=127.0.0.1 TCP_LISTEN_PORT=$R_TCP TCP_DASH_PORT=$D_TCP UDP_LISTEN_PORT=$R_UDP UDP_DASH_PORT=$D_UDP "$BIN" & PIDS+=($!)
for _ in $(seq 1 30); do python3 -c "import socket;socket.create_connection(('127.0.0.1',$R_TCP),0.2).close()" 2>/dev/null && break; sleep 0.1; done

if python3 "$T/concurrent_client.py" "$R_TCP" "$N"; then ok "$N concurrent connections all round-tripped"; else bad "concurrent round-trip"; fi

echo "bridge-concurrent: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
