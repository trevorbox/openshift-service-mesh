#!/usr/bin/env python3
"""TCP echo server that sends nothing until the client does.

An idle connection stays idle, so DestinationRule connectionPool.tcp.idleTimeout
can fire. Bytes in either direction reset that timer.
"""

import os
import socket
import threading

PORT = int(os.environ.get("PORT", "9000"))


def handle(conn):
    with conn:
        while True:
            data = conn.recv(4096)
            if not data:
                return
            conn.sendall(data)


def main():
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", PORT))
    sock.listen(128)
    print(f"listening on {PORT}", flush=True)
    while True:
        conn, _addr = sock.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
