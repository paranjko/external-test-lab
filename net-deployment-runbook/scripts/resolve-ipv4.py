#!/usr/bin/env python3
"""Resolve unique IPv4 stream addresses with the workstation's native resolver."""
import socket
import sys


def resolve(host):
    return sorted({row[4][0] for row in socket.getaddrinfo(
        host, None, socket.AF_INET, socket.SOCK_STREAM)})


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: resolve-ipv4.py HOST")
    try:
        addresses = resolve(sys.argv[1])
        if not addresses:
            raise ValueError("no IPv4 addresses")
    except (OSError, ValueError) as error:
        sys.exit(f"IPv4 resolution failed for {sys.argv[1]}: {error}")
    print("\n".join(addresses))
