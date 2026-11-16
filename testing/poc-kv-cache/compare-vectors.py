#!/usr/bin/env python3
"""Compare the PoC vectors of two artifact files nonce by nonce, or cut an artifact to an evenly spread subset.

compare-vectors.py A.json B.json [--threshold 0.4]
compare-vectors.py --subset 20 A.json --out S.json

Artifacts are the files make_artifact.py writes: base64 little-endian float16 vectors per nonce.
"""
import argparse
import base64
import json
import math
import statistics
import struct
import sys


def vectors(path):
    artifact = json.load(open(path, encoding="utf-8"))
    out = {}
    for piece in artifact["artifacts"]:
        raw = base64.b64decode(piece["vector_b64"])
        out[int(piece["nonce"])] = struct.unpack(f"<{len(raw) // 2}e", raw)
    return artifact, out


def l2(a, b):
    return math.sqrt(sum((x - y) ** 2 for x, y in zip(a, b)))


def unit(v):
    n = math.sqrt(sum(x * x for x in v)) or 1.0
    return [x / n for x in v]


def compare(path_a, path_b, threshold):
    _, a = vectors(path_a)
    _, b = vectors(path_b)
    common = sorted(set(a) & set(b))
    if not common:
        sys.exit("no common nonces")
    raw = [l2(a[n], b[n]) for n in common]
    norm = [l2(unit(a[n]), unit(b[n])) for n in common]
    print(f"A: {path_a}\nB: {path_b}\nnonces: {len(common)}")
    for name, values in (("raw", raw), ("unit", norm)):
        q = sorted(values)
        print(f"{name:4} L2  min {q[0]:.4f}  median {statistics.median(q):.4f}  p95 {q[int(0.95 * (len(q) - 1))]:.4f}"
              f"  max {q[-1]:.4f}  above {threshold}: {sum(v > threshold for v in values)}")
    print("nonce  raw     unit")
    for n, r, u in zip(common, raw, norm):
        print(f"{n:5}  {r:.4f}  {u:.4f}")


def subset(path, count, out):
    artifact = json.load(open(path, encoding="utf-8"))
    pieces = sorted(artifact["artifacts"], key=lambda p: int(p["nonce"]))
    if count > len(pieces):
        sys.exit(f"{path} has {len(pieces)} nonces, fewer than {count}")
    step = len(pieces) / count
    artifact["artifacts"] = [pieces[int(i * step)] for i in range(count)]
    json.dump(artifact, open(out, "w", encoding="utf-8"), indent=2)
    print(f"wrote {out}: nonces {[int(p['nonce']) for p in artifact['artifacts']]}")


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("files", nargs="+")
    p.add_argument("--threshold", type=float, default=0.4)
    p.add_argument("--subset", type=int)
    p.add_argument("--out")
    args = p.parse_args()
    if args.subset:
        if len(args.files) != 1 or not args.out:
            p.error("--subset takes one artifact and --out")
        subset(args.files[0], args.subset, args.out)
    elif len(args.files) == 2:
        compare(args.files[0], args.files[1], args.threshold)
    else:
        p.error("give two artifacts, or --subset N with one")


if __name__ == "__main__":
    main()
