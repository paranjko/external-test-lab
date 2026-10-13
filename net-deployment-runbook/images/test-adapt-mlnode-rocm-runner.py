#!/usr/bin/env python3
"""Focused tests for the source adapter's argument contract."""

from __future__ import annotations

import argparse
import importlib.util
import tempfile
from pathlib import Path


HERE = Path(__file__).resolve().parent
ADAPTER = HERE / "adapt-mlnode-rocm-runner.py"


def load(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


adapter = load(ADAPTER, "rocm_runner_adapter")

fixture = """from typing import List, Optional
import subprocess

class VLLMRunner:
    def __init__(self, additional_args: Optional[List[str]] = None):
        self.additional_args = additional_args or []
        self.processes: List[subprocess.Popen] = []
"""

with tempfile.TemporaryDirectory() as directory:
    runner_path = Path(directory) / "runner.py"
    runner_path.write_text(fixture)
    adapter.adapt(runner_path)
    adapted_source = runner_path.read_text()
    adapter.adapt(runner_path)
    assert runner_path.read_text() == adapted_source
    module = load(runner_path, "adapted_runner")

    assert module.VLLMRunner().additional_args == [
        "--attention-backend", "ROCM_ATTN"
    ]
    assert module.VLLMRunner(
        ["--attention-backend", "ROCM_ATTN", "--max-model-len", "8"]
    ).additional_args == [
        "--max-model-len", "8", "--attention-backend", "ROCM_ATTN"
    ]
    assert module.VLLMRunner(
        ["--attention-backend=ROCM_ATTN"]
    ).additional_args == ["--attention-backend", "ROCM_ATTN"]

    overridden = [
        ["--attention-backend", "FLASHINFER"],
        ["--attention-backend=FLASHINFER"],
        ["--attention-backend="],
        ["--attention-backend"],
        ["--attention-backend", "ROCM_ATTN", "--attention-backend=ROCM_ATTN"],
        ["--attention-backen", "FLASHINFER"],
        ["--attention-backen=FLASHINFER"],
        [
            "--attention-backend", "ROCM_ATTN",
            "--attention-backen", "FLASHINFER",
        ],
    ]
    for arguments in overridden:
        assert module.VLLMRunner(arguments).additional_args == [
            "--attention-backend", "ROCM_ATTN"
        ]

    parser = argparse.ArgumentParser()
    parser.add_argument("--attention-backend")
    bypass = module.VLLMRunner([
        "--attention-backend", "ROCM_ATTN",
        "--attention-backen", "FLASHINFER",
    ]).additional_args
    assert parser.parse_args(bypass).attention_backend == "ROCM_ATTN"

    assert module.VLLMRunner(
        ["--attention-dropout", "0.1"]
    ).additional_args == [
        "--attention-dropout", "0.1", "--attention-backend", "ROCM_ATTN"
    ]

    guarded_path = Path(directory) / "changed-runner.py"
    guarded_path.write_text("class VLLMRunner:\n    pass\n")
    try:
        adapter.adapt(guarded_path)
    except SystemExit as error:
        assert "no longer matches adapter" in str(error)
    else:
        raise AssertionError("adapter accepted an unrecognized runner source")

print("PASS ROCm runner adapter argument normalization")
