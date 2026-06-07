#!/usr/bin/env python3
"""ka_sender.py — sends aim-ka UDP keepalives to a port at a fixed cadence until killed.

Stands in for RS3's background keepalive thread. Points at the BRIDGE's UDP listen port,
so the test exercises keepalive forwarding across the relay's two hops.

Usage: ka_sender.py <udp_port> [interval_s]
"""
import socket
import sys
import time

KA = b"aim-ka"


def main() -> None:
    port = int(sys.argv[1])
    interval = float(sys.argv[2]) if len(sys.argv) > 2 else 0.4
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    while True:
        try:
            s.sendto(KA, ("127.0.0.1", port))
        except OSError:
            pass
        time.sleep(interval)


if __name__ == "__main__":
    main()
