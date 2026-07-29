#!/usr/bin/env python3
"""
Peer speed tester for Cosmos/CometBFT nodes.
Usage: python3 peer_speed_test.py [host:port]
Default: node2.gonka.ai:8000
"""

import sys
import socket
import subprocess
import json
import time
import statistics
from concurrent.futures import ThreadPoolExecutor, as_completed

# ── Config ──────────────────────────────────────────────────────────────────
DEFAULT_RPC = "node2.gonka.ai:8000"
TOP_N       = 10
ATTEMPTS    = 3          # TCP connect attempts per peer
TIMEOUT     = 3.0        # seconds per attempt
MAX_WORKERS = 50         # parallel workers
# ────────────────────────────────────────────────────────────────────────────


def fetch_peers(rpc_host: str, rpc_port: int) -> list[dict]:
    """Fetch peer list from /net_info RPC endpoint."""
    url = f"http://{rpc_host}:{rpc_port}/chain-rpc/net_info"
    cmd = ["curl", "-s", "--max-time", "10", url]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        data = json.loads(result.stdout)
        peers = []
        for p in data["result"]["peers"]:
            node_id   = p["node_info"]["id"]
            remote_ip = p["remote_ip"]
            listen    = p["node_info"]["listen_addr"]  # e.g. tcp://0.0.0.0:26656
            parts     = listen.split(":")
            peer_port = int(parts[-1]) if parts[-1].isdigit() else 5000
            peers.append({
                "id":   node_id,
                "ip":   remote_ip,
                "port": peer_port,
            })
        return peers
    except Exception as e:
        print(f"[ERROR] Could not fetch peers: {e}", file=sys.stderr)
        sys.exit(1)


def tcp_latency_ms(ip: str, port: int) -> float | None:
    """
    Measure TCP connection latency in milliseconds.
    Returns None if connection failed.
    """
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(TIMEOUT)
        t0 = time.perf_counter()
        result = sock.connect_ex((ip, port))
        t1 = time.perf_counter()
        sock.close()
        if result == 0:
            return (t1 - t0) * 1000
        return None
    except Exception:
        return None


def test_peer(peer: dict) -> dict | None:
    """Run ATTEMPTS probes, return median latency or None if unreachable."""
    ip, port = peer["ip"], peer["port"]
    samples = []
    for _ in range(ATTEMPTS):
        ms = tcp_latency_ms(ip, port)
        if ms is not None:
            samples.append(ms)
        # small pause between attempts
        time.sleep(0.05)

    if not samples:
        return None

    return {
        **peer,
        "latency_ms": round(statistics.median(samples), 2),
        "samples":    len(samples),
    }


def main():
    rpc_arg = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_RPC
    if ":" in rpc_arg:
        rpc_host, rpc_port_str = rpc_arg.rsplit(":", 1)
        rpc_port = int(rpc_port_str)
    else:
        rpc_host, rpc_port = rpc_arg, 8000

    print(f"[*] Fetching peers from http://{rpc_host}:{rpc_port}/chain-rpc/net_info …")
    peers = fetch_peers(rpc_host, rpc_port)
    print(f"[*] Found {len(peers)} peers. Testing TCP latency ({ATTEMPTS} probes each, timeout={TIMEOUT}s) …\n")

    results = []
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        futures = {executor.submit(test_peer, p): p for p in peers}
        done = 0
        for future in as_completed(futures):
            done += 1
            print(f"\r    Progress: {done}/{len(peers)}", end="", flush=True)
            res = future.result()
            if res:
                results.append(res)

    print()  # newline after progress

    if not results:
        print("[!] No reachable peers found.")
        sys.exit(1)

    results.sort(key=lambda x: x["latency_ms"])
    top = results[:TOP_N]

    # ── Output 1: human-readable with speed ──────────────────────────────────
    print("\n" + "═" * 55)
    print(f"  TOP {TOP_N} PEERS  —  host:port, latency")
    print("═" * 55)
    print(f"  {'ADDRESS':<35}  {'LATENCY':>10}")
    print("─" * 55)
    for r in top:
        addr = f"{r['ip']}:{r['port']}"
        print(f"  {addr:<35}  {r['latency_ms']:>7.1f} ms")
    print("═" * 55)

    # ── Output 2: persistent_peers format ────────────────────────────────────
    persistent = ",".join(f"{r['id']}@{r['ip']}:{r['port']}" for r in top)
    print("\n" + "═" * 55)
    print("  PERSISTENT PEERS (copy to config.toml)")
    print("═" * 55)
    print(f"\npersistent_peers = \"{persistent}\"\n")


if __name__ == "__main__":
    main()