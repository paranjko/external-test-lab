#!/usr/bin/env python3
"""Bind the embedded inferenced build in the pinned DAPI Dockerfile."""

from __future__ import annotations

import argparse
from pathlib import Path


ARG_ANCHOR = "ARG LDFLAGS\nRUN --mount=type=cache,id=go-build-cache3"
PATCHED_ARG_ANCHOR = (
    "ARG LDFLAGS\nARG INFERENCED_LDFLAGS\n"
    "RUN --mount=type=cache,id=go-build-cache3"
)
UPSTREAM_LDFLAGS = (
    '-ldflags "-X github.com/cosmos/cosmos-sdk/version.Name=inference-chain '
    '-X github.com/cosmos/cosmos-sdk/version.AppName=inference-chaind"'
)
REVIEWED_LDFLAGS = '-ldflags "$INFERENCED_LDFLAGS"'


class PatchError(RuntimeError):
    pass


def patch_dockerfile(source: Path, output: Path) -> None:
    rendered = source.read_text(encoding="utf-8")
    if rendered.count(ARG_ANCHOR) != 1:
        raise PatchError("pinned DAPI Dockerfile LDFLAGS argument anchor drifted")
    if rendered.count(UPSTREAM_LDFLAGS) != 1:
        raise PatchError("pinned DAPI embedded inferenced LDFLAGS anchor drifted")
    rendered = rendered.replace(ARG_ANCHOR, PATCHED_ARG_ANCHOR)
    rendered = rendered.replace(UPSTREAM_LDFLAGS, REVIEWED_LDFLAGS)
    output.write_text(rendered, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    patch_dockerfile(args.source, args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
