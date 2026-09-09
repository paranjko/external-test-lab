#!/usr/bin/env python3
"""Regression tests for candidate Dockerfile dependency-download retrying."""

from __future__ import annotations

import importlib.util
import subprocess
import tempfile
from pathlib import Path


SCRIPT = Path(__file__).resolve().with_name("patch-candidate-go-mod-download.py")
SPEC = importlib.util.spec_from_file_location("patch_candidate_go_mod", SCRIPT)
assert SPEC and SPEC.loader
patching = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(patching)


def main() -> None:
    with tempfile.TemporaryDirectory(dir=SCRIPT.parent) as temporary_name:
        temporary = Path(temporary_name)
        source = temporary / "Dockerfile"
        output = temporary / "Dockerfile.patched"
        source.write_text(
            "RUN --mount=type=cache,target=/go/pkg/mod go mod download\n"
            "RUN CGO_ENABLED=1 CC=gcc go mod download\n",
            encoding="utf-8",
        )
        assert patching.patch_dockerfile(source, output) == 2
        rendered = output.read_text(encoding="utf-8")
        assert rendered.count(patching.MARKER) == 2
        assert rendered.count("attempt in 1 2 3") == 2
        assert rendered.count("candidate dependency download failed") == 2
        assert "(CGO_ENABLED=1 CC=gcc go mod download)" in rendered
        subprocess.run(
            ["sh", "-n", "-c", rendered.splitlines()[1].removeprefix("RUN ")],
            check=True,
        )

        try:
            patching.patch_dockerfile(output, temporary / "second")
        except patching.PatchError as exc:
            assert "already patched" in str(exc)
        else:
            raise AssertionError("already patched Dockerfile was accepted")

        no_download = temporary / "Dockerfile.no-download"
        no_download.write_text("FROM scratch\n", encoding="utf-8")
        try:
            patching.patch_dockerfile(no_download, temporary / "missing")
        except patching.PatchError as exc:
            assert "no dependency download anchor" in str(exc)
        else:
            raise AssertionError("Dockerfile without dependency download was accepted")

    print("PASS candidate Go module download retry contract")


if __name__ == "__main__":
    main()
