#!/usr/bin/env python3
"""Offline contract tests for the candidate release lifecycle."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import io
import json
import subprocess
import tempfile
import threading
from contextlib import redirect_stdout
from pathlib import Path


SCRIPT = Path(__file__).resolve().with_name("release-candidate.py")
SPEC = importlib.util.spec_from_file_location("release_candidate", SCRIPT)
assert SPEC and SPEC.loader
candidate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(candidate)


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def workflow_pages(*pages: list[dict[str, object]]) -> str:
    return json.dumps([
        {
            "workflow_runs": [
                {
                    "id": item["databaseId"],
                    "display_title": item["displayTitle"],
                    "status": item["status"],
                    "conclusion": item["conclusion"],
                    "run_attempt": item["attempt"],
                }
                for item in page
            ]
        }
        for page in pages
    ])


def main() -> None:
    source_definition = candidate.load_json(
        candidate.CANDIDATES / "v2026.08.25-rc.0.definition.json"
    )
    with tempfile.TemporaryDirectory() as temporary_name:
        temporary = Path(temporary_name)
        candidates = temporary / "candidates"
        releases = temporary / "releases"
        state = temporary / "state"
        candidate.CANDIDATES = candidates
        candidate.RELEASES = releases
        candidate.candidate_state = lambda profile: state / profile

        definition_path = candidates / "v2026.08.25-rc.0.definition.json"
        write_json(definition_path, source_definition)
        definition_hash = candidate.sha256(definition_path)
        definition_short = definition_hash[:12]
        definition_path.with_suffix(".sha256").write_text(
            f"{definition_hash}  {definition_path.name}\n", encoding="utf-8"
        )

        output = io.StringIO()
        with redirect_stdout(output):
            candidate.command_prepare(argparse.Namespace(source_ref="upgrade-v0.2.16"))
        assert "READY profile=v2026.08.25-rc.0" in output.getvalue()

        # A layer-qualified freeze must not select an older combined
        # definition that happens to bind the same DevShard ref.
        devshard_only = json.loads(json.dumps(source_definition))
        devshard_only["profile"] = "v2026.08.27-rc.0"
        devshard_only["layer"] = "devshard"
        devshard_only["repositories"] = {
            "devshard_v5": source_definition["repositories"]["devshard_v5"]
        }
        devshard_only["components"] = [
            {
                "id": "devshard-runtime",
                "action": "build-candidate",
                "artifacts": ["oci-image", "upgrade-binary"],
            },
            {
                "id": "devshard-host",
                "action": "build-candidate",
                "artifacts": ["oci-image"],
            },
        ]
        devshard_path = candidates / "v2026.08.27-rc.0.definition.json"
        write_json(devshard_path, devshard_only)
        devshard_hash = candidate.sha256(devshard_path)
        devshard_path.with_suffix(".sha256").write_text(
            f"{devshard_hash}  {devshard_path.name}\n", encoding="utf-8"
        )
        output = io.StringIO()
        with redirect_stdout(output):
            candidate.command_prepare(
                argparse.Namespace(source_ref="devshard-0.2.15-v5", layer="devshard")
            )
        assert "READY profile=v2026.08.27-rc.0 layer=devshard" in output.getvalue()

        image_names = candidate.REQUIRED_IMAGES
        binary_names = candidate.REQUIRED_BINARIES
        manifest = {
            "schema_version": 1,
            "kind": "external-test-lab-candidate-build",
            "profile": "v2026.08.25-rc.0",
            "definition_sha256": definition_hash,
            "architectures": ["linux/amd64"],
            "source": {
                key: value["commit"]
                for key, value in source_definition["repositories"].items()
            },
            "workflow": {
                "repository": "paranjko/external-test-lab",
                "ref": (
                    "paranjko/external-test-lab/.github/workflows/"
                    "candidate-publish.yml@refs/heads/main"
                ),
                "sha": "a" * 40,
                "request_ref": "refs/heads/main",
                "request_sha": "b" * 40,
                "request_run_id": "101",
                "run_id": "202",
                "run_attempt": "1",
            },
            "images": {
                name: {
                    "reference": (
                        f"ghcr.io/paranjko/gdc-{name}:"
                        f"v2026.08.25-rc.0-{definition_short}-202"
                    ),
                    "digest": f"sha256:{hashlib.sha256(name.encode()).hexdigest()}",
                    "deployment_reference": (
                        f"ghcr.io/paranjko/gdc-{name}:"
                        f"v2026.08.25-rc.0-{definition_short}-202"
                    ),
                    "archive_url": f"https://github.com/paranjko/external-test-lab/releases/download/lab-candidate%2Fv2026.08.25-rc.0/{name}-linux-amd64.oci.tar.gz",
                    "archive_sha256": hashlib.sha256((name + "-archive").encode()).hexdigest(),
                    "sbom": True,
                    "provenance": True,
                }
                for name in image_names
            },
            "binaries": {
                name: {
                    "oci_reference": (
                        "ghcr.io/paranjko/gdc-upgrade-"
                        f"{name.removesuffix('-linux-amd64')}:"
                        f"v2026.08.25-rc.0-{definition_short}-202"
                    ),
                    "oci_digest": f"sha256:{hashlib.sha256((name + '-oci').encode()).hexdigest()}",
                    "url": f"https://github.com/paranjko/external-test-lab/releases/download/lab-candidate%2Fv2026.08.25-rc.0/{name}.zip",
                    "sha256": hashlib.sha256((name + "-zip").encode()).hexdigest(),
                    "sbom": True,
                    "provenance": True,
                }
                for name in binary_names
            },
        }
        manifest_path = state / "v2026.08.25-rc.0" / "build" / "build-manifest.json"
        write_json(manifest_path, manifest)

        retried_manifest = json.loads(json.dumps(manifest))
        retried_manifest["workflow"]["run_attempt"] = "2"
        retried_manifest_path = temporary / "retried-manifest.json"
        write_json(retried_manifest_path, retried_manifest)
        candidate.verify_build_manifest(
            "v2026.08.25-rc.0", retried_manifest_path
        )
        assert {
            value["oci_reference"]
            for value in retried_manifest["binaries"].values()
        } == {
            value["oci_reference"] for value in manifest["binaries"].values()
        }

        attempt_scoped_binary = json.loads(json.dumps(retried_manifest))
        attempt_scoped_binary["binaries"]["inferenced-linux-amd64"][
            "oci_reference"
        ] += "-2"
        attempt_scoped_binary_path = temporary / "attempt-scoped-binary.json"
        write_json(attempt_scoped_binary_path, attempt_scoped_binary)
        try:
            candidate.verify_build_manifest(
                "v2026.08.25-rc.0", attempt_scoped_binary_path
            )
        except candidate.CandidateError as exc:
            assert "binary OCI reference is invalid" in str(exc)
        else:
            raise AssertionError("attempt-scoped binary reference was accepted")

        invalid_publisher = json.loads(json.dumps(manifest))
        invalid_publisher["workflow"]["ref"] = "refs/heads/main"
        invalid_publisher_path = temporary / "invalid-publisher.json"
        write_json(invalid_publisher_path, invalid_publisher)
        try:
            candidate.verify_build_manifest("v2026.08.25-rc.0", invalid_publisher_path)
        except candidate.CandidateError as exc:
            assert "publisher identity" in str(exc)
        else:
            raise AssertionError("request ref was accepted as the publisher identity")

        missing_request = json.loads(json.dumps(manifest))
        del missing_request["workflow"]["request_sha"]
        missing_request_path = temporary / "missing-request.json"
        write_json(missing_request_path, missing_request)
        try:
            candidate.verify_build_manifest("v2026.08.25-rc.0", missing_request_path)
        except candidate.CandidateError as exc:
            assert "request identity" in str(exc)
        else:
            raise AssertionError("manifest without request identity was accepted")

        unpublished_deployment = json.loads(json.dumps(manifest))
        unpublished_deployment["images"]["inferenced"]["deployment_reference"] = (
            "ghcr.io/paranjko/gdc-inferenced:v2026.08.25-rc.0"
        )
        unpublished_deployment_path = temporary / "unpublished-deployment.json"
        write_json(unpublished_deployment_path, unpublished_deployment)
        try:
            candidate.verify_build_manifest(
                "v2026.08.25-rc.0", unpublished_deployment_path
            )
        except candidate.CandidateError as exc:
            assert "was not published" in str(exc)
        else:
            raise AssertionError("unpublished deployment tag was accepted")

        swapped_images = json.loads(json.dumps(manifest))
        swapped_images["images"]["inferenced"], swapped_images["images"]["decentralized-api"] = (
            swapped_images["images"]["decentralized-api"],
            swapped_images["images"]["inferenced"],
        )
        swapped_images_path = temporary / "swapped-images.json"
        write_json(swapped_images_path, swapped_images)
        try:
            candidate.verify_build_manifest("v2026.08.25-rc.0", swapped_images_path)
        except candidate.CandidateError as exc:
            assert "image reference is invalid" in str(exc)
        else:
            raise AssertionError("images swapped between component keys were accepted")

        wrong_image_archive = json.loads(json.dumps(manifest))
        wrong_image_archive["images"]["inferenced"]["archive_url"] = (
            "https://github.com/paranjko/external-test-lab/releases/download/"
            "lab-candidate%2Fv2026.08.25-rc.0/decentralized-api-linux-amd64.oci.tar.gz"
        )
        wrong_image_archive_path = temporary / "wrong-image-archive.json"
        write_json(wrong_image_archive_path, wrong_image_archive)
        try:
            candidate.verify_build_manifest(
                "v2026.08.25-rc.0", wrong_image_archive_path
            )
        except candidate.CandidateError as exc:
            assert "image archive URL is invalid" in str(exc)
        else:
            raise AssertionError("image archive bound to another component was accepted")

        swapped_binaries = json.loads(json.dumps(manifest))
        swapped_binaries["binaries"]["inferenced-linux-amd64"], swapped_binaries["binaries"]["edge-api-linux-amd64"] = (
            swapped_binaries["binaries"]["edge-api-linux-amd64"],
            swapped_binaries["binaries"]["inferenced-linux-amd64"],
        )
        swapped_binaries_path = temporary / "swapped-binaries.json"
        write_json(swapped_binaries_path, swapped_binaries)
        try:
            candidate.verify_build_manifest("v2026.08.25-rc.0", swapped_binaries_path)
        except candidate.CandidateError as exc:
            assert "binary OCI reference is invalid" in str(exc)
        else:
            raise AssertionError("binaries swapped between component keys were accepted")

        wrong_binary_url = json.loads(json.dumps(manifest))
        wrong_binary_url["binaries"]["inferenced-linux-amd64"]["url"] = (
            "https://github.com/paranjko/external-test-lab/releases/download/"
            "lab-candidate%2Fv2026.08.25-rc.0/edge-api-linux-amd64.zip"
        )
        wrong_binary_url_path = temporary / "wrong-binary-url.json"
        write_json(wrong_binary_url_path, wrong_binary_url)
        try:
            candidate.verify_build_manifest("v2026.08.25-rc.0", wrong_binary_url_path)
        except candidate.CandidateError as exc:
            assert "binary release URL is invalid" in str(exc)
        else:
            raise AssertionError("binary URL bound to another component was accepted")

        for race_number in range(20):
            race_path = releases / f"concurrent-{race_number}.lock"
            barrier = threading.Barrier(2)
            outcomes: list[tuple[str, str]] = []

            def write_racer(content: str) -> None:
                barrier.wait()
                try:
                    candidate.atomic_write(race_path, content)
                except candidate.CandidateError:
                    outcomes.append(("rejected", content))
                else:
                    outcomes.append(("created", content))

            racers = [
                threading.Thread(target=write_racer, args=("first\n",)),
                threading.Thread(target=write_racer, args=("second\n",)),
            ]
            for racer in racers:
                racer.start()
            for racer in racers:
                racer.join()
            assert sorted(status for status, _ in outcomes) == ["created", "rejected"]
            winner = next(content for status, content in outcomes if status == "created")
            assert race_path.read_text(encoding="utf-8") == winner

        args = argparse.Namespace(profile="v2026.08.25-rc.0", build_manifest=str(manifest_path))
        candidate.command_profile(args)
        candidate.command_profile(args)
        candidate.command_verify(args)
        lock = releases / "v2026.08.25-rc.0.lock"
        lock_text = lock.read_text(encoding="utf-8")
        assert "LAB_CANDIDATE=true" in lock_text
        assert "UPGRADE_FROM_PROFILE=v2026.08.06" in lock_text
        assert "GONKA_HA=false" in lock_text
        assert "DEVSHARD_STORAGE_MODE=memory" in lock_text
        mlnode_reference = next(
            component["reference"]
            for component in source_definition["components"]
            if component["id"] == "mlnode"
        )
        assert f"MLNODE_GENERIC_IMAGE={mlnode_reference}" in lock_text
        expected_image = (
            f"INFERENCED_IMAGE={manifest['images']['inferenced']['reference']}@"
            f"{manifest['images']['inferenced']['digest']}"
        )
        assert expected_image in lock_text
        inferenced_binary = manifest["binaries"]["inferenced-linux-amd64"]
        operator_binary = manifest["binaries"]["inferenced-operator-linux-amd64"]
        assert (
            f"INFERENCED_OPERATOR_URL_LINUX_AMD64={operator_binary['url']}"
            in lock_text
        )
        assert (
            "INFERENCED_OPERATOR_SHA256_LINUX_AMD64="
            f"{operator_binary['sha256']}"
            in lock_text
        )
        assert operator_binary["url"] != inferenced_binary["url"]
        assert operator_binary["sha256"] != inferenced_binary["sha256"]
        assert (
            f"INFERENCED_UPGRADE_URL={inferenced_binary['url']}"
            in lock_text
        )
        assert (
            f"INFERENCED_UPGRADE_SHA256={inferenced_binary['sha256']}"
            in lock.read_text(encoding="utf-8")
        )
        gateway = manifest["images"]["devshard-gateway"]
        assert (
            f"DEVSHARD_GATEWAY_IMAGE={gateway['reference']}@{gateway['digest']}"
            in lock.read_text(encoding="utf-8")
        )
        assert (
            f"CANDIDATE_LOCAL_GATEWAY_IMAGE={gateway['reference']}"
            in lock.read_text(encoding="utf-8")
        )
        assert (
            f"CANDIDATE_LOCAL_GATEWAY_IMAGE={gateway['reference']}@{gateway['digest']}"
            not in lock.read_text(encoding="utf-8")
        )

        lock.write_text(lock.read_text(encoding="utf-8") + "BROKEN=true\n", encoding="utf-8")
        try:
            candidate.command_verify(args)
        except candidate.CandidateError as exc:
            assert "does not match" in str(exc)
        else:
            raise AssertionError("modified candidate release lock was accepted")

        output = io.StringIO()
        with redirect_stdout(output):
            candidate.command_build(
                argparse.Namespace(
                    profile="v2026.08.25-rc.0", dry_run=True, retry=False, wait=False
                )
            )
        assert "reviewed_ref=main" in output.getvalue()

        candidate.REPOSITORY_ROOT = temporary
        calls: list[list[str]] = []
        downloads: list[tuple[str, int]] = []
        request_title = f"candidate v2026.08.25-rc.0 {definition_hash}"
        publish_title = f"publish {request_title} request-101-attempt-1"
        request_lists = 0

        older_requests = [
            {
                "databaseId": 1000 + number,
                "displayTitle": f"candidate unrelated-{number}",
                "status": "completed",
                "conclusion": "success",
                "attempt": 1,
            }
            for number in range(30)
        ]
        existing_request = {
            "databaseId": 101,
            "displayTitle": request_title,
            "status": "completed",
            "conclusion": "success",
            "attempt": 1,
        }
        existing_publication = {
            "databaseId": 202,
            "displayTitle": publish_title,
            "status": "completed",
            "conclusion": "success",
            "attempt": 1,
        }

        def fake_history_run(
            command: list[str], *, capture: bool = True
        ) -> subprocess.CompletedProcess[str]:
            calls.append(command)
            stdout = ""
            if command[:2] == ["git", "show"]:
                stdout = definition_path.read_text(encoding="utf-8")
            elif command[:2] == ["gh", "api"]:
                assert "--paginate" in command and "--slurp" in command
                assert "per_page=100" in command
                endpoint = command[-1]
                if candidate.REQUEST_WORKFLOW in endpoint:
                    stdout = workflow_pages(older_requests, [existing_request])
                elif candidate.PUBLISH_WORKFLOW in endpoint:
                    stdout = workflow_pages([existing_publication])
            return subprocess.CompletedProcess(command, 0, stdout=stdout, stderr="")

        candidate.run = fake_history_run
        candidate.download_build_artifact = (
            lambda profile, run_id: downloads.append((profile, run_id))
        )
        output = io.StringIO()
        with redirect_stdout(output):
            candidate.command_build(
                argparse.Namespace(
                    profile="v2026.08.25-rc.0", dry_run=False, retry=False, wait=False
                )
            )
        assert not any(command[:3] == ["gh", "workflow", "run"] for command in calls)
        assert downloads == [("v2026.08.25-rc.0", 202)]
        assert "resumed=true" in output.getvalue()

        calls.clear()
        downloads.clear()

        def fake_run(command: list[str], *, capture: bool = True) -> subprocess.CompletedProcess[str]:
            nonlocal request_lists
            calls.append(command)
            stdout = ""
            if command[:2] == ["git", "show"]:
                stdout = definition_path.read_text(encoding="utf-8")
            elif command[:2] == ["gh", "api"]:
                endpoint = command[-1]
                if candidate.REQUEST_WORKFLOW in endpoint:
                    request_lists += 1
                    if request_lists > 1:
                        stdout = workflow_pages([{
                            "databaseId": 101,
                            "displayTitle": request_title,
                            "status": "completed" if request_lists > 2 else "in_progress",
                            "conclusion": "success" if request_lists > 2 else "",
                            "attempt": 1,
                        }])
                    else:
                        stdout = workflow_pages([])
                elif candidate.PUBLISH_WORKFLOW in endpoint:
                    stdout = workflow_pages([{
                        "databaseId": 202,
                        "displayTitle": publish_title,
                        "status": "in_progress",
                        "conclusion": "",
                        "attempt": 1,
                    }])
            return subprocess.CompletedProcess(command, 0, stdout=stdout, stderr="")

        candidate.run = fake_run
        candidate.download_build_artifact = (
            lambda profile, run_id: downloads.append((profile, run_id))
        )
        output = io.StringIO()
        with redirect_stdout(output):
            candidate.command_build(
                argparse.Namespace(
                    profile="v2026.08.25-rc.0", dry_run=False, retry=False, wait=True
                )
            )
        assert any(command[:3] == ["gh", "workflow", "run"] for command in calls)
        watched = [
            int(command[3])
            for command in calls
            if command[:3] == ["gh", "run", "watch"]
        ]
        assert watched == [101, 202]
        assert downloads == [("v2026.08.25-rc.0", 202)]
        assert "publish_run_id=202" in output.getvalue()

        calls.clear()
        downloads.clear()
        retry_dispatched = False
        retry_publish_title = f"publish {request_title} request-102-attempt-1"

        def fake_retry_run(
            command: list[str], *, capture: bool = True
        ) -> subprocess.CompletedProcess[str]:
            nonlocal retry_dispatched
            calls.append(command)
            stdout = ""
            if command[:2] == ["git", "show"]:
                stdout = definition_path.read_text(encoding="utf-8")
            elif command[:3] == ["gh", "workflow", "run"]:
                retry_dispatched = True
            elif command[:2] == ["gh", "api"]:
                endpoint = command[-1]
                if candidate.REQUEST_WORKFLOW in endpoint:
                    runs = [{
                        "databaseId": 101,
                        "displayTitle": request_title,
                        "status": "completed",
                        "conclusion": "failure",
                        "attempt": 1,
                    }]
                    if retry_dispatched:
                        runs.insert(0, {
                            "databaseId": 102,
                            "displayTitle": request_title,
                            "status": "completed",
                            "conclusion": "success",
                            "attempt": 1,
                        })
                    stdout = workflow_pages(runs)
                elif candidate.PUBLISH_WORKFLOW in endpoint:
                    stdout = workflow_pages([{
                        "databaseId": 202,
                        "displayTitle": retry_publish_title,
                        "status": "in_progress",
                        "conclusion": "",
                        "attempt": 1,
                    }])
            return subprocess.CompletedProcess(command, 0, stdout=stdout, stderr="")

        candidate.run = fake_retry_run
        output = io.StringIO()
        with redirect_stdout(output):
            candidate.command_build(
                argparse.Namespace(
                    profile="v2026.08.25-rc.0", dry_run=False, retry=True, wait=True
                )
            )
        assert any(command[:3] == ["gh", "workflow", "run"] for command in calls)
        assert not any(command[:3] == ["gh", "run", "rerun"] for command in calls)
        watched = [
            int(command[3])
            for command in calls
            if command[:3] == ["gh", "run", "watch"]
        ]
        assert watched == [202]
        assert downloads == [("v2026.08.25-rc.0", 202)]
        # --- IMP-013: Core Layer Candidate Tests ---
        core_definition = {
            "schema_version": 1,
            "kind": "external-test-lab-candidate-definition",
            "profile": "v2026.08.26-rc.0",
            "layer": "core",
            "classification": "lab-candidate",
            "official_gonka_release": False,
            "upgrade_from_profile": "v2026.08.06",
            "repositories": {
                "gonka_core": {
                    "url": "https://github.com/gonka-ai/gonka.git",
                    "ref": "refs/heads/upgrade-v0.2.16-core",
                    "commit": "1" * 40,
                    "tree": "2" * 40,
                }
            },
            "architectures": {
                "observed_laboratory_hosts": ["linux/amd64"],
                "oci_images": ["linux/amd64"],
                "upgrade_binaries": ["linux/amd64"],
            },
            "base_images": [
                {
                    "reference": "alpine:3.21",
                    "digest": f"sha256:{'3' * 64}",
                }
            ],
            "components": [
                {
                    "id": name,
                    "action": "build-candidate" if name in candidate.CORE_REQUIRED_IMAGES else "reuse-immutable",
                    "reference": f"ghcr.io/paranjko/gdc-{name}:v0.2.15@sha256:{'4' * 64}",
                    "artifacts": ["oci-image", "upgrade-binary", "operator-binary"] if name == "inferenced" else ["oci-image"],
                }
                for name in [
                    "inferenced", "decentralized-api", "edge-api",
                    "versiond", "versiond-router", "mlnode", "proxy",
                    "tmkms", "bridge",
                ]
            ],
            "governance": {
                "core_upgrade_name": "v0.2.16",
            },
            "features": {
                "ha": {
                    "enabled": False,
                    "deployment": "excluded",
                    "storage_mode": "memory",
                }
            },
        }
        core_def_path = candidates / "v2026.08.26-rc.0.definition.json"
        write_json(core_def_path, core_definition)
        core_def_hash = candidate.sha256(core_def_path)
        core_def_path.with_suffix(".sha256").write_text(
            f"{core_def_hash}  {core_def_path.name}\n", encoding="utf-8"
        )

        output = io.StringIO()
        with redirect_stdout(output):
            candidate.command_prepare(
                argparse.Namespace(source_ref="upgrade-v0.2.16-core", layer="core")
            )
        assert "READY profile=v2026.08.26-rc.0 layer=core" in output.getvalue()

        core_manifest = {
            "schema_version": 1,
            "kind": "external-test-lab-candidate-build",
            "profile": "v2026.08.26-rc.0",
            "definition_sha256": core_def_hash,
            "architectures": ["linux/amd64"],
            "source": {
                "gonka_core": "1" * 40,
            },
            "workflow": {
                "repository": "paranjko/external-test-lab",
                "ref": (
                    "paranjko/external-test-lab/.github/workflows/"
                    "candidate-publish.yml@refs/heads/main"
                ),
                "sha": "a" * 40,
                "request_ref": "refs/heads/main",
                "request_sha": "b" * 40,
                "request_run_id": "301",
                "run_id": "402",
                "run_attempt": "1",
            },
            "images": {
                name: {
                    "reference": f"ghcr.io/paranjko/gdc-{name}:v2026.08.26-rc.0-{core_def_hash[:12]}-402",
                    "digest": f"sha256:{hashlib.sha256(('core-img-' + name).encode()).hexdigest()}",
                    "deployment_reference": f"ghcr.io/paranjko/gdc-{name}:v2026.08.26-rc.0-{core_def_hash[:12]}-402",
                    "archive_url": f"https://github.com/paranjko/external-test-lab/releases/download/lab-candidate%2Fv2026.08.26-rc.0/{name}-linux-amd64.oci.tar.gz",
                    "archive_sha256": hashlib.sha256((name + "-core-arch").encode()).hexdigest(),
                    "sbom": True,
                    "provenance": True,
                }
                for name in candidate.CORE_REQUIRED_IMAGES
            },
            "binaries": {
                name: {
                    "oci_reference": f"ghcr.io/paranjko/gdc-upgrade-{name.removesuffix('-linux-amd64')}:v2026.08.26-rc.0-{core_def_hash[:12]}-402",
                    "oci_digest": f"sha256:{hashlib.sha256(('core-bin-oci-' + name).encode()).hexdigest()}",
                    "url": f"https://github.com/paranjko/external-test-lab/releases/download/lab-candidate%2Fv2026.08.26-rc.0/{name}.zip",
                    "sha256": hashlib.sha256((name + "-core-zip").encode()).hexdigest(),
                    "sbom": True,
                    "provenance": True,
                }
                for name in candidate.CORE_REQUIRED_BINARIES
            },
        }
        core_manifest_path = state / "v2026.08.26-rc.0" / "build" / "build-manifest.json"
        write_json(core_manifest_path, core_manifest)
        candidate.verify_build_manifest("v2026.08.26-rc.0", core_manifest_path)

        candidate.command_profile(
            argparse.Namespace(profile="v2026.08.26-rc.0", build_manifest=str(core_manifest_path))
        )
        candidate.command_verify(
            argparse.Namespace(profile="v2026.08.26-rc.0", build_manifest=str(core_manifest_path))
        )

        # Negative test: core candidate with missing component in build manifest
        corrupted_core_manifest = json.loads(json.dumps(core_manifest))
        del corrupted_core_manifest["images"]["inferenced"]
        corrupted_path = temporary / "corrupted-core-manifest.json"
        write_json(corrupted_path, corrupted_core_manifest)
        try:
            candidate.verify_build_manifest("v2026.08.26-rc.0", corrupted_path)
        except candidate.CandidateError as exc:
            assert "image set is incomplete" in str(exc)
        else:
            raise AssertionError("incomplete core images accepted")

        # --- IMP-013: DevShard Layer Candidate Tests ---
        devshard_definition = {
            "schema_version": 1,
            "kind": "external-test-lab-candidate-definition",
            "profile": "v2026.08.27-rc.0",
            "layer": "devshard",
            "classification": "lab-candidate",
            "official_gonka_release": False,
            "upgrade_from_profile": "v2026.08.06",
            "repositories": {
                "devshard_v5": {
                    "url": "https://github.com/gonka-ai/gonka.git",
                    "ref": "refs/heads/devshard-v5-candidate",
                    "commit": "5" * 40,
                    "tree": "6" * 40,
                }
            },
            "architectures": {
                "observed_laboratory_hosts": ["linux/amd64"],
                "oci_images": ["linux/amd64"],
                "upgrade_binaries": ["linux/amd64"],
            },
            "base_images": [
                {
                    "reference": "alpine:3.21",
                    "digest": f"sha256:{'7' * 64}",
                }
            ],
            "components": [
                {
                    "id": "devshard-runtime",
                    "action": "build-candidate",
                    "artifacts": ["oci-image", "upgrade-binary"],
                },
                {
                    "id": "devshard-host",
                    "action": "build-candidate",
                    "artifacts": ["oci-image"],
                },
            ],
            "features": {
                "devshard_protocol_version": "v5",
                "ha": {
                    "enabled": False,
                    "deployment": "excluded",
                    "storage_mode": "memory",
                }
            },
        }
        devshard_def_path = candidates / "v2026.08.27-rc.0.definition.json"
        write_json(devshard_def_path, devshard_definition)
        devshard_def_hash = candidate.sha256(devshard_def_path)
        devshard_def_path.with_suffix(".sha256").write_text(
            f"{devshard_def_hash}  {devshard_def_path.name}\n", encoding="utf-8"
        )

        output = io.StringIO()
        with redirect_stdout(output):
            candidate.command_prepare(
                argparse.Namespace(source_ref="devshard-v5-candidate", layer="devshard")
            )
        assert "READY profile=v2026.08.27-rc.0 layer=devshard" in output.getvalue()

        devshard_manifest = {
            "schema_version": 1,
            "kind": "external-test-lab-candidate-build",
            "profile": "v2026.08.27-rc.0",
            "definition_sha256": devshard_def_hash,
            "architectures": ["linux/amd64"],
            "source": {
                "devshard_v5": "5" * 40,
            },
            "workflow": {
                "repository": "paranjko/external-test-lab",
                "ref": (
                    "paranjko/external-test-lab/.github/workflows/"
                    "candidate-publish.yml@refs/heads/main"
                ),
                "sha": "a" * 40,
                "request_ref": "refs/heads/main",
                "request_sha": "b" * 40,
                "request_run_id": "501",
                "run_id": "602",
                "run_attempt": "1",
            },
            "images": {
                name: {
                    "reference": f"ghcr.io/paranjko/gdc-{name}:v2026.08.27-rc.0-{devshard_def_hash[:12]}-602",
                    "digest": f"sha256:{hashlib.sha256(('ds-img-' + name).encode()).hexdigest()}",
                    "deployment_reference": f"ghcr.io/paranjko/gdc-{name}:v2026.08.27-rc.0-{devshard_def_hash[:12]}-602",
                    "archive_url": f"https://github.com/paranjko/external-test-lab/releases/download/lab-candidate%2Fv2026.08.27-rc.0/{name}-linux-amd64.oci.tar.gz",
                    "archive_sha256": hashlib.sha256((name + "-ds-arch").encode()).hexdigest(),
                    "sbom": True,
                    "provenance": True,
                }
                for name in candidate.DEVSHARD_REQUIRED_IMAGES
            },
            "binaries": {
                name: {
                    "oci_reference": f"ghcr.io/paranjko/gdc-upgrade-{name.removesuffix('-linux-amd64')}:v2026.08.27-rc.0-{devshard_def_hash[:12]}-602",
                    "oci_digest": f"sha256:{hashlib.sha256(('ds-bin-oci-' + name).encode()).hexdigest()}",
                    "url": f"https://github.com/paranjko/external-test-lab/releases/download/lab-candidate%2Fv2026.08.27-rc.0/{name}.zip",
                    "sha256": hashlib.sha256((name + "-ds-zip").encode()).hexdigest(),
                    "sbom": True,
                    "provenance": True,
                }
                for name in candidate.DEVSHARD_REQUIRED_BINARIES
            },
        }
        devshard_manifest_path = state / "v2026.08.27-rc.0" / "build" / "build-manifest.json"
        write_json(devshard_manifest_path, devshard_manifest)
        candidate.verify_build_manifest("v2026.08.27-rc.0", devshard_manifest_path)

        candidate.command_profile(
            argparse.Namespace(profile="v2026.08.27-rc.0", build_manifest=str(devshard_manifest_path))
        )
        candidate.command_verify(
            argparse.Namespace(profile="v2026.08.27-rc.0", build_manifest=str(devshard_manifest_path))
        )

        # --- IMP-013: Deployed-State Composition Manifest Tests ---
        # Copy real v2026.08.06 lock and community-lab.lock for testing compositions
        compositions = temporary / "compositions"
        candidate.COMPOSITIONS = compositions
        deployments = temporary / "deployments"
        candidate.DEPLOYMENTS = deployments
        deployments.mkdir(parents=True, exist_ok=True)
        real_v0806_lock = (SCRIPT.parent.parent / "profiles" / "releases" / "v2026.08.06.lock").read_text(encoding="utf-8")
        (releases / "v2026.08.06.lock").write_text(real_v0806_lock, encoding="utf-8")
        real_dept_lock = (SCRIPT.parent.parent / "profiles" / "deployments" / "community-lab.lock").read_text(encoding="utf-8")
        (deployments / "community-lab.lock").write_text(real_dept_lock, encoding="utf-8")

        # Test workflow-matrix for core and devshard profiles
        matrix_core = candidate.workflow_matrix("v2026.08.26-rc.0")
        assert matrix_core["layer"] == "core"
        core_img_ids = {img["id"] for img in matrix_core["image_matrix"]["include"]}
        assert core_img_ids == candidate.CORE_REQUIRED_IMAGES
        assert len(matrix_core["binary_matrix"]["include"]) == len(candidate.CORE_REQUIRED_BINARIES)
        for img in matrix_core["image_matrix"]["include"]:
            assert "${{" not in img["build_args"]
        inferenced_entry = next(img for img in matrix_core["image_matrix"]["include"] if img["id"] == "inferenced")
        assert "Version=0.2.16" in inferenced_entry["build_args"]
        assert "Commit=" in inferenced_entry["build_args"]

        matrix_devshard = candidate.workflow_matrix("v2026.08.27-rc.0")
        assert matrix_devshard["layer"] == "devshard"
        devshard_img_ids = {img["id"] for img in matrix_devshard["image_matrix"]["include"]}
        assert devshard_img_ids == candidate.DEVSHARD_REQUIRED_IMAGES
        assert len(matrix_devshard["binary_matrix"]["include"]) == len(candidate.DEVSHARD_REQUIRED_BINARIES)
        for img in matrix_devshard["image_matrix"]["include"]:
            assert "${{" not in img["build_args"]
        devshardd_entry = next(img for img in matrix_devshard["image_matrix"]["include"] if img["id"] == "devshardd")
        assert "DEVSHARD_BINARY_VERSION=v2026.08.27-rc.0-" in devshardd_entry["build_args"]

        # Positive test: composition create, verify, materialize, export-env
        output = io.StringIO()
        with redirect_stdout(output):
            candidate.command_composition_create(
                argparse.Namespace(
                    core="v2026.08.06",
                    devshard="v2026.08.06",
                    name="core-v2026.08.06+devshard-v4",
                    output=None,
                    materialize=None,
                )
            )
        assert "READY composition=core-v2026.08.06+devshard-v4" in output.getvalue()

        output = io.StringIO()
        with redirect_stdout(output):
            candidate.command_composition_verify(
                argparse.Namespace(manifest="core-v2026.08.06+devshard-v4")
            )
        assert "PASS composition=core-v2026.08.06+devshard-v4" in output.getvalue()

        # Materialize composition
        mat_out_path = temporary / "materialized-v4.lock"
        output = io.StringIO()
        with redirect_stdout(output):
            candidate.command_composition_materialize(
                argparse.Namespace(manifest="core-v2026.08.06+devshard-v4", output=str(mat_out_path))
            )
        assert "READY composition=core-v2026.08.06+devshard-v4" in output.getvalue()
        assert mat_out_path.is_file()
        mat_content = mat_out_path.read_text(encoding="utf-8")
        assert "DEVSHARD_PROTOCOL_VERSION=v3" in mat_content
        assert "LOCAL_GATEWAY_IMAGE=gdc/devshard-gateway:0.2.15-v3" in mat_content

        # Export env
        output = io.StringIO()
        with redirect_stdout(output):
            candidate.command_composition_export_env(
                argparse.Namespace(manifest="core-v2026.08.06+devshard-v4")
            )
        env_content = output.getvalue()
        assert "export GDC_COMPOSITION=core-v2026.08.06+devshard-v4" in env_content
        assert "export DEVSHARD_PROTOCOL_VERSION=v3" in env_content

        # Candidate composition create & verify (core candidate + devshard candidate)
        comp_candidate_path = temporary / "comp-candidates.json"
        manifest_cand, _, comp_cand_hash = candidate.create_composition(
            core_profile="v2026.08.26-rc.0",
            devshard_profile="v2026.08.27-rc.0",
            name="cand-core+cand-devshard",
            output_path=comp_candidate_path,
        )
        assert manifest_cand["core"]["classification"] == "lab-candidate"
        assert manifest_cand["devshard"]["classification"] == "lab-candidate"
        candidate.verify_composition(comp_candidate_path)

        # Verify candidate composition lock and env bindings
        mat_cand_lock = temporary / "materialized-cand.lock"
        mat_cand_content = candidate.materialize_composition_lock(manifest_cand)
        candidate.atomic_write(mat_cand_lock, mat_cand_content)
        assert "DEVSHARD_PROTOCOL_VERSION=v5" in mat_cand_content
        assert "DEVSHARD_GATEWAY_IMAGE_ARCHIVE_URL=" in mat_cand_content
        assert "DEVSHARD_GATEWAY_IMAGE_ARCHIVE_SHA256=" in mat_cand_content
        assert "POSTGRES_IMAGE='postgres:16-alpine@" in mat_cand_content or "POSTGRES_IMAGE=postgres:16-alpine@" in mat_cand_content
        assert "DEVSHARD_HOST_IMAGE=" in mat_cand_content

        env_cand_content = candidate.composition_env(manifest_cand)
        assert "export GDC_COMPOSITION_HASH=" in env_cand_content
        assert "export DEVSHARD_GATEWAY_IMAGE_ARCHIVE_URL=" in env_cand_content
        assert "export DEVSHARD_GATEWAY_IMAGE_ARCHIVE_SHA256=" in env_cand_content
        assert "export POSTGRES_IMAGE='postgres:16-alpine@" in env_cand_content or "export POSTGRES_IMAGE=postgres:16-alpine@" in env_cand_content
        assert "export DEVSHARD_HOST_IMAGE=" in env_cand_content

        # Verify stable composition devshard commit is distinct from host stack commit
        manifest_stable = candidate.build_canonical_composition("v2026.08.06", "v2026.08.06", "test-stable")
        assert manifest_stable["devshard"]["source_commit"] == "3c034a72a80f82c33f71a73737c329f41c7ddf7b"
        assert manifest_stable["devshard"]["host_stack_commit"] == "ce33c851282b8f4c0f63d78d46ddd4d8bb248207"

        # Negative test: incompatible lineage between core candidate and devshard candidate
        incomp_lock_content = (releases / "v2026.08.27-rc.0.lock").read_text(encoding="utf-8").replace(
            "UPGRADE_FROM_PROFILE=v2026.08.06", "UPGRADE_FROM_PROFILE=v2026.07.23"
        )
        (releases / "incompatible-devshard.lock").write_text(incomp_lock_content, encoding="utf-8")
        try:
            candidate.create_composition("v2026.08.26-rc.0", "incompatible-devshard")
        except candidate.CandidateError as exc:
            assert "incompatible lineage" in str(exc)
        else:
            raise AssertionError("incompatible lineage composition was accepted")

        # Negative test: malformed composition name
        try:
            candidate.create_composition("v2026.08.06", "v2026.08.06", name="../traversal-name")
        except candidate.CandidateError as exc:
            assert "composition identifier is malformed" in str(exc)
        else:
            raise AssertionError("malformed composition identifier was accepted")

        # Negative test: tampered manifest with recomputed valid sidecar hash
        # (Must be rejected by canonical composition reconstruction!)
        tampered_manifest = candidate.load_json(comp_candidate_path)
        tampered_manifest["devshard"]["protocol_version"] = "v99"  # Tampered field
        tampered_path = temporary / "tampered-recomputed-sidecar.json"
        write_json(tampered_path, tampered_manifest)
        tampered_path.with_suffix(".sha256").write_text(
            f"{candidate.sha256(tampered_path)}  {tampered_path.name}\n", encoding="utf-8"
        )
        try:
            candidate.verify_composition(tampered_path)
        except candidate.CandidateError as exc:
            assert "does not match reconstructed canonical composition" in str(exc)
        else:
            raise AssertionError("tampered manifest with valid sidecar was accepted")

        # Negative test: corrupted composition sidecar checksum
        comp_file = compositions / "core-v2026.08.06+devshard-v4.json"
        comp_sidecar = comp_file.with_suffix(".sha256")
        comp_sidecar.write_text("0" * 64 + "  " + comp_file.name + "\n", encoding="utf-8")
        try:
            candidate.verify_composition("core-v2026.08.06+devshard-v4")
        except candidate.CandidateError as exc:
            assert "composition checksum mismatch" in str(exc)
        else:
            raise AssertionError("tampered composition sidecar was accepted")

        # Fix sidecar for next tests
        comp_sidecar.write_text(f"{candidate.sha256(comp_file)}  {comp_file.name}\n", encoding="utf-8")

        # Negative test: invalid network chain_id in composition
        bad_chain_manifest = candidate.load_json(comp_file)
        bad_chain_manifest["network"]["chain_id"] = "wrong-network"
        bad_chain_path = temporary / "bad-chain.json"
        write_json(bad_chain_path, bad_chain_manifest)
        bad_chain_path.with_suffix(".sha256").write_text(
            f"{candidate.sha256(bad_chain_path)}  {bad_chain_path.name}\n", encoding="utf-8"
        )
        try:
            candidate.verify_composition(bad_chain_path)
        except candidate.CandidateError as exc:
            assert "composition chain_id must be gonka-devnet-community" in str(exc)
        else:
            raise AssertionError("invalid network chain_id was accepted")

        # Negative test: missing core profile lock
        bad_core_manifest = candidate.load_json(comp_file)
        bad_core_manifest["core"]["profile"] = "nonexistent-profile"
        bad_core_path = temporary / "bad-core.json"
        write_json(bad_core_path, bad_core_manifest)
        bad_core_path.with_suffix(".sha256").write_text(
            f"{candidate.sha256(bad_core_path)}  {bad_core_path.name}\n", encoding="utf-8"
        )
        try:
            candidate.verify_composition(bad_core_path)
        except candidate.CandidateError as exc:
            assert "release profile lock is missing" in str(exc)
        else:
            raise AssertionError("nonexistent core profile was accepted")

    print("PASS candidate release lifecycle contract")


if __name__ == "__main__":
    main()
