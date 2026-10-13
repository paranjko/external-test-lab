#!/usr/bin/env python3
"""Dispatch loopback TCP connections to the source-bound observer adapter."""

import socket
import subprocess
import threading

ADAPTER = "/usr/local/lib/gonka-devnet/network-observer-http.py"
HOST = "127.0.0.1"
PORT = 18094
LIMIT = threading.BoundedSemaphore(16)


def reject(client):
    body = b'{"error":"observer_busy"}'
    try:
        client.sendall(
            b"HTTP/1.1 503 Service Unavailable\r\n"
            b"Content-Type: application/json\r\n"
            b"Cache-Control: no-store\r\n"
            b"Connection: close\r\n"
            + f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
            + body
        )
    except OSError:
        pass


def serve(client):
    try:
        subprocess.run(
            ["/usr/bin/python3", ADAPTER],
            stdin=client,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=330,
            check=False,
            close_fds=True,
        )
    except (OSError, subprocess.TimeoutExpired):
        reject(client)
    finally:
        client.close()
        LIMIT.release()


def main():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((HOST, PORT))
        server.listen(16)
        while True:
            client, _address = server.accept()
            if not LIMIT.acquire(blocking=False):
                reject(client)
                client.close()
                continue
            threading.Thread(target=serve, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()
