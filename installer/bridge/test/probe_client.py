#!/usr/bin/env python3
"""probe_client.py — drives the relay like RS3 would, over loopback only.

Sends a token to the relay's loopback listener and checks the fake dash's prefixed
echo comes back. Exits 0 on a correct round trip, nonzero otherwise.

Usage: probe_client.py <tcp|udp> <listen_port> <token>
"""
import socket
import sys

EXPECT_PREFIX = b"DASH:"
TIMEOUT = 5.0


def probe_tcp(port: int, token: bytes) -> int:
    with socket.create_connection(("127.0.0.1", port), timeout=TIMEOUT) as s:
        s.settimeout(TIMEOUT)
        s.sendall(token)
        got = s.recv(65536)
    return _check(got, token)


def probe_udp(port: int, token: bytes) -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(TIMEOUT)
    s.sendto(token, ("127.0.0.1", port))
    got, _ = s.recvfrom(65536)
    return _check(got, token)


def _check(got: bytes, token: bytes) -> int:
    want = EXPECT_PREFIX + token
    if got == want:
        return 0
    sys.stderr.write(f"mismatch: got {got!r} want {want!r}\n")
    return 1


def main() -> int:
    if len(sys.argv) != 4:
        sys.stderr.write("usage: probe_client.py <tcp|udp> <listen_port> <token>\n")
        return 2
    proto, port, token = sys.argv[1], int(sys.argv[2]), sys.argv[3].encode()
    if proto == "tcp":
        return probe_tcp(port, token)
    if proto == "udp":
        return probe_udp(port, token)
    sys.stderr.write(f"invalid protocol: {proto!r}; expected 'tcp' or 'udp'\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())
