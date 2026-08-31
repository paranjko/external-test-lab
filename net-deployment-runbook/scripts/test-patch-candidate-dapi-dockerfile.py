#!/usr/bin/env python3
"""Regression tests for legacy candidate DAPI build-metadata patching."""

from __future__ import annotations

import importlib.util
import tempfile
from pathlib import Path


SCRIPT = Path(__file__).resolve().with_name("patch-candidate-dapi-dockerfile.py")
SPEC = importlib.util.spec_from_file_location("patch_candidate_dapi", SCRIPT)
assert SPEC and SPEC.loader
patching = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(patching)


def main() -> None:
    with tempfile.TemporaryDirectory() as temporary_name:
        temporary = Path(temporary_name)
        source = temporary / "Dockerfile"
        output = temporary / "Dockerfile.patched"
        source.write_text(
            "ARG LDFLAGS\n"
            "RUN --mount=type=cache,id=go-build-cache3,target=/cache true\n"
            "RUN go build -ldflags \"-X github.com/cosmos/cosmos-sdk/version.Name=inference-chain "
            "-X github.com/cosmos/cosmos-sdk/version.AppName=inference-chaind\" ./cmd\n",
            encoding="utf-8",
        )
        patching.patch_dockerfile(source, output)
        rendered = output.read_text(encoding="utf-8")
        assert "ARG INFERENCED_LDFLAGS" in rendered
        assert '-ldflags "$INFERENCED_LDFLAGS"' in rendered
        assert "inference-chaind" not in rendered

        try:
            patching.patch_dockerfile(output, temporary / "second")
        except patching.PatchError as exc:
            assert "anchor drifted" in str(exc)
        else:
            raise AssertionError("already patched DAPI Dockerfile was accepted")

    print("PASS legacy candidate DAPI Dockerfile metadata binding")


if __name__ == "__main__":
    main()
