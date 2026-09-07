#!/usr/bin/env python3
"""Contract test for deterministic public candidate release notes."""

from __future__ import annotations

import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
renderer_path = ROOT / "scripts" / "render-candidate-release-notes.py"
spec = importlib.util.spec_from_file_location("release_notes_renderer", renderer_path)
assert spec and spec.loader
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)

template = (ROOT / "profiles" / "candidates" / "release-notes.template.md").read_text(encoding="utf-8")
definition = {
    "profile": "v2026.09.05-rc.1",
    "layer": "devshard",
    "core_baseline": {"profile": "v2026.08.06", "gonka_release": "v0.2.15"},
    "repositories": {
        "devshard_v5": {
            "url": "https://github.com/gonka-ai/gonka.git",
            "ref": "refs/heads/devshard-0.2.15-v5",
            "commit": "5ed5f391f5c68daeb22740b9023f1453d3158279",
        }
    },
}
manifest = {
    "profile": "v2026.09.05-rc.1",
    "definition_sha256": "a" * 64,
    "images": {
        "devshardd": {
            "archive_url": "https://example.invalid/releases/download/v2026.09.05-rc.1/devshardd-linux-amd64.oci.tar.gz",
            "archive_sha256": "b" * 64,
            "digest": "sha256:" + "c" * 64,
        }
    },
    "binaries": {
        "devshardd-linux-amd64": {
            "url": "https://example.invalid/releases/download/v2026.09.05-rc.1/devshardd.zip",
            "sha256": "d" * 64,
            "oci_digest": "sha256:" + "e" * 64,
        }
    },
}

rendered = renderer.render(template, definition, manifest)
for expected in (
    "# External Test Lab candidate v2026.09.05-rc.1",
    "`v2026.08.06` – Gonka `v0.2.15`",
    "refs/heads/devshard-0.2.15-v5",
    "`devshardd-linux-amd64.oci.tar.gz`",
    "`devshardd.zip`",
    "gh attestation verify \"$artifact\" -R paranjko/external-test-lab",
    "--predicate-type https://spdx.dev/Document",
):
    assert expected in rendered, expected
assert "{{" not in rendered and "}}" not in rendered

try:
    renderer.render(template, definition, {**manifest, "profile": "v2026.09.05-rc.2"})
except renderer.RenderError as exc:
    assert "profile differ" in str(exc)
else:
    raise AssertionError("profile mismatch must fail")

print("PASS candidate release-notes renderer binds definition and build manifest")
