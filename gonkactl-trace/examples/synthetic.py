"""Write an explicitly synthetic, offline example. Never contacts a node."""
import base64
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent / ".cache" / "synthetic"
root.mkdir(parents=True, exist_ok=True)
names = ["node0", "node1", "node2", "node3", "node4", "node5-1", "node5-2"]
keys = {name: bytes([i + 1]) * 32 for i, name in enumerate(names)}
addresses = {name: hashlib.sha256(key).hexdigest()[:40].upper() for name, key in keys.items()}
collected = "2026-01-01T00:01:00Z"
receipts = []


def save(method, height, result, query=""):
    filename = f"{method}-{height}.json"
    content = json.dumps({"result": result}, sort_keys=True, indent=2) + "\n"
    (root / filename).write_text(content, encoding="utf-8")
    receipts.append({
        "node": "node0",
        "source": f"https://synthetic.invalid/{method}?height={height}{query}",
        "path": filename,
        "collected": collected,
        "bytes": len(content.encode()),
    })


def pubkey(name):
    return {"type": "tendermint/PubKeyEd25519", "value": base64.b64encode(keys[name]).decode()}


old = {"node0": 3, "node1": 3, "node3": 3, "node4": 3}
new = {"node0": 3, "node1": 3, "node5-2": 6}
for height in [100, 101, 102]:
    powers = old if height < 102 else new
    save("validators", height, {
        "block_height": str(height), "total": str(len(powers)),
        "validators": [{"address": addresses[n], "pub_key": pubkey(n), "voting_power": str(p)} for n, p in powers.items()],
    }, "&page=1&per_page=100")
    if height == 102:
        continue
    stamp = f"2026-01-01T00:00:{height - 100:02d}Z"
    block_id = {"hash": f"{height:064X}", "parts": {"total": 1, "hash": "E" * 64}}
    save("block", height, {"block_id": block_id, "block": {"header": {"height": str(height), "time": stamp, "chain_id": "synthetic-only"}}})
    save("commit", height, {"signed_header": {"header": {"height": str(height), "time": stamp}, "commit": {
        "height": str(height), "round": 0, "block_id": block_id,
        "signatures": [{"validator_address": addresses[n], "block_id_flag": 2, "timestamp": stamp, "signature": "SYNTHETIC-NOT-A-VALID-SIGNATURE"} for n in old],
    }}})
    save("block_results", height, {"height": str(height), "validator_updates": [
        {"pub_key": pubkey(n), "power": str(new.get(n, 0))} for n in ["node3", "node4", "node5-2"]
    ] if height == 100 else []})

save("consensus_state", 102, {"round_state": {"height/round/step": "102/0/4", "height_vote_set": []}})

dataset = {
    "config": {"incident": "SYNTHETIC DEMO - NOT INCIDENT EVIDENCE", "chain": "synthetic-only", "nodes": [{"id": "node0"}],
               "identity_labels": [{"node": n, "validator": addresses[n], "source": "Synthetic example label; no real participant or signature"} for n in names]},
    "from": 100, "to": 101, "collected": collected, "receipts": receipts,
}
(root / "dataset.json").write_text(json.dumps(dataset, sort_keys=True, indent=2) + "\n", encoding="utf-8")
print(root / "dataset.json")
