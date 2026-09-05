#!/bin/bash
# test-bridge-no-dash-subnet.sh — the relay must NOT forward when the Mac has no interface on a
# dash subnet (10/11/12.0.0.x). Root resolves that from the interfaces; the non-root harness
# simulates it with an EMPTY DASH_ADDR. Off the dash Wi-Fi, "10.0.0.1" is whatever a home
# router / hotspot / carrier puts there — relaying let RS3 find a phantom device and freeze on it
# (2026-09-05). Expected: UDP from RS3 is dropped (the fake dash never sees it), TCP connects are
# closed at once (no hang), the relay stays up, and the log names the reason.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HERE/build/aim-bridge"
D_TCP=24070; D_UDP=24071; R_TCP=24072; R_UDP=24073
LOG="$(mktemp "${TMPDIR:-/tmp}/aim-bridge-nodash.XXXXXX")"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
PIDS=(); trap 'for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null||true; done; rm -f "$LOG"' EXIT

SKIP_SIGN=1 bash "$HERE/build-bridge.sh" >/dev/null 2>&1 && [ -x "$BIN" ] && ok "built" || { bad build; exit 1; }

# A "dash" IS listening on loopback — but the relay believes the Mac is off the dash subnet
# (DASH_ADDR=""), so it must never be reached. It records whether anything arrived on UDP.
python3 - "$D_UDP" >"$LOG.udp" 2>&1 <<'PY' &
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", int(sys.argv[1]))); s.settimeout(6)
try:
    d, a = s.recvfrom(65536); print("LEAKED", d)
except socket.timeout:
    print("NOTHING")
PY
PIDS+=($!)
DASH_ADDR="" TCP_LISTEN_PORT=$R_TCP TCP_DASH_PORT=$D_TCP UDP_LISTEN_PORT=$R_UDP UDP_DASH_PORT=$D_UDP "$BIN" 2>"$LOG" & RELAY=$!; PIDS+=($RELAY)
ready=0
for _ in $(seq 1 30); do
  if python3 -c "import socket;socket.create_connection(('127.0.0.1',$R_TCP),0.2).close()" 2>/dev/null; then ready=1; break; fi
  sleep 0.1
done
[ "$ready" = 1 ] && ok "relay listening" || { bad "relay never started listening"; exit 1; }

echo "== startup log says no dash subnet =="
grep -q "(none: no interface on a dash subnet)" "$LOG" && ok "startup banner shows no dash target" || bad "startup banner missing no-dash label"

echo "== TCP: connect is closed at once, not dialed =="
if python3 -c "
import socket,sys
s=socket.create_connection(('127.0.0.1',$R_TCP),timeout=3); s.settimeout(4)
ok=False
try:
    s.sendall(b'hello'); ok = (s.recv(4096) == b'')
except socket.timeout: ok=False
except OSError: ok=True
finally: s.close()
sys.exit(0 if ok else 2)
"; then ok "TCP closed immediately (no hang, no phantom dash)"; else bad "TCP hung or stayed open"; fi

echo "== UDP: discovery datagram is dropped =="
python3 -c "
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(1.5)
s.sendto(b'aim-ka-probe',('127.0.0.1',$R_UDP))
try:
    s.recvfrom(65536); raise SystemExit(2)
except socket.timeout:
    raise SystemExit(0)
" && ok "RS3 side gets no reply" || bad "RS3 side got a reply while off the dash subnet"
wait "${PIDS[0]}" 2>/dev/null
grep -q "^NOTHING" "$LOG.udp" && ok "nothing reached the dash port" || bad "datagram LEAKED to the dash port: $(cat "$LOG.udp")"

echo "== relay alive + log names the reason =="
kill -0 "$RELAY" 2>/dev/null && ok "relay still running" || bad "relay died"
grep -q "tcp: RS3 opened the control channel (#1) but NO interface on a dash subnet" "$LOG" && ok "tcp-nodash milestone logged" || bad "tcp-nodash line missing"
grep -q "udp: datagram from RS3 .* DROPPED (#1, 12B) — NO interface on a dash subnet" "$LOG" && ok "c2d-nodash milestone logged" || bad "c2d-nodash line missing"
rm -f "$LOG.udp"

echo "bridge-no-dash-subnet: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
