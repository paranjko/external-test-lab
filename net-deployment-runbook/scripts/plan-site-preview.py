#!/usr/bin/env python3
"""Classify a pull-request change into a reproducible status-site preview."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

STATIC_PREFIXES = (
    "net-deployment-runbook/04-ops/site/",
    "net-deployment-runbook/scripts/build-site-js.sh",
    "net-deployment-runbook/scripts/render-site-build-info.sh",
    "net-deployment-runbook/scripts/render-site-revision.sh",
    "net-deployment-runbook/scripts/install-site-vendor.sh",
)
ENDPOINT_PREFIXES = (
    "net-deployment-runbook/04-ops/render-ops.sh",
    "net-deployment-runbook/04-ops/Caddyfile",
    "net-deployment-runbook/04-ops/participants-proxy.sh",
    "net-deployment-runbook/04-ops/edge-node/",
)
PLATFORM_PREFIXES = (
    "ops/preview/",
    "net-deployment-runbook/scripts/isolated-preview-",
    "net-deployment-runbook/scripts/prepare-isolated-site-preview-artifact.sh",
    "net-deployment-runbook/scripts/prepare-isolated-preview-ci.sh",
    "net-deployment-runbook/scripts/prepare-isolated-preview-ci-artifact.sh",
    "net-deployment-runbook/scripts/verify-isolated-preview-ci-artifact.sh",
    ".github/workflows/site-preview-build.yml",
    ".github/workflows/site-preview-publish.yml",
)


def changed(path: str, prefixes: tuple[str, ...]) -> bool:
    return any(path == prefix or path.startswith(prefix) for prefix in prefixes)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--files", type=Path, required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repository-root", type=Path, required=True)
    parser.add_argument("--endpoint-input", action="append", type=Path, default=[])
    args = parser.parse_args()
    repository_root = args.repository_root.resolve()
    files = sorted({line.strip() for line in args.files.read_text().splitlines() if line.strip()})
    static_changed = any(changed(path, STATIC_PREFIXES) for path in files)
    endpoint_changed = any(changed(path, ENDPOINT_PREFIXES) for path in files)
    if not static_changed and not endpoint_changed:
        mode = "none"
    elif static_changed and endpoint_changed:
        mode = "combined"
    elif static_changed:
        mode = "static"
    else:
        mode = "endpoint"
    endpoint_sources = []
    if endpoint_changed:
        for source in args.endpoint_input:
            resolved = source.resolve()
            try:
                relative = resolved.relative_to(repository_root)
            except ValueError as error:
                raise SystemExit(f"endpoint input is outside repository: {source}") from error
            if not resolved.is_file():
                raise SystemExit(f"endpoint input is missing: {relative}")
            endpoint_sources.append(
                {
                    "path": str(relative),
                    "sha256": hashlib.sha256(resolved.read_bytes()).hexdigest(),
                }
            )
        if not endpoint_sources:
            raise SystemExit("endpoint preview requires declared endpoint inputs")
    payload = {
        "schema_version": 1,
        "base_revision": args.base,
        "head_revision": args.head,
        "mode": mode,
        "static_revision": args.head if static_changed else args.base,
        "endpoint_revision": args.head if endpoint_changed else args.base,
        # The topology config stays a live, same-origin dependency.  Preview
        # artifacts must never carry an invented or point-in-time status API.
        "runtime_dependencies": {
            "config": "/config.js",
            "status_base": (
                "/status"
                if mode == "static"
                else "/preview/<PR>/status"
                if mode in {"endpoint", "combined"}
                else None
            ),
        },
        "endpoint_handlers": (
            ["/preview/<PR>/status/*", "/preview/<PR>/status/gateway/v1/admission-status"]
            if mode in {"endpoint", "combined"}
            else []
        ),
        # Static bytes alone cannot identify the endpoint implementation that
        # they call.  Bind the composition to the source inputs that install
        # the shared overlay and produce its status responses.
        "endpoint_sources": endpoint_sources,
        "changed_files": files,
    }
    canonical = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
    payload["digest"] = hashlib.sha256(canonical).hexdigest()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
