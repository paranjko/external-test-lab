#!/usr/bin/env python3
"""Add bounded transient-network retries to candidate Dockerfile dependency downloads."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


MARKER = "candidate retry: go mod download"
DOWNLOAD_RE = re.compile(
    r"(?P<command>(?:[A-Z_][A-Z0-9_]*=[^\s]+\s+)*go mod download)"
)


class PatchError(RuntimeError):
    """The candidate Dockerfile cannot safely receive the retry contract."""


def patch_dockerfile(source: Path, output: Path) -> int:
    text = source.read_text(encoding="utf-8")
    if MARKER in text:
        raise PatchError(f"candidate retry anchor drifted: {source} is already patched")
    if not DOWNLOAD_RE.search(text):
        raise PatchError(f"candidate Dockerfile has no dependency download anchor: {source}")

    def replacement(match: re.Match[str]) -> str:
        command = match.group("command")
        return (
            '{ : "candidate retry: go mod download"; '
            "for attempt in 1 2 3; do "
            f"({command}) && break; "
            'if [ "$attempt" -eq 3 ]; then '
            'echo "candidate dependency download failed command=go_mod_download attempts=3" >&2; exit 1; fi; '
            'sleep "$((attempt * 3))"; '
            "done; }"
        )

    rendered, count = DOWNLOAD_RE.subn(replacement, text)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(rendered, encoding="utf-8")
    return count


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    replaced = patch_dockerfile(args.source, args.output)
    print(f"candidate Go module retry contract applied downloads={replaced}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
