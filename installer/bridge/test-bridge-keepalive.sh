#!/bin/bash
# test-bridge-keepalive.sh — realistic relay test against a keepalive-gated dash.
#
# Proves what the simple echo test (test-bridge.sh) cannot: the relay forwards UDP aim-ka
# keepalives reliably enough across its two hops to keep a keepalive-gated TCP session alive
# for a sustained transfer — and that when keepalives stop, the dash's ~1s TCP close is
# observed THROUGH the relay (no false "still connected"). All on loopback, no sudo, no gate.
#
#   ka_sender ─UDP→ relay ─UDP→ keepalive_dash   (keeps TCP awake)
#   ka_client ─TCP→ relay ─TCP→ keepalive_dash   (sustained transfer / upload-shaped)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$HERE/test"
BIN="$HERE/build/aim-bridge"

D_TCP=24010; D_UDP=24012; CLOSE_AFTER=1.0      # dash ports + close timer
R_TCP=24014; R_UDP=24016                        # relay listen ports (the "RS3 side")
NBYTES=262144                                   # ~256KB sustained transfer

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
PIDS=(); cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

echo "== build =="
SKIP_SIGN=1 bash "$HERE/build-bridge.sh" >/dev/null && [ -x "$BIN" ] && ok "binary built" || { bad "build"; exit 1; }

echo "== start keepalive-gated dash + relay =="
python3 "$T/keepalive_dash.py" "$D_TCP" "$D_UDP" "$CLOSE_AFTER" & PIDS+=($!)
DASH_ADDR=127.0.0.1 \
  TCP_LISTEN_PORT=$R_TCP TCP_DASH_PORT=$D_TCP \
  UDP_LISTEN_PORT=$R_UDP UDP_DASH_PORT=$D_UDP \
  "$BIN" & PIDS+=($!)
ready=0
for _ in $(seq 1 30); do
  python3 -c "import socket; socket.create_connection(('127.0.0.1',$R_TCP),0.2).close()" 2>/dev/null && { ready=1; break; }
  sleep 0.1
done
[ "$ready" = 1 ] && ok "relay listening" || { bad "relay listening"; exit 1; }

echo "== scenario A: keepalives flowing -> sustained transfer survives =="
python3 "$T/ka_sender.py" "$R_UDP" 0.4 & KA_PID=$!; PIDS+=($KA_PID)
sleep 1   # let keepalives propagate through the relay so the dash's TCP is awake
if python3 "$T/ka_client.py" "$R_TCP" "$NBYTES"; then ok "256KB transfer completed while keepalives flow"; else bad "transfer should have completed with keepalives flowing"; fi

echo "== scenario B: keepalives stop -> dash drops TCP (observed through relay) =="
kill "$KA_PID" 2>/dev/null || true
sleep 1.6   # exceed close_after so the dash goes stale
if python3 "$T/ka_client.py" "$R_TCP" "$NBYTES"; then bad "transfer should NOT complete after keepalives stopped"; else ok "dash dropped TCP once keepalives went stale (relay surfaced it)"; fi

echo "bridge-keepalive: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
