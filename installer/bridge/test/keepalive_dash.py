#!/usr/bin/env python3
"""keepalive_dash.py — realistic AiM-dash stand-in (models the real failure mode).

The simple echo dash (fake_dash.py) proves round-trips but NOT the behavior that
actually breaks bridges: per promiscuous-slurp's KeepaliveMaintainer, the dash's TCP
port 2000 stays usable only while UDP aim-ka keepalives keep arriving, and the dash
drops TCP connections ~1s after the last keepalive. A session must therefore keep
sending keepalives the whole time — and the bridge must forward them reliably across
its two hops or the dash hangs up mid-transfer.

This dash:
  - UDP: every datagram refreshes `last_ka` and gets a short ack.
  - TCP: echoes data (stands in for download/upload) ONLY while keepalives are fresh;
    a watcher closes live connections, and new ones are refused-by-immediate-close,
    once `last_ka` is older than close_after_s.

Usage: keepalive_dash.py <tcp_port> <udp_port> [close_after_s]
"""
import socket
import sys
import threading
import time

last_ka = 0.0
lock = threading.Lock()


def fresh(close_after: float) -> bool:
    with lock:
        return (time.monotonic() - last_ka) <= close_after


def serve_udp(port: int) -> None:
    global last_ka
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    while True:
        data, addr = s.recvfrom(4096)
        with lock:
            last_ka = time.monotonic()
        s.sendto(b"ack", addr)


def handle_tcp(conn: socket.socket, close_after: float) -> None:
    conn.settimeout(0.5)
    with conn:
        while True:
            if not fresh(close_after):
                return  # dash drops the connection once keepalives go stale
            try:
                data = conn.recv(65536)
            except socket.timeout:
                continue
            if not data:
                return
            try:
                conn.sendall(data)  # echo = stand-in for download/upload bytes
            except OSError:
                return


def serve_tcp(port: int, close_after: float) -> None:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    s.listen(8)
    while True:
        conn, _ = s.accept()
        threading.Thread(target=handle_tcp, args=(conn, close_after), daemon=True).start()


def main() -> None:
    tcp_port, udp_port = int(sys.argv[1]), int(sys.argv[2])
    close_after = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
    threading.Thread(target=serve_udp, args=(udp_port,), daemon=True).start()
    threading.Thread(target=serve_tcp, args=(tcp_port, close_after), daemon=True).start()
    threading.Event().wait()


if __name__ == "__main__":
    main()
