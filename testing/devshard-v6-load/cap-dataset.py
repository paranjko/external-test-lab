#!/usr/bin/env python3
"""Fit a captured request dataset to a model with a short context: drop long prompts, cap max_tokens.

Usage: cap-dataset.py <input.jsonl> <output.jsonl> [max_tokens=512] [max_prompt_chars=6000]
"""
import json, sys

src, dst = sys.argv[1], sys.argv[2]
max_tokens = int(sys.argv[3]) if len(sys.argv) > 3 else 512
max_chars = int(sys.argv[4]) if len(sys.argv) > 4 else 6000

kept = total = 0
with open(src) as f, open(dst, "x") as out:
    for line in f:
        sample = json.loads(line)
        total += 1
        chars = sum(len(m["content"]) if isinstance(m.get("content"), str) else len(json.dumps(m.get("content")))
                    for m in sample["messages"])
        if chars > max_chars:
            continue
        sample["max_tokens"] = min(sample.get("max_tokens") or max_tokens, max_tokens)
        out.write(json.dumps(sample, ensure_ascii=False) + "\n")
        kept += 1
print(f"kept {kept} of {total} samples, max_tokens {max_tokens}, prompts up to {max_chars} chars")
