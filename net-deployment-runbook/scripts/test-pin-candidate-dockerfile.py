#!/usr/bin/env python3
"""Regression tests for candidate Dockerfile base-image pinning."""

from __future__ import annotations

import importlib.util
import tempfile
from pathlib import Path


SCRIPT = Path(__file__).resolve().with_name("pin-candidate-dockerfile.py")
SPEC = importlib.util.spec_from_file_location("pin_candidate_dockerfile", SCRIPT)
assert SPEC and SPEC.loader
pinning = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pinning)


def main() -> None:
    with tempfile.TemporaryDirectory() as temporary_name:
        temporary = Path(temporary_name)
        source = temporary / "Dockerfile"
        output = temporary / "Dockerfile.pinned"
        digest = "sha256:" + "a" * 64
        source.write_text(
            "FROM --platform=$TARGETPLATFORM alpine:3.23 AS runtime\n"
            "FROM runtime AS packaged\n"
            "FROM scratch AS export\n",
            encoding="utf-8",
        )
        pinning.pin_dockerfile(source, output, {"alpine:3.23": digest})
        rendered = output.read_text(encoding="utf-8")
        assert f"FROM --platform=$TARGETPLATFORM alpine:3.23@{digest} AS runtime" in rendered
        assert "FROM runtime AS packaged" in rendered
        assert "FROM scratch AS export" in rendered

        try:
            pinning.pin_dockerfile(source, output, {})
        except pinning.PinError as exc:
            assert "unreviewed Dockerfile base" in str(exc)
        else:
            raise AssertionError("tag-only unreviewed base image was accepted")

    print("PASS candidate Dockerfile bases are pinned to reviewed digests")


if __name__ == "__main__":
    main()
