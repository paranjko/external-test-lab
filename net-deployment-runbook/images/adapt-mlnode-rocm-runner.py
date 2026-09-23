#!/usr/bin/env python3
"""Guardedly bind the pinned MLNode runner to the ROCm attention backend."""

from __future__ import annotations

import argparse
from pathlib import Path


EXPECTED_CONSTRUCTOR = """        self.additional_args = additional_args or []
        self.processes: List[subprocess.Popen] = []
"""

ADAPTED_CONSTRUCTOR = """        self.additional_args = self._with_attention_backend(
            additional_args or [], "ROCM_ATTN"
        )
        self.processes: List[subprocess.Popen] = []

    @staticmethod
    def _with_attention_backend(additional_args: List[str], required: str) -> List[str]:
        args = list(additional_args)
        selected = []
        index = 0
        while index < len(args):
            argument = args[index]
            if argument == "--attention-backend":
                if index + 1 >= len(args) or args[index + 1].startswith("--"):
                    raise ValueError("--attention-backend requires a value")
                selected.append(args[index + 1])
                index += 2
                continue
            if argument.startswith("--attention-backend="):
                selected.append(argument.split("=", 1)[1])
            index += 1

        if any(value != required for value in selected):
            raise ValueError(
                f"ROCm MLNode requires --attention-backend {required}; got {selected}"
            )
        if len(selected) > 1:
            raise ValueError("duplicate --attention-backend options are not allowed")
        if not selected:
            args.extend(["--attention-backend", required])
        return args
"""


def adapt(path: Path) -> None:
    source = path.read_text()
    if ADAPTED_CONSTRUCTOR in source:
        return
    if source.count(EXPECTED_CONSTRUCTOR) != 1:
        raise SystemExit("pinned MLNode runner constructor no longer matches adapter")
    path.write_text(source.replace(EXPECTED_CONSTRUCTOR, ADAPTED_CONSTRUCTOR))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("runner", type=Path)
    args = parser.parse_args()
    adapt(args.runner)


if __name__ == "__main__":
    main()
