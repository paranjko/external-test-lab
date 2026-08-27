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
        retry_request_lists = 0
        retry_publish_lists = 0
        stale_publish_title = f"publish {request_title} request-101-attempt-1"
        retry_publish_title = f"publish {request_title} request-101-attempt-2"

        def fake_retry_run(
            command: list[str], *, capture: bool = True
        ) -> subprocess.CompletedProcess[str]:
            nonlocal retry_request_lists, retry_publish_lists
            calls.append(command)
            stdout = ""
            if command[:2] == ["git", "show"]:
                stdout = definition_path.read_text(encoding="utf-8")
            elif command[:2] == ["gh", "api"]:
                endpoint = command[-1]
                if candidate.REQUEST_WORKFLOW in endpoint:
                    retry_request_lists += 1
                    stdout = workflow_pages([{
                        "databaseId": 101,
                        "displayTitle": request_title,
                        "status": "completed",
                        "conclusion": (
                            "failure" if retry_request_lists == 1 else "success"
                        ),
                        "attempt": 1 if retry_request_lists == 1 else 2,
                    }])
                elif candidate.PUBLISH_WORKFLOW in endpoint:
                    retry_publish_lists += 1
                    runs = [{
                        "databaseId": 201,
                        "displayTitle": stale_publish_title,
                        "status": "completed",
                        "conclusion": "skipped",
                        "attempt": 1,
                    }]
                    if retry_publish_lists > 1:
                        runs.insert(0, {
                            "databaseId": 202,
                            "displayTitle": retry_publish_title,
                            "status": "in_progress",
                            "conclusion": "",
                            "attempt": 1,
                        })
                    stdout = workflow_pages(runs)
            return subprocess.CompletedProcess(command, 0, stdout=stdout, stderr="")

        candidate.run = fake_retry_run
        output = io.StringIO()
        with redirect_stdout(output):
            candidate.command_build(
                argparse.Namespace(
                    profile="v2026.08.25-rc.0", dry_run=False, retry=True, wait=True
                )
            )
        reruns = [
            command
            for command in calls
            if command[:3] == ["gh", "run", "rerun"]
        ]
        assert reruns == [[
            "gh", "run", "rerun", "101", "--repo", candidate.REPOSITORY, "--failed"
        ]]
        watched = [
            int(command[3])
            for command in calls
            if command[:3] == ["gh", "run", "watch"]
        ]
        assert watched == [101, 202]
        assert downloads == [("v2026.08.25-rc.0", 202)]
        assert "publish_run_id=202" in output.getvalue()

    print("PASS candidate release lifecycle contract")


if __name__ == "__main__":
    main()
