#!/usr/bin/env python3
"""fake_dash.py — stand-in for an AiM dash for the hermetic bridge test.

Echoes whatever it receives, with a fixed prefix so the test can prove the bytes
made the full round trip THROUGH the relay (not a loopback short-circuit). No real
hardware, no LAN, no Local Network gate involved — everything is on 127.0.0.1.

Usage: fake_dash.py <tcp_port> <udp_port>
"""
import socket
import sys
import threading

PREFIX = b"DASH:"  # proves the reply came from the fake dash via the relay


def serve_tcp(port: int) -> None:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    s.listen(8)
    while True:
        conn, _ = s.accept()
        threading.Thread(target=_tcp_conn, args=(conn,), daemon=True).start()


def _tcp_conn(conn: socket.socket) -> None:
    with conn:
        while True:
            data = conn.recv(65536)
            if not data:
                return
            conn.sendall(PREFIX + data)


def serve_udp(port: int) -> None:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    while True:
        data, addr = s.recvfrom(65536)
        s.sendto(PREFIX + data, addr)


def main() -> None:
    tcp_port, udp_port = int(sys.argv[1]), int(sys.argv[2])
    threading.Thread(target=serve_tcp, args=(tcp_port,), daemon=True).start()
    threading.Thread(target=serve_udp, args=(udp_port,), daemon=True).start()
    threading.Event().wait()  # run until killed


if __name__ == "__main__":
    main()
