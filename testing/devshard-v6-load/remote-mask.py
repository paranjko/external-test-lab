#!/usr/bin/env python3
"""Mask a stream line by line: a public IPv4 becomes a hash salted by MASK_SALT, a private one stays,
values after secret words and of secret-like env names are hidden.

Usage: <command> | MASK_SALT=<hex> remote-mask.py
       remote-mask.py --check    (no output and exit 0 when every case passes)
"""
import hashlib
import os
import re
import sys

ip = re.compile(r"(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?![\d.])")
private = re.compile(r"(10\.|127\.|0\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)")
auth = re.compile(r"(?i)(authorization:\s*)\S+(?:\s+[^\s\"',]+)?")
secret = re.compile(r"(?i)(bearer\s+|(?:api[_-]?key|password|secret|token)[\"'=:\s]+)[^\s\"',]+")
# The same words as the env filter of the inspect output; upper case only, so log fields like prompt_tokens stay.
named = re.compile(r"\b([A-Z0-9_]*(?:KEY|SECRET|TOKEN|PASS|PRIVATE|CRED)[A-Z0-9_]*[\"']?\s*[=:]\s*)"
                   r"(?:\"[^\"]*\"|'[^']*'|[^\s\"',]+)")


def mask(line, salt):
    def one(m):
        a = m.group(0)
        return a if private.match(a) else "ip-" + hashlib.sha256(salt + a.encode()).hexdigest()[:8]
    line = auth.sub(r"\1<hidden>", ip.sub(one, line))
    return secret.sub(r"\1<hidden>", named.sub(r"\1<hidden>", line))


def check():
    hidden = [
        "      - PRIVATE_KEY=x1y2z3",
        '      CREDENTIALS_JSON: "x1y2z3 with spaces"',
        "      GONKA_PRIVATE_MNEMONIC: 'x1y2z3 with spaces'",
        "      - CREDENTIAL_FILE=/run/x1y2z3",
        '  "Env": ["PROXY_TOKEN=x1y2z3", "DB_PASSWORD=x1y2z3"],',
        "Authorization: Bearer x1y2z3",
        '{"api_key": "x1y2z3"}',
    ]
    kept = ["max_tokens=512", '"prompt_tokens": 12', "      - PROXY_IMAGE=ghcr.io/gonka/proxy:v6", "peer 10.1.2.3"]
    bad = [c for c in hidden if "x1y2z3" in mask(c, b"check")]
    bad += [c for c in kept if mask(c, b"check") != c]
    if "203.0.113.7" in mask("peer 203.0.113.7", b"check"):
        bad.append("peer 203.0.113.7")
    for c in bad:
        print("FAIL", c)
    return 1 if bad else 0


if sys.argv[1:] == ["--check"]:
    sys.exit(check())
salt = os.environ["MASK_SALT"].encode()
for raw in sys.stdin.buffer:
    sys.stdout.buffer.write(mask(raw.decode("utf-8", "replace"), salt).encode())
    sys.stdout.buffer.flush()
