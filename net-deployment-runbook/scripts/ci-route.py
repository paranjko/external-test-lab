#!/usr/bin/env python3
"""Classify changed paths for conservative runbook CI routing."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess


RELEASE_FILES = {
    "net-deployment-runbook/scripts/devshard-release.py",
    "net-deployment-runbook/scripts/devshard-artifacts.py",
    "net-deployment-runbook/scripts/gonka-pr-unified-release.py",
    "net-deployment-runbook/scripts/test-devshard-release.py",
    "net-deployment-runbook/scripts/test-devshard-artifacts.py",
    "net-deployment-runbook/scripts/test-gonka-pr-unified-release.py",
    "net-deployment-runbook/scripts/verify-devshard-archive.sh",
    "net-deployment-runbook/scripts/pin-candidate-dockerfile.py",
    "net-deployment-runbook/scripts/patch-candidate-go-mod-download.py",
    "net-deployment-runbook/scripts/test-verify-devshard-archive.sh",
    "net-deployment-runbook/scripts/test-pin-candidate-dockerfile.py",
    "net-deployment-runbook/scripts/test-patch-candidate-go-mod-download.py",
    ".github/workflows/gonka-pr-unified-release.yml",
    ".github/workflows/devshard-release.yml",
    ".github/workflows/devshard-artifacts-release.yml",
}
RELEASE_PREFIXES = ("net-deployment-runbook/releases/",)
SITE_FILES = {
    "net-deployment-runbook/04-ops/render-ops.sh",
    "net-deployment-runbook/04-ops/network-observer.sh",
    "net-deployment-runbook/04-ops/network-observer-http.py",
    "net-deployment-runbook/04-ops/gdc-network-observer.service",
    "net-deployment-runbook/04-ops/gdc-network-observer.socket",
    "net-deployment-runbook/04-ops/gdc-network-observer@.service",
    "net-deployment-runbook/04-ops/gdc-network-observer.timer",
    "net-deployment-runbook/04-ops/Caddyfile",
    "net-deployment-runbook/04-ops/edge-node/PublicCaddyfile",
    "net-deployment-runbook/profiles/devnet-hadware.json",
    ".github/workflows/site-preview-build.yml",
    ".github/workflows/site-preview-publish.yml",
}


def release(path: str) -> bool:
    return path in RELEASE_FILES or path.startswith(RELEASE_PREFIXES)


GROUPS = ["bootstrap", "core", "site", "join", "gateways"]
JOBS = ["release-checks", "shellcheck", "runbook-tests",
        "p0a-lifecycle", "public-edge-integration", "ownership", "upstream-profiles",
        "host-upgrade-lifecycle"]


def plan(paths: list[str], force_full: bool = False) -> dict:
    # Only audited independent domains get a narrow route. Unknown/shared
    # inputs deliberately retain the complete suite, even for a one-line diff.
    relevant = [p for p in paths if p.startswith(("net-deployment-runbook/", "model/",
                "broker-ops/", "schema/", "bootstrap/", "ops/preview/"))
                or p in RELEASE_FILES or p in SITE_FILES
                or p in {"install_inferenced.sh", "ops/chore/setup-bootstrap-publisher.sh"}
                or p.startswith(".github/workflows/network-bootstrap-")
                or p == ".github/workflows/net-deployment-runbook.yml"]
    if force_full or not paths:
        selected = set(JOBS) - {"release-checks"}
        groups = GROUPS
    elif not relevant:
        selected, groups = set(), []
    elif all(release(p) for p in relevant):
        selected, groups = {"release-checks"}, []
        if any(p.endswith(".sh") for p in relevant):
            selected.add("shellcheck")
    elif all(release(p) or p.startswith("net-deployment-runbook/04-ops/site/") for p in relevant):
        # The bootstrap observer and profile checks also consume site assets.
        # Core includes all release checks, including the shared helper target;
        # scheduling release-checks as well would execute them twice.
        selected = {"runbook-tests", "public-edge-integration"}
        groups = ["bootstrap", "core", "site"]
        if any(p.endswith(".sh") for p in relevant):
            selected.add("shellcheck")
    elif all(p.endswith(".md") for p in relevant):
        # Documentation contains tested examples; retain their tests but
        # do not recreate Host containers or lint unchanged shell programs.
        selected = set(JOBS) - {"release-checks", "shellcheck", "host-upgrade-lifecycle"}
        groups = GROUPS
    else:
        selected = set(JOBS) - {"release-checks"}
        groups = GROUPS
    return {"groups": groups, "required": sorted(selected),
            **{name.replace("-", "_"): name in selected for name in JOBS}}


def git_paths(base: str, head: str) -> list[str]:
    # --no-renames includes both old and new names: moving a shared helper
    # into an independent directory cannot hide its deletion.
    result = subprocess.check_output(
        ["git", "diff", "--name-only", "--no-renames", "-z", base, head], text=True)
    return [path for path in result.split("\0") if path]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--changed-files", type=Path)
    parser.add_argument("--base")
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--full", action="store_true")
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    force_full = args.full
    if args.changed_files:
        paths = json.loads(args.changed_files.read_text())
    elif args.base and set(args.base) != {"0"}:
        try:
            paths = git_paths(args.base, args.head)
        except subprocess.CalledProcessError:
            paths, force_full = [], True
    else:
        paths, force_full = [], True
    if not isinstance(paths, list) or not all(isinstance(path, str) for path in paths):
        raise ValueError("changed files must be a JSON string list")
    result = plan(paths, force_full)
    text = "".join(f"{key}={json.dumps(value, separators=(',', ':'))}\n" for key, value in result.items())
    if args.github_output:
        with args.github_output.open("a") as output:
            output.write(text)
    print(text, end="")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write("### Selected runbook checks\n\n" +
                          (", ".join(result["required"]) or "No affected runbook checks") +
                          "\n\nTest groups: " + (", ".join(result["groups"]) or "none") + "\n")


if __name__ == "__main__":
    main()
