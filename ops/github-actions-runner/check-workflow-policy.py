#!/usr/bin/env python3
"""Fail closed on the repository's narrow Node4 runner contract."""
from __future__ import annotations

import argparse
import pathlib
import re
import sys

LABELS = '["self-hosted", "linux", "x64", "gdc-node4"]'
RELEASE_VERSION = re.compile(r"uses:\s+[^\s@]+@v[0-9]+(?:\.[0-9]+){0,2}(?:\s|$)")


def fail(message: str) -> None:
    print(f"policy failure: {message}", file=sys.stderr)
    raise SystemExit(1)


def read(path: pathlib.Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        fail(f"cannot read {path}: {exc}")


def require(value: bool, message: str) -> None:
    if not value:
        fail(message)


def check_actions(text: str, name: str) -> None:
    for line in text.splitlines():
        if "uses:" in line:
            require(bool(RELEASE_VERSION.search(line)), f"{name} has a non-versioned action: {line.strip()}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("workflow_dir", type=pathlib.Path)
    args = parser.parse_args()
    directory = args.workflow_dir
    runbook = read(directory / "net-deployment-runbook.yml")
    candidate = read(directory / "candidate-build.yml")
    publish = read(directory / "candidate-publish.yml")
    all_workflows = "\n".join((runbook, candidate, publish))

    require("pull_request_target:" not in all_workflows, "pull_request_target is forbidden")
    require("pull_request:" in runbook, "runbook pull-request validation is missing")
    require("github.event_name != 'pull_request'" in runbook, "runbook self-hosted predicate does not exclude pull requests")
    require("GDC_NODE4_RUNNER_ENABLED == 'true'" in runbook, "runbook flag is not fail closed")
    require("github.ref == format('refs/heads/{0}', github.event.repository.default_branch)" in runbook,
            "runbook self-hosted predicate is not default-branch constrained")
    require(LABELS in runbook, "runbook lacks all four dedicated labels")
    require("'gdc-node4-runner'" in runbook, "manual runner environment is missing")
    require("permissions:\n  contents: read" in runbook, "runbook is not read-only")
    require("docker" not in runbook.lower(), "runbook Node4 path mentions Docker")
    require("secrets." not in runbook, "runbook Node4 path references secrets")

    require("github.ref == format('refs/heads/{0}', github.event.repository.default_branch)" in candidate,
            "candidate build is not default-branch constrained")
    require("GDC_NODE4_RUNNER_ENABLED == 'true'" in candidate, "candidate build flag is not fail closed")
    require(LABELS in candidate, "candidate build lacks all four dedicated labels")
    require("permissions:\n  contents: read" in candidate, "candidate build is not read-only")
    require("docker" not in candidate.lower(), "candidate build mentions Docker")
    require("secrets." not in candidate, "candidate build references secrets")

    require("self-hosted" not in publish, "candidate publication must remain hosted")
    require("runs-on: ubuntu-latest" in publish, "candidate publication hosted route is missing")
    require("packages: write" in publish and "id-token: write" in publish and "attestations: write" in publish,
            "publication authority inventory changed")
    check_actions(runbook, "net-deployment-runbook.yml")
    check_actions(candidate, "candidate-build.yml")
    print("workflow policy: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
