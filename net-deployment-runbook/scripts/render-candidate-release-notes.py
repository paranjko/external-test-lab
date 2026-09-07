#!/usr/bin/env python3
"""Render public candidate release notes from verified definition and build data."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from urllib.parse import urlparse


class RenderError(RuntimeError):
    pass


def read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RenderError(f"cannot read JSON: {path}") from exc
    if not isinstance(value, dict):
        raise RenderError(f"JSON root must be an object: {path}")
    return value


def required(value: object, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise RenderError(f"missing {label}")
    return value


def filename(url: str, label: str) -> str:
    name = Path(urlparse(url).path).name
    if not name:
        raise RenderError(f"missing file name in {label}")
    return name


def source_lines(definition: dict) -> str:
    repositories = definition.get("repositories")
    if not isinstance(repositories, dict) or not repositories:
        raise RenderError("candidate definition has no repositories")
    lines: list[str] = []
    for key, source in sorted(repositories.items()):
        if not isinstance(source, dict):
            raise RenderError(f"invalid source {key}")
        lines.extend(
            [
                f"- Source ({key}): `{required(source.get('url'), key + '.url')}`",
                f"- Source ref ({key}): `{required(source.get('ref'), key + '.ref')}`",
                f"- Source commit ({key}): `{required(source.get('commit'), key + '.commit')}`",
            ]
        )
    return "\n".join(lines)


def artifact_rows(manifest: dict) -> tuple[str, str]:
    rows: list[str] = []
    example = ""
    images = manifest.get("images", {})
    if not isinstance(images, dict):
        raise RenderError("build manifest images must be an object")
    for component, image in sorted(images.items()):
        if not isinstance(image, dict):
            raise RenderError(f"invalid image {component}")
        archive_url = required(image.get("archive_url"), f"image {component}.archive_url")
        archive = filename(archive_url, f"image {component}.archive_url")
        sha256 = required(image.get("archive_sha256"), f"image {component}.archive_sha256")
        digest = required(image.get("digest"), f"image {component}.digest")
        rows.append(f"| `{archive}` | OCI archive for `{component}` | `{sha256}` / `{digest}` |")
        example = example or archive
    binaries = manifest.get("binaries", {})
    if not isinstance(binaries, dict):
        raise RenderError("build manifest binaries must be an object")
    for component, binary in sorted(binaries.items()):
        if not isinstance(binary, dict):
            raise RenderError(f"invalid binary {component}")
        url = required(binary.get("url"), f"binary {component}.url")
        archive = filename(url, f"binary {component}.url")
        sha256 = required(binary.get("sha256"), f"binary {component}.sha256")
        digest = required(binary.get("oci_digest"), f"binary {component}.oci_digest")
        rows.append(f"| `{archive}` | Upgrade archive for `{component}` | `{sha256}` / `{digest}` |")
        example = example or archive
    if not rows:
        raise RenderError("build manifest has no release artifacts")
    return "\n".join(rows), example


def render(template: str, definition: dict, manifest: dict) -> str:
    profile = required(definition.get("profile"), "definition.profile")
    if required(manifest.get("profile"), "manifest.profile") != profile:
        raise RenderError("definition and build manifest profile differ")
    layer = required(definition.get("layer"), "definition.layer")
    definition_sha = required(manifest.get("definition_sha256"), "manifest.definition_sha256")
    rows, example = artifact_rows(manifest)
    core = definition.get("core_baseline")
    if isinstance(core, dict):
        baseline = (
            f"`{required(core.get('profile'), 'core_baseline.profile')}` – Gonka "
            f"`{required(core.get('gonka_release'), 'core_baseline.gonka_release')}`"
        )
    else:
        baseline = "defined by this candidate"
    replacements = {
        "{{PROFILE}}": profile,
        "{{LAYER}}": layer,
        "{{CORE_BASELINE}}": baseline,
        "{{SOURCE_LINES}}": source_lines(definition),
        "{{DEFINITION_SHA256}}": definition_sha,
        "{{ARTIFACT_ROWS}}": rows,
        "{{EXAMPLE_ARTIFACT}}": example,
    }
    output = template
    for token, value in replacements.items():
        output = output.replace(token, value)
    if "{{" in output or "}}" in output:
        raise RenderError("release-notes template has unresolved placeholders")
    return output


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", type=Path, required=True)
    parser.add_argument("--definition", type=Path, required=True)
    parser.add_argument("--build-manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not args.template.is_file():
        raise RenderError(f"missing template: {args.template}")
    rendered = render(args.template.read_text(encoding="utf-8"), read_json(args.definition), read_json(args.build_manifest))
    args.output.write_text(rendered, encoding="utf-8")


if __name__ == "__main__":
    try:
        main()
    except RenderError as exc:
        raise SystemExit(f"error: {exc}") from exc
