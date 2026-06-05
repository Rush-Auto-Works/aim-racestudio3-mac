#!/bin/bash
# test-bridge.sh — hermetic round-trip test for the aim-bridge loopback relay.
#
# No hardware, no LAN, no Local Network gate: a fake dash, the relay, and the probe client
# all live on 127.0.0.1. Proves bytes survive the full path RS3 -> relay -> dash -> relay -> RS3
# for BOTH the TCP control/data port and the UDP discovery port. Ports are >1024 (no sudo) and
# the "dash" is loopback (no gate), so this runs unprivileged in CI.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$HERE/test"
BIN="$HERE/build/aim-bridge"

# Fixed high ports for the test wiring (relay listen vs fake-dash listen must differ).
TCP_LISTEN=24000; TCP_DASH=24001
UDP_LISTEN=24002; UDP_DASH=24003

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }

PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

echo "== build =="
SKIP_SIGN=1 bash "$HERE/build-bridge.sh" >/dev/null || { bad "build"; echo "bridge: $PASS passed, $((FAIL+1)) failed"; exit 1; }
[ -x "$BIN" ] && ok "binary built" || bad "binary built"

echo "== start fake dash + relay =="
python3 "$T/fake_dash.py" "$TCP_DASH" "$UDP_DASH" & PIDS+=($!)
DASH_ADDR=127.0.0.1 \
  TCP_LISTEN_PORT=$TCP_LISTEN TCP_DASH_PORT=$TCP_DASH \
  UDP_LISTEN_PORT=$UDP_LISTEN UDP_DASH_PORT=$UDP_DASH \
  "$BIN" & PIDS+=($!)

# Wait until the relay's TCP listener is actually accepting (poll, don't fixed-sleep).
ready=0
for _ in $(seq 1 30); do
  if python3 -c "import socket,sys; socket.create_connection(('127.0.0.1',$TCP_LISTEN),0.2).close()" 2>/dev/null; then
    ready=1; break
  fi
  sleep 0.1
done
[ "$ready" = 1 ] && ok "relay listening" || bad "relay listening"

echo "== round trips =="
if python3 "$T/probe_client.py" tcp "$TCP_LISTEN" "hello-tcp-12345"; then ok "TCP round trip via relay"; else bad "TCP round trip via relay"; fi
if python3 "$T/probe_client.py" udp "$UDP_LISTEN" "aim-ka-probe"; then ok "UDP round trip via relay"; else bad "UDP round trip via relay"; fi

echo "bridge: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
