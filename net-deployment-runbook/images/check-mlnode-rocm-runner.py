#!/usr/bin/env python3
"""Exercise adapted MLNode command construction and the system vLLM parser."""

import json
import shlex
import subprocess
from pathlib import Path
from contextlib import ExitStack
from pathlib import Path
from unittest.mock import patch

import vllm
from api.inference.vllm.runner import VLLMRunner
import vllm


vllm_root = Path(vllm.__file__).resolve().parent
required_poc_markers = (
    ("poc/poc_model_runner.py", "_create_v1_attn_metadata"),
    ("poc/poc_model_runner.py", "blocks_per_seq"),
)
for relative_path, marker in required_poc_markers:
    source = (vllm_root / relative_path).read_text()
    assert marker in source, f"missing v0.23 PoC marker {marker} in {relative_path}"


vllm_root = Path(vllm.__file__).resolve().parent
required_poc_markers = (
    ("poc/poc_model_runner.py", "_create_v1_attn_metadata"),
    ("poc/poc_model_runner.py", "blocks_per_seq"),
)
for relative_path, marker in required_poc_markers:
    source = (vllm_root / relative_path).read_text()
    assert marker in source, f"missing v0.23 PoC marker {marker} in {relative_path}"


runner = VLLMRunner("probe")
captured = []
fake_process = type("Process", (), {"pid": 1})()
runner._wait_for_server = lambda: True

with ExitStack() as stack:
    stack.enter_context(patch("api.inference.vllm.runner.torch.cuda.device_count", return_value=1))
    stack.enter_context(patch("api.inference.vllm.runner.setup_vllm_proxy"))
    stack.enter_context(patch(
        "api.inference.vllm.runner.subprocess.Popen",
        side_effect=lambda command, **kwargs: captured.append(command) or fake_process,
    ))
    runner.start()

assert len(captured) == 1, captured
assert captured[0][:2] == ["sh", "-c"], captured[0]
command = shlex.split(captured[0][2])
module_index = command.index("-m")
assert command[module_index + 1] == "vllm.entrypoints.openai.api_server", command
server_args = command[module_index + 2:]

parser_program = """
import json
import sys
from vllm.entrypoints.openai.cli_args import make_arg_parser
from vllm.utils.argparse_utils import FlexibleArgumentParser
from vllm.platforms import current_platform
from unittest.mock import patch
args = json.loads(sys.argv[1])
with patch.object(current_platform, "device_type", "cpu"):
    parser = make_arg_parser(FlexibleArgumentParser())
    parsed = parser.parse_args(args)
    assert parsed.attention_backend == "ROCM_ATTN", parsed.attention_backend
without_backend = []
index = 0
while index < len(args):
    if args[index] == "--attention-backend":
        index += 2
        continue
    if not args[index].startswith("--attention-backend="):
        without_backend.append(args[index])
    index += 1
assert parser.parse_args(without_backend).attention_backend != "ROCM_ATTN"
try:
    parser.parse_args(args + ["--gdc-invalid-smoke-option"])
except SystemExit as error:
    assert error.code == 2, error.code
else:
    raise AssertionError("real parser accepted an unknown option")
print("CPU parser smoke: hardware discovery stubbed; ROCM_ATTN preserved")
"""
subprocess.run(
    [runner.vllm_python_path, "-c", parser_program, json.dumps(server_args)],
    check=True,
)
