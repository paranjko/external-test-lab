#!/usr/bin/env python3
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def plan(files: list[str]) -> dict:
    with tempfile.TemporaryDirectory() as directory:
        directory = Path(directory)
        source, output = directory / "files", directory / "plan.json"
        source.write_text("\n".join(files) + "\n")
        subprocess.run([
            str(ROOT / "scripts/plan-site-preview.py"),
            "--files", str(source),
            "--base", "a" * 40,
            "--head", "b" * 40,
            "--output", str(output),
            "--repository-root", str(ROOT),
            "--endpoint-input", str(ROOT / "04-ops/edge-node/PublicCaddyfile"),
            "--endpoint-input", str(ROOT / "04-ops/render-ops.sh"),
        ], check=True)
        return json.loads(output.read_text())


assert plan(["README.md"])["mode"] == "none"
assert plan(["net-deployment-runbook/04-ops/site/src/app.js"])["mode"] == "static"
assert plan(["net-deployment-runbook/04-ops/render-ops.sh"])["mode"] == "endpoint"
both = plan(["net-deployment-runbook/04-ops/site/src/app.js", "net-deployment-runbook/04-ops/render-ops.sh"])
assert both["mode"] == "combined"
assert both["static_revision"] == "b" * 40 and both["endpoint_revision"] == "b" * 40
assert both["runtime_dependencies"] == {
    "config": "/config.js",
    "status_base": "/preview/<PR>/status",
}
assert both["endpoint_handlers"] == [
    "/preview/<PR>/status/*",
    "/preview/<PR>/status/gateway/v1/admission-status",
]
assert [source["path"] for source in both["endpoint_sources"]] == [
    "04-ops/edge-node/PublicCaddyfile",
    "04-ops/render-ops.sh",
]
assert all(len(source["sha256"]) == 64 for source in both["endpoint_sources"])
assert plan(["net-deployment-runbook/04-ops/site/src/app.js"])["endpoint_sources"] == []
assert "fixture" not in both
assert len(both["digest"]) == 64
print("PASS preview classifier covers no-preview, static, endpoint and combined modes")
