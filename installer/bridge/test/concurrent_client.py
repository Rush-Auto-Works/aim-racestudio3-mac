#!/usr/bin/env python3
"""concurrent_client.py — open N simultaneous TCP connections through the relay.

RS3 opens two concurrent TCP connections to the dash (control + data); this stresses the
relay's per-accept fan-out with N at once and checks every one round-trips its own token
(fake_dash echoes with a "DASH:" prefix). Exit 0 only if all N succeed.

Usage: concurrent_client.py <port> <n>
"""
import socket
import sys
import threading

EXPECT = b"DASH:"
results = {}


def one(port: int, i: int) -> None:
    token = f"C{i}".encode()
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=5) as s:
            s.settimeout(5)
            s.sendall(token)
            got = s.recv(4096)
        results[i] = (got == EXPECT + token)
    except OSError:
        results[i] = False


def main() -> int:
    port, n = int(sys.argv[1]), int(sys.argv[2])
    ts = [threading.Thread(target=one, args=(port, i)) for i in range(n)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    okc = sum(1 for v in results.values() if v)
    print(f"{okc}/{n} concurrent connections round-tripped")
    return 0 if okc == n else 1


if __name__ == "__main__":
    sys.exit(main())
