#!/usr/bin/env python3
"""Build and publish one complete source-bound DevShard lab candidate."""

from __future__ import annotations

import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import tempfile


ROOT = Path(__file__).resolve().parents[1]
DEFINITION = ROOT / "releases/gonka-pr-1792-unified.json"
GROUPS = ["manual-matrix", "dapi-edge"]


def load_module(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


release = load_module("devshard_release", "devshard-release.py")
artifacts = load_module("devshard_artifacts", "devshard-artifacts.py")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def definition(path: Path = DEFINITION) -> dict:
    value = json.loads(path.read_text())
    require(set(value) == {
        "schema_version", "classification", "source_repository", "source_pr", "source_commit", "source_tree",
        "protocol", "release_tag", "binary_version", "platform", "coverage_template", "artifact_recipe",
        "legacy_current_source_commit",
    }, "unexpected unified candidate definition fields")
    require(value["schema_version"] == 1 and value["classification"] == "lab-candidate-unified",
            "unsupported unified candidate definition")
    require(value["source_repository"] == "gonka-ai/gonka" and value["source_pr"] == 1792,
            "unexpected unified candidate source")
    require(all(re.fullmatch(r"[0-9a-f]{40}", value[field]) for field in
                ("source_commit", "source_tree", "legacy_current_source_commit")), "invalid immutable source identity")
    require(value["protocol"] == "v6" and value["platform"] == "linux/amd64", "unsupported candidate platform")
    expected_tag = f"lab-gonka-pr-{value['source_pr']}-{value['source_commit'][:12]}"
    require(value["release_tag"] == expected_tag and value["binary_version"] == expected_tag,
            "candidate tag or binary stamp is not source-bound")
    for field in ("coverage_template", "artifact_recipe"):
        require((ROOT / "releases" / value[field]).is_file(), f"missing reviewed {field}")
    return value


def binary_definition(candidate: dict) -> dict:
    value = copy.deepcopy(release.definition())
    value.update({
        "source_repository": candidate["source_repository"],
        "source_commit": candidate["source_commit"],
        "source_tree": candidate["source_tree"],
        "protocol": candidate["protocol"],
        "release_tag": candidate["release_tag"],
        "binary_version": candidate["binary_version"],
        "platform": candidate["platform"],
    })
    return value


def replace_source(value, old: str, new: str):
    if isinstance(value, dict):
        return {key: replace_source(item, old, new) for key, item in value.items()}
    if isinstance(value, list):
        return [replace_source(item, old, new) for item in value]
    return value.replace(old, new) if isinstance(value, str) else value


def artifact_definition(candidate: dict, binary: dict, zip_hash: str) -> dict:
    value = replace_source(copy.deepcopy(artifacts.load_definition()), candidate["legacy_current_source_commit"],
                           candidate["source_commit"])
    value["source_repository"] = candidate["source_repository"]
    value["source_commit"] = candidate["source_commit"]
    value["source_tree"] = candidate["source_tree"]
    value["release_tag"] = candidate["release_tag"]
    value["devshard_zip"] = {
        "url": f"https://github.com/{artifacts.REPOSITORY}/releases/download/{candidate['release_tag']}/devshardd.zip",
        "sha256": zip_hash,
    }
    value["components"]["decentralized-api"]["build_args"]["LDFLAGS"] = (
        "-X github.com/cosmos/cosmos-sdk/version.Name=decentralized-api "
        "-X github.com/cosmos/cosmos-sdk/version.AppName=decentralized-api "
        f"-X github.com/cosmos/cosmos-sdk/version.Version=lab-{candidate['source_commit']} "
        f"-X github.com/cosmos/cosmos-sdk/version.Commit={candidate['source_commit']}"
    )
    value["unified_binary_definition"] = binary
    return value


def materialize_coverage(candidate: dict, zip_hash: str, destination: Path) -> Path:
    template = ROOT / "releases" / candidate["coverage_template"]
    coverage = replace_source(json.loads(template.read_text()), candidate["legacy_current_source_commit"],
                              candidate["source_commit"])
    coverage["source"]["commit"] = candidate["source_commit"]
    coverage["artifact_status"]["devshard-v6-zip"] = {
        "status": "built", "sha256": zip_hash, "protocol": candidate["protocol"],
        "platform": candidate["platform"],
    }
    destination.write_text(json.dumps(coverage, sort_keys=True, indent=2) + "\n")
    return destination


def context(candidate: dict, work: Path) -> tuple[dict, dict]:
    binary = binary_definition(candidate)
    binary_dir = work / "binary"
    source = Path(os.environ["DEVSHARD_SOURCE"]).resolve()
    release.build(source, binary_dir, binary)
    zip_hash = sha256(binary_dir / "devshardd.zip")
    artifact = artifact_definition(candidate, binary, zip_hash)
    artifacts.COVERAGE = materialize_coverage(candidate, zip_hash, work / "coverage.json")
    return binary, artifact


def output_path() -> Path:
    return Path(os.environ.get("DEVSHARD_UNIFIED_RELEASE_DIR", str(ROOT / ".data/gonka-pr-1792-unified"))).resolve()


def fetch(candidate: dict) -> None:
    require(bool(os.environ.get("DEVSHARD_SOURCE")), "set DEVSHARD_SOURCE to a new checkout directory")
    release.fetch(Path(os.environ["DEVSHARD_SOURCE"]).resolve(), binary_definition(candidate))


def build(candidate: dict) -> None:
    require(bool(os.environ.get("DEVSHARD_SOURCE")), "set DEVSHARD_SOURCE to the frozen Gonka checkout")
    output = output_path()
    require(not output.exists() or not any(output.iterdir()), "unified output must be empty; never overwrite")
    with tempfile.TemporaryDirectory(prefix="gonka-pr-unified-") as directory:
        binary, artifact = context(candidate, Path(directory))
        artifacts.build(Path(os.environ["DEVSHARD_SOURCE"]).resolve(), output, artifact, GROUPS,
                        Path(directory) / "binary")
        artifacts.smoke(output, artifact, GROUPS)


def verify(candidate: dict) -> None:
    output = output_path()
    with tempfile.TemporaryDirectory(prefix="gonka-pr-unified-verify-") as directory:
        binary = binary_definition(candidate)
        zip_hash = sha256(output / "devshardd.zip")
        artifact = artifact_definition(candidate, binary, zip_hash)
        artifacts.COVERAGE = materialize_coverage(candidate, zip_hash, Path(directory) / "coverage.json")
        artifacts.verify(output, artifact, GROUPS)
        coverage = json.loads((output / artifacts.COVERAGE_ASSET).read_text())
        artifacts.validate_coverage(coverage, artifact, GROUPS, artifacts.verify(output, artifact, GROUPS))


def publish(candidate: dict) -> None:
    output = output_path()
    with tempfile.TemporaryDirectory(prefix="gonka-pr-unified-publish-") as directory:
        binary = binary_definition(candidate)
        zip_hash = sha256(output / "devshardd.zip")
        artifact = artifact_definition(candidate, binary, zip_hash)
        artifacts.COVERAGE = materialize_coverage(candidate, zip_hash, Path(directory) / "coverage.json")
        artifacts.publish(output, artifact, GROUPS)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "fetch", "build", "verify", "publish"))
    args = parser.parse_args()
    candidate = definition()
    if args.command == "prepare":
        print(json.dumps(candidate, indent=2))
    elif args.command == "fetch":
        fetch(candidate)
    elif args.command == "build":
        build(candidate)
    elif args.command == "verify":
        verify(candidate)
    else:
        publish(candidate)


if __name__ == "__main__":
    main()
