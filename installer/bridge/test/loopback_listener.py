#!/usr/bin/env python3
"""loopback_listener.py — native loopback listener for the Phase 1.5 gate test.

Plays the "RS3 side" (where the bridge would listen). Binds TCP and UDP on 127.0.0.1 and
appends every received payload to a receipt file, so the harness can prove a Wine-guest
probe's bytes actually arrived over loopback. Native (NOT under Wine) on purpose.

Usage: loopback_listener.py <tcp_port> <udp_port> <receipt_file>
"""
import socket
import sys
import threading


def record(receipt: str, line: str) -> None:
    with open(receipt, "a") as f:
        f.write(line + "\n")
        f.flush()


def serve_tcp(port: int, receipt: str) -> None:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    s.listen(8)
    while True:
        conn, _ = s.accept()
        with conn:
            data = conn.recv(4096)
            if data:
                record(receipt, "GOT " + data.decode(errors="replace"))


def serve_udp(port: int, receipt: str) -> None:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    while True:
        data, _ = s.recvfrom(4096)
        if data:
            record(receipt, "GOT " + data.decode(errors="replace"))


def main() -> None:
    tcp_port, udp_port, receipt = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    threading.Thread(target=serve_tcp, args=(tcp_port, receipt), daemon=True).start()
    threading.Thread(target=serve_udp, args=(udp_port, receipt), daemon=True).start()
    threading.Event().wait()


if __name__ == "__main__":
    main()
