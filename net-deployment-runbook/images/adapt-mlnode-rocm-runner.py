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
        source = list(additional_args)
        args = []
        option = "--attention-backend"
        index = 0
        while index < len(source):
            argument = source[index]
            option_name = argument.split("=", 1)[0]
            is_attention_backend = (
                option_name == option
                or (
                    option_name.startswith("--attention-")
                    and option.startswith(option_name)
                )
            )
            if is_attention_backend:
                if (
                    "=" not in argument
                    and index + 1 < len(source)
                    and not source[index + 1].startswith("--")
                ):
                    index += 2
                    continue
                index += 1
                continue
            args.append(argument)
            index += 1

        args.extend([option, required])
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
