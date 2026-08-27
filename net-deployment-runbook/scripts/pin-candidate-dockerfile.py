#!/usr/bin/env python3
"""Rewrite external Dockerfile bases to reviewed candidate digests."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


FROM_RE = re.compile(r"^(\s*FROM(?:\s+--platform=\S+)?\s+)(\S+)(.*)$", re.IGNORECASE)
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
STAGE_RE = re.compile(r"\s+AS\s+(\S+)\s*$", re.IGNORECASE)


class PinError(RuntimeError):
    pass


def pin_dockerfile(source: Path, output: Path, base_images: dict[str, str]) -> None:
    for reference, digest in base_images.items():
        if not reference or not DIGEST_RE.fullmatch(digest):
            raise PinError(f"invalid reviewed base image binding: {reference}")

    stages: set[str] = set()
    pinned: list[str] = []
    external_count = 0
    for line_number, line in enumerate(source.read_text(encoding="utf-8").splitlines(), 1):
        match = FROM_RE.match(line)
        if not match:
            pinned.append(line)
            continue
        prefix, image, suffix = match.groups()
        if image.lower() == "scratch" or image in stages:
            replacement = image
        else:
            digest = base_images.get(image)
            if digest is None:
                raise PinError(
                    f"unreviewed Dockerfile base at {source}:{line_number}: {image}"
                )
            replacement = f"{image}@{digest}"
            external_count += 1
        pinned.append(f"{prefix}{replacement}{suffix}")
        stage_match = STAGE_RE.search(suffix)
        if stage_match:
            stages.add(stage_match.group(1))

    if external_count == 0:
        raise PinError(f"Dockerfile has no reviewed external base images: {source}")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(pinned) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--base-images-json", required=True)
    args = parser.parse_args()
    value = json.loads(args.base_images_json)
    if not isinstance(value, dict) or not all(
        isinstance(key, str) and isinstance(item, str) for key, item in value.items()
    ):
        raise PinError("base image bindings must be a JSON object")
    pin_dockerfile(args.source, args.output, value)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
