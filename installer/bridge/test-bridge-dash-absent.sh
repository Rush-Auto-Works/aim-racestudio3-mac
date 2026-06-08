#!/bin/bash
# test-bridge-dash-absent.sh — the relay must degrade gracefully when the dash isn't there.
# Cold case: RS3 launches before the dash is on WiFi. Connecting through the relay must NOT hang
# or crash the relay — the client just gets a clean close — and the relay must keep serving, so
# the next attempt (dash now present) works. This guards the "first download often fails, retry
# works" reality noted in the protocol docs.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$HERE/test"; BIN="$HERE/build/aim-bridge"
D_TCP=24060; D_UDP=24061; R_TCP=24062; R_UDP=24063

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
PIDS=(); trap 'for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null||true; done' EXIT

SKIP_SIGN=1 bash "$HERE/build-bridge.sh" >/dev/null 2>&1 && [ -x "$BIN" ] && ok "built" || { bad build; exit 1; }

# relay up, but NO dash listening on D_TCP/D_UDP yet
DASH_ADDR=127.0.0.1 TCP_LISTEN_PORT=$R_TCP TCP_DASH_PORT=$D_TCP UDP_LISTEN_PORT=$R_UDP UDP_DASH_PORT=$D_UDP "$BIN" & RELAY=$!; PIDS+=($RELAY)
ready=0
for _ in $(seq 1 30); do
  if python3 -c "import socket;socket.create_connection(('127.0.0.1',$R_TCP),0.2).close()" 2>/dev/null; then ready=1; break; fi
  sleep 0.1
done
if [ "$ready" = 1 ]; then ok "relay listening"; else bad "relay never started listening"; exit 1; fi

echo "== dash absent: client gets a clean close, no hang =="
# connect through relay; dial to absent dash fails -> relay closes our side; recv returns b"" fast.
if python3 -c "
import socket,sys
s=socket.create_connection(('127.0.0.1',$R_TCP),timeout=3); s.settimeout(4)
ok=False
try:
    s.sendall(b'hello')
    ok = (s.recv(4096) == b'')   # clean EOF once the relay's dial fails
except socket.timeout:
    ok=False                     # a hang is the only real failure
except OSError:
    ok=True                      # RST / broken pipe is also an immediate, graceful failure
finally:
    s.close()
sys.exit(0 if ok else 2)
"; then ok "immediate graceful failure when dash absent (no hang)"; else bad "connection hung when dash absent"; fi

echo "== relay survived: works once the dash appears =="
kill -0 "$RELAY" 2>/dev/null && ok "relay still running after failed dial" || bad "relay died on failed dial"
python3 "$T/fake_dash.py" "$D_TCP" "$D_UDP" & PIDS+=($!); sleep 0.5
if python3 "$T/probe_client.py" tcp "$R_TCP" "after-absent"; then ok "transfer works after dash appears"; else bad "relay did not recover"; fi

echo "bridge-dash-absent: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
