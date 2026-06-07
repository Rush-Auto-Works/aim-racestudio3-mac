#!/usr/bin/env python3
"""ka_client.py — TCP transfer probe through the bridge (stands in for an RS3 download/upload).

Connects to the BRIDGE's TCP listen port, sends <nbytes> (upload-shaped: sustained
client->dash), and reads the echo back. Exits 0 only if the FULL payload round-trips.

Usage: ka_client.py <tcp_port> <nbytes>
"""
import socket
import sys

TIMEOUT = 5.0


def main() -> int:
    port, nbytes = int(sys.argv[1]), int(sys.argv[2])
    payload = bytes((i % 251 for i in range(nbytes)))
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=TIMEOUT)
    except OSError as e:
        print(f"connect failed: {e}")
        return 1
    s.settimeout(TIMEOUT)
    got = bytearray()
    try:
        s.sendall(payload)
        while len(got) < nbytes:
            chunk = s.recv(65536)
            if not chunk:
                break  # dash closed the connection (e.g. keepalives went stale)
            got.extend(chunk)
    except OSError as e:
        print(f"transfer error after {len(got)}/{nbytes} bytes: {e}")
        return 1
    finally:
        s.close()
    if len(got) == nbytes and bytes(got) == payload:
        print(f"OK transferred {nbytes} bytes")
        return 0
    print(f"INCOMPLETE {len(got)}/{nbytes} bytes")
    return 1


if __name__ == "__main__":
    sys.exit(main())
