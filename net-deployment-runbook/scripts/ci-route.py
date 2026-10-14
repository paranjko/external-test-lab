#!/usr/bin/env python3
"""Classify changed paths for conservative runbook CI routing."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path


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
    ".github/workflows/gonka-pr-unified-release.yml",
    ".github/workflows/devshard-release.yml",
    ".github/workflows/devshard-artifacts-release.yml",
}
RELEASE_PREFIXES = ("net-deployment-runbook/releases/",)
SITE_PREFIXES = ("net-deployment-runbook/04-ops/site/", "ops/preview/")
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


def site(path: str) -> bool:
    return path in SITE_FILES or path.startswith(SITE_PREFIXES)


def classify(paths: list[str]) -> dict[str, bool]:
    release_change = any(release(path) for path in paths)
    site_change = any(site(path) for path in paths)
    shared_or_unknown = any(not release(path) and not site(path) for path in paths)
    return {
        "release_only": release_change and not site_change and not shared_or_unknown,
        "site_only": site_change and not release_change and not shared_or_unknown,
        "full": shared_or_unknown or (release_change and site_change) or not paths,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--changed-files", type=Path, required=True)
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    paths = json.loads(args.changed_files.read_text())
    if not isinstance(paths, list) or not all(isinstance(path, str) for path in paths):
        raise ValueError("changed files must be a JSON string list")
    result = classify(paths)
    text = "".join(f"{key}={'true' if value else 'false'}\n" for key, value in result.items())
    if args.github_output:
        with args.github_output.open("a") as output:
            output.write(text)
    print(text, end="")


if __name__ == "__main__":
    main()
