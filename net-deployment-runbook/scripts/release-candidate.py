#!/usr/bin/env python3
"""Prepare, dispatch, materialize, and verify lab candidate releases."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
REPOSITORY_ROOT = ROOT.parent
CANDIDATES = ROOT / "profiles" / "candidates"
RELEASES = ROOT / "profiles" / "releases"
PROFILE_RE = re.compile(r"^v\d{4}\.\d{2}\.\d{2}-rc\.\d+$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
HASH_RE = re.compile(r"^[0-9a-f]{64}$")
REPOSITORY = "paranjko/external-test-lab"
REQUEST_WORKFLOW = "candidate-build.yml"
PUBLISH_WORKFLOW = "candidate-publish.yml"
RUN_DISCOVERY_ATTEMPTS = 120
RUN_DISCOVERY_INTERVAL_SECONDS = 2
REQUIRED_IMAGES = {
    "inferenced",
    "decentralized-api",
    "edge-api",
    "devshardd",
    "devshard-gateway",
    "devshard-host",
    "versiond",
    "versiond-router",
}
REQUIRED_BINARIES = {
    "inferenced-linux-amd64",
    "inferenced-operator-linux-amd64",
    "decentralized-api-linux-amd64",
    "edge-api-linux-amd64",
    "devshardd-linux-amd64",
}


class CandidateError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CandidateError(f"cannot read JSON {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise CandidateError(f"JSON root must be an object: {path}")
    return value


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(temporary, path)
        except FileExistsError:
            existing = path.read_text(encoding="utf-8")
            if existing == content:
                return
            raise CandidateError(
                f"refusing to overwrite incompatible immutable file: {path}"
            ) from None
    finally:
        temporary.unlink(missing_ok=True)


def definition_path(profile: str) -> Path:
    if not PROFILE_RE.fullmatch(profile):
        raise CandidateError(f"invalid candidate profile: {profile}")
    return CANDIDATES / f"{profile}.definition.json"


def verify_definition(profile: str) -> tuple[dict[str, Any], Path, str]:
    path = definition_path(profile)
    definition = load_json(path)
    actual_hash = sha256(path)
    sidecar = path.with_suffix(".sha256")
    try:
        fields = sidecar.read_text(encoding="utf-8").strip().split()
    except OSError as exc:
        raise CandidateError(f"candidate definition checksum is missing: {sidecar}") from exc
    if fields != [actual_hash, path.name]:
        raise CandidateError(f"candidate definition checksum mismatch: {path}")
    if definition.get("schema_version") != 1:
        raise CandidateError("candidate definition schema_version must be 1")
    if definition.get("kind") != "external-test-lab-candidate-definition":
        raise CandidateError("candidate definition kind is invalid")
    if definition.get("profile") != profile:
        raise CandidateError("candidate profile does not match its filename")
    if definition.get("classification") != "lab-candidate":
        raise CandidateError("candidate must be classified as lab-candidate")
    if definition.get("official_gonka_release") is not False:
        raise CandidateError("candidate must not claim to be an official Gonka release")
    if definition.get("upgrade_from_profile") != "v2026.08.06":
        raise CandidateError("candidate must declare upgrade_from_profile v2026.08.06")

    repositories = definition.get("repositories")
    if not isinstance(repositories, dict) or set(repositories) != {"gonka_core", "devshard_v5"}:
        raise CandidateError("candidate must bind gonka_core and devshard_v5 repositories")
    for name, repository in repositories.items():
        if not isinstance(repository, dict):
            raise CandidateError(f"repository binding is invalid: {name}")
        if repository.get("url") != "https://github.com/gonka-ai/gonka.git":
            raise CandidateError(f"repository URL is not allowlisted: {name}")
        if not SHA_RE.fullmatch(str(repository.get("commit", ""))):
            raise CandidateError(f"repository commit is invalid: {name}")
        if not SHA_RE.fullmatch(str(repository.get("tree", ""))):
            raise CandidateError(f"repository tree is invalid: {name}")
        if not str(repository.get("ref", "")).startswith("refs/heads/"):
            raise CandidateError(f"repository ref is not a branch ref: {name}")

    architectures = definition.get("architectures", {})
    expected_architectures = ["linux/amd64"]
    for key in ("observed_laboratory_hosts", "oci_images", "upgrade_binaries"):
        if architectures.get(key) != expected_architectures:
            raise CandidateError(f"candidate architecture set is unsupported: {key}")

    base_images = definition.get("base_images")
    if not isinstance(base_images, list) or not base_images:
        raise CandidateError("candidate base image set is empty")
    for image in base_images:
        if not isinstance(image, dict) or not image.get("reference") or not DIGEST_RE.fullmatch(str(image.get("digest", ""))):
            raise CandidateError("candidate contains an invalid base image binding")

    components = definition.get("components")
    if not isinstance(components, list):
        raise CandidateError("candidate component matrix is missing")
    component_ids = {str(component.get("id", "")) for component in components if isinstance(component, dict)}
    expected_components = {
        "inferenced", "decentralized-api", "edge-api", "devshard-runtime",
        "devshard-host", "versiond", "versiond-router", "mlnode", "proxy",
        "tmkms", "bridge",
    }
    if component_ids != expected_components:
        raise CandidateError("candidate component matrix is incomplete or unexpected")
    inferenced = next(
        component
        for component in components
        if isinstance(component, dict) and component.get("id") == "inferenced"
    )
    if set(inferenced.get("artifacts", [])) != {
        "oci-image", "upgrade-binary", "operator-binary"
    }:
        raise CandidateError("candidate inferenced artifacts are incomplete or unexpected")
    governance = definition.get("governance", {})
    if governance.get("core_upgrade_name") != "v0.2.16":
        raise CandidateError("candidate core upgrade name must be v0.2.16")
    ha = definition.get("features", {}).get("ha", {})
    if ha != {
        "enabled": False,
        "deployment": "excluded",
        "storage_mode": "memory",
    }:
        raise CandidateError(
            "candidate HA must remain excluded until a reviewed v5 deployment lifecycle exists"
        )
    return definition, path, actual_hash


def command_prepare(args: argparse.Namespace) -> None:
    source_ref = args.source_ref.removeprefix("refs/heads/")
    expected_ref = f"refs/heads/{source_ref}"
    matches: list[str] = []
    for path in sorted(CANDIDATES.glob("*.definition.json")):
        candidate = load_json(path)
        if candidate.get("repositories", {}).get("gonka_core", {}).get("ref") == expected_ref:
            matches.append(str(candidate.get("profile", "")))
    if not matches:
        raise CandidateError(
            "no reviewed candidate blueprint is available for this source ref; "
            "freeze the component matrix before resolving a moving upstream ref"
        )
    if len(matches) != 1:
        raise CandidateError(f"source ref is bound by multiple candidate definitions: {', '.join(matches)}")
    definition, path, definition_hash = verify_definition(matches[0])
    core = definition["repositories"]["gonka_core"]
    print(f"READY profile={matches[0]} definition_sha256={definition_hash}")
    print(f"source_ref={core['ref']} source_commit={core['commit']} definition={path}")


def run(command: list[str], *, capture: bool = True) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            cwd=REPOSITORY_ROOT,
            check=True,
            text=True,
            capture_output=capture,
        )
    except FileNotFoundError as exc:
        raise CandidateError(f"required command is unavailable: {command[0]}") from exc
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "command failed").strip()
        raise CandidateError(f"{' '.join(command)}: {detail}") from exc


def candidate_state(profile: str) -> Path:
    data_root = Path(os.environ.get("GDC_HOME", str(Path.home() / ".gdc-data"))).expanduser()
    return data_root / "candidates" / profile


def workflow_runs(workflow: str, event: str) -> list[dict[str, Any]]:
    pages = json.loads(run([
        "gh", "api", "--paginate", "--slurp", "-X", "GET",
        "-f", "branch=main", "-f", f"event={event}", "-f", "per_page=100",
        f"repos/{REPOSITORY}/actions/workflows/{workflow}/runs",
    ]).stdout)
    if not isinstance(pages, list):
        raise CandidateError(f"invalid workflow run listing for {workflow}")
    runs: list[dict[str, Any]] = []
    for page in pages:
        if not isinstance(page, dict) or not isinstance(page.get("workflow_runs"), list):
            raise CandidateError(f"invalid workflow run page for {workflow}")
        for item in page["workflow_runs"]:
            if not isinstance(item, dict):
                raise CandidateError(f"invalid workflow run entry for {workflow}")
            runs.append({
                "databaseId": item.get("id"),
                "displayTitle": item.get("display_title"),
                "status": item.get("status"),
                "conclusion": item.get("conclusion"),
                "attempt": item.get("run_attempt"),
            })
    return runs


def matching_run(workflow: str, event: str, title: str) -> dict[str, Any] | None:
    return next(
        (item for item in workflow_runs(workflow, event) if item.get("displayTitle") == title),
        None,
    )


def wait_for_new_run(
    workflow: str,
    event: str,
    title: str,
    excluded_ids: set[int] | None = None,
) -> dict[str, Any]:
    excluded_ids = excluded_ids or set()
    for _ in range(RUN_DISCOVERY_ATTEMPTS):
        match = matching_run(workflow, event, title)
        if match is not None and int(match["databaseId"]) not in excluded_ids:
            return match
        time.sleep(RUN_DISCOVERY_INTERVAL_SECONDS)
    raise CandidateError(f"timed out discovering workflow run: {title}")


def watch_run(run_id: int) -> None:
    run([
        "gh", "run", "watch", str(run_id), "--repo", REPOSITORY, "--exit-status",
    ], capture=False)


def request_run(run_id: int) -> dict[str, Any]:
    match = next(
        (
            item
            for item in workflow_runs(REQUEST_WORKFLOW, "workflow_dispatch")
            if int(item["databaseId"]) == run_id
        ),
        None,
    )
    if match is None:
        raise CandidateError(f"request workflow run disappeared: {run_id}")
    return match


def command_build(args: argparse.Namespace) -> None:
    _, path, definition_hash = verify_definition(args.profile)
    request_title = f"candidate {args.profile} {definition_hash}"
    dispatch = [
        "gh", "workflow", "run", REQUEST_WORKFLOW, "--repo", REPOSITORY,
        "--ref", "main", "-f", f"candidate_profile={args.profile}",
        "-f", f"candidate_definition_sha256={definition_hash}",
    ]
    if args.dry_run or os.environ.get("GDC_CANDIDATE_DRY_RUN") == "true":
        print(f"DRY_RUN reviewed_ref=main workflow={REQUEST_WORKFLOW} title={request_title}")
        print("command=" + " ".join(dispatch))
        return

    run(["git", "fetch", "--no-tags", "origin", "refs/heads/main:refs/remotes/origin/main"])
    local_path = path.relative_to(REPOSITORY_ROOT)
    remote_definition = run(["git", "show", f"origin/main:{local_path.as_posix()}"]).stdout.encode()
    if hashlib.sha256(remote_definition).hexdigest() != definition_hash:
        raise CandidateError(
            "reviewed origin/main does not contain this exact candidate definition; "
            "merge the reviewed implementation before package publication"
        )

    request_runs = workflow_runs(REQUEST_WORKFLOW, "workflow_dispatch")
    request = next((item for item in request_runs if item.get("displayTitle") == request_title), None)
    if request and request.get("status") != "completed":
        request_run_id = int(request["databaseId"])
        print(f"RESUME profile={args.profile} request_run_id={request_run_id}")
    elif request and request.get("conclusion") != "success" and not args.retry:
        raise CandidateError(
            f"candidate request run {request['databaseId']} concluded {request.get('conclusion')}; "
            "inspect it and rerun with --retry only after the cause is understood"
        )
    elif request and request.get("conclusion") != "success":
        request_run_id = int(request["databaseId"])
        run(["gh", "run", "rerun", str(request_run_id), "--repo", REPOSITORY, "--failed"])
        print(f"RETRY profile={args.profile} request_run_id={request_run_id}")
    elif request:
        request_run_id = int(request["databaseId"])
    else:
        existing_ids = {int(item["databaseId"]) for item in request_runs}
        run(dispatch)
        print(f"DISPATCHED profile={args.profile} definition_sha256={definition_hash}")
        if not args.wait:
            return
        request = wait_for_new_run(
            REQUEST_WORKFLOW, "workflow_dispatch", request_title, existing_ids
        )
        request_run_id = int(request["databaseId"])

    if request.get("conclusion") != "success":
        if not args.wait:
            return
        watch_run(request_run_id)

    request = request_run(request_run_id)
    if request.get("conclusion") != "success":
        raise CandidateError(
            f"candidate request run {request_run_id} did not conclude successfully"
        )
    request_attempt = int(request.get("attempt", 0))
    if request_attempt < 1:
        raise CandidateError(f"candidate request run {request_run_id} has no valid attempt")

    publish_title = (
        f"publish {request_title} request-{request_run_id}-attempt-{request_attempt}"
    )
    publication = matching_run(PUBLISH_WORKFLOW, "workflow_run", publish_title)
    if publication is None:
        if not args.wait:
            print(f"PUBLISH_PENDING profile={args.profile} request_run_id={request_run_id}")
            return
        publication = wait_for_new_run(PUBLISH_WORKFLOW, "workflow_run", publish_title)
    publish_run_id = int(publication["databaseId"])
    if publication.get("conclusion") == "success":
        download_build_artifact(args.profile, publish_run_id)
        print(
            f"READY profile={args.profile} request_run_id={request_run_id} "
            f"publish_run_id={publish_run_id} resumed=true"
        )
        return
    if publication.get("status") == "completed":
        if not args.retry:
            raise CandidateError(
                f"candidate publication run {publish_run_id} concluded "
                f"{publication.get('conclusion')}; inspect it and rerun with --retry only "
                "after the cause is understood"
            )
        run(["gh", "run", "rerun", str(publish_run_id), "--repo", REPOSITORY, "--failed"])
        print(f"RETRY profile={args.profile} publish_run_id={publish_run_id}")
    else:
        print(f"RESUME profile={args.profile} publish_run_id={publish_run_id}")
    if args.wait:
        watch_run(publish_run_id)
        download_build_artifact(args.profile, publish_run_id)
        print(
            f"READY profile={args.profile} request_run_id={request_run_id} "
            f"publish_run_id={publish_run_id} resumed=true"
        )


def download_build_artifact(profile: str, run_id: int) -> None:
    destination = candidate_state(profile) / "build"
    destination.mkdir(parents=True, exist_ok=True)
    manifest = destination / "build-manifest.json"
    if manifest.exists():
        verify_build_manifest(profile, manifest)
        return
    run([
        "gh", "run", "download", str(run_id), "--repo", REPOSITORY,
        "--name", f"candidate-{profile}-build-manifest", "--dir", str(destination),
    ])
    verify_build_manifest(profile, manifest)


def verify_build_manifest(profile: str, path: Path) -> tuple[dict[str, Any], str]:
    definition, _, definition_hash = verify_definition(profile)
    manifest = load_json(path)
    if manifest.get("schema_version") != 1 or manifest.get("kind") != "external-test-lab-candidate-build":
        raise CandidateError("candidate build manifest kind or schema is invalid")
    if manifest.get("profile") != profile or manifest.get("definition_sha256") != definition_hash:
        raise CandidateError("candidate build manifest is not bound to the definition")
    source = manifest.get("source", {})
    for key in ("gonka_core", "devshard_v5"):
        if source.get(key) != definition["repositories"][key]["commit"]:
            raise CandidateError(f"candidate build source mismatch: {key}")
    if manifest.get("architectures") != ["linux/amd64"]:
        raise CandidateError("candidate build architecture is unsupported")
    workflow = manifest.get("workflow", {})
    expected_workflow_ref = (
        "paranjko/external-test-lab/.github/workflows/"
        "candidate-publish.yml@refs/heads/main"
    )
    if (
        workflow.get("repository") != "paranjko/external-test-lab"
        or workflow.get("ref") != expected_workflow_ref
        or not SHA_RE.fullmatch(str(workflow.get("sha", "")))
    ):
        raise CandidateError("candidate build publisher identity is invalid")
    if (
        workflow.get("request_ref") != "refs/heads/main"
        or not SHA_RE.fullmatch(str(workflow.get("request_sha", "")))
    ):
        raise CandidateError("candidate build request identity is invalid")
    for key in ("request_run_id", "run_id", "run_attempt"):
        if not str(workflow.get(key, "")).isdigit():
            raise CandidateError(f"candidate build workflow {key} is invalid")
    run_id = str(workflow["run_id"])
    definition_short = definition_hash[:12]
    release_base = (
        "https://github.com/paranjko/external-test-lab/releases/download/"
        f"lab-candidate%2F{profile}"
    )
    images = manifest.get("images")
    if not isinstance(images, dict) or set(images) != REQUIRED_IMAGES:
        raise CandidateError("candidate build image set is incomplete or unexpected")
    for name, image in images.items():
        expected_reference = (
            f"ghcr.io/paranjko/gdc-{name}:"
            f"{profile}-{definition_short}-{run_id}"
        )
        expected_archive_url = f"{release_base}/{name}-linux-amd64.oci.tar.gz"
        if not isinstance(image, dict) or image.get("reference") != expected_reference:
            raise CandidateError(f"candidate image reference is invalid: {name}")
        if not DIGEST_RE.fullmatch(str(image.get("digest", ""))):
            raise CandidateError(f"candidate image digest is invalid: {name}")
        if image.get("sbom") is not True or image.get("provenance") is not True:
            raise CandidateError(f"candidate image attestations are incomplete: {name}")
        if image.get("deployment_reference") != expected_reference:
            raise CandidateError(f"candidate deployment image was not published: {name}")
        if not HASH_RE.fullmatch(str(image.get("archive_sha256", ""))):
            raise CandidateError(f"candidate image archive checksum is invalid: {name}")
        if image.get("archive_url") != expected_archive_url:
            raise CandidateError(f"candidate image archive URL is invalid: {name}")
    binaries = manifest.get("binaries")
    if not isinstance(binaries, dict) or set(binaries) != REQUIRED_BINARIES:
        raise CandidateError("candidate build binary set is incomplete or unexpected")
    for name, binary in binaries.items():
        component = name.removesuffix("-linux-amd64")
        expected_oci_reference = (
            f"ghcr.io/paranjko/gdc-upgrade-{component}:"
            f"{profile}-{definition_short}-{run_id}"
        )
        expected_url = f"{release_base}/{name}.zip"
        if not isinstance(binary, dict) or not HASH_RE.fullmatch(str(binary.get("sha256", ""))):
            raise CandidateError(f"candidate binary checksum is invalid: {name}")
        if not DIGEST_RE.fullmatch(str(binary.get("oci_digest", ""))):
            raise CandidateError(f"candidate binary OCI digest is invalid: {name}")
        if binary.get("oci_reference") != expected_oci_reference:
            raise CandidateError(f"candidate binary OCI reference is invalid: {name}")
        if binary.get("url") != expected_url:
            raise CandidateError(f"candidate binary release URL is invalid: {name}")
        if binary.get("sbom") is not True or binary.get("provenance") is not True:
            raise CandidateError(f"candidate binary attestations are incomplete: {name}")
    return manifest, sha256(path)


def shell_quote(value: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9_./:@+%=-]+", value):
        return value
    if re.fullmatch(r"[A-Za-z0-9_./:@+% =-]+", value):
        return f"'{value}'"
    raise CandidateError(f"release lock value contains unsupported characters: {value!r}")


def render_lock(profile: str, manifest: dict[str, Any], manifest_hash: str) -> str:
    definition, _, definition_hash = verify_definition(profile)
    images = manifest["images"]
    binaries = manifest["binaries"]
    ha = definition["features"]["ha"]
    reused = {
        component["id"]: component["reference"]
        for component in definition["components"]
        if component.get("action") == "reuse-immutable"
    }
    image = lambda name: f"{images[name]['reference']}@{images[name]['digest']}"
    deployment_image = image
    local_archive_image = lambda name: images[name]["deployment_reference"]
    binary = lambda name: f"{binaries[name]['oci_reference']}@{binaries[name]['oci_digest']}"
    values = {
        "GONKA_SOURCE_REF": definition["repositories"]["gonka_core"]["ref"],
        "GONKA_COMMIT": definition["repositories"]["gonka_core"]["commit"],
        "GONKA_REPOSITORY": definition["repositories"]["gonka_core"]["url"],
        "GONKA_RELEASE": definition["governance"]["core_upgrade_name"].removeprefix("v"),
        "LAB_CANDIDATE": "true",
        "UPGRADE_FROM_PROFILE": definition["upgrade_from_profile"],
        "CANDIDATE_DEFINITION_SHA256": definition_hash,
        "CANDIDATE_BUILD_MANIFEST_SHA256": manifest_hash,
        "JOIN_BOOTSTRAP_FORMAT": "1",
        "TMKMS_IMAGE": reused["tmkms"],
        "INFERENCED_IMAGE": deployment_image("inferenced"),
        "INFERENCED_IMAGE_OCI": image("inferenced"),
        "INFERENCED_IMAGE_ARCHIVE_URL": images["inferenced"]["archive_url"],
        "INFERENCED_IMAGE_ARCHIVE_SHA256": images["inferenced"]["archive_sha256"],
        "INFERENCED_OPERATOR_URL_LINUX_AMD64": binaries["inferenced-operator-linux-amd64"]["url"],
        "INFERENCED_OPERATOR_SHA256_LINUX_AMD64": binaries["inferenced-operator-linux-amd64"]["sha256"],
        "INFERENCED_UPGRADE_URL": binaries["inferenced-linux-amd64"]["url"],
        "INFERENCED_UPGRADE_SHA256": binaries["inferenced-linux-amd64"]["sha256"],
        "INFERENCED_UPGRADE_OCI_LINUX_AMD64": binary("inferenced-linux-amd64"),
        "INFERENCED_UPGRADE_SHA256_LINUX_AMD64": binaries["inferenced-linux-amd64"]["sha256"],
        "DAPI_IMAGE": deployment_image("decentralized-api"),
        "DAPI_IMAGE_OCI": image("decentralized-api"),
        "DAPI_IMAGE_ARCHIVE_URL": images["decentralized-api"]["archive_url"],
        "DAPI_IMAGE_ARCHIVE_SHA256": images["decentralized-api"]["archive_sha256"],
        "DAPI_UPGRADE_URL": binaries["decentralized-api-linux-amd64"]["url"],
        "DAPI_UPGRADE_SHA256": binaries["decentralized-api-linux-amd64"]["sha256"],
        "DAPI_UPGRADE_OCI_LINUX_AMD64": binary("decentralized-api-linux-amd64"),
        "DAPI_UPGRADE_SHA256_LINUX_AMD64": binaries["decentralized-api-linux-amd64"]["sha256"],
        "EDGE_API_IMAGE": deployment_image("edge-api"),
        "EDGE_API_IMAGE_OCI": image("edge-api"),
        "EDGE_API_IMAGE_ARCHIVE_URL": images["edge-api"]["archive_url"],
        "EDGE_API_IMAGE_ARCHIVE_SHA256": images["edge-api"]["archive_sha256"],
        "EDGE_API_ENABLED": "true",
        "EDGE_API_COMPOSE_PROFILE": "edge-api",
        "EDGE_API_SERVICE_NAME": "edge-api",
        "EDGE_API_UPGRADE_OCI_LINUX_AMD64": binary("edge-api-linux-amd64"),
        "EDGE_API_UPGRADE_SHA256_LINUX_AMD64": binaries["edge-api-linux-amd64"]["sha256"],
        "DEVSHARDD_IMAGE": deployment_image("devshardd"),
        "DEVSHARDD_IMAGE_OCI": image("devshardd"),
        "DEVSHARDD_IMAGE_ARCHIVE_URL": images["devshardd"]["archive_url"],
        "DEVSHARDD_IMAGE_ARCHIVE_SHA256": images["devshardd"]["archive_sha256"],
        "DEVSHARD_V5_URL": binaries["devshardd-linux-amd64"]["url"],
        "DEVSHARD_V5_SHA256": binaries["devshardd-linux-amd64"]["sha256"],
        "DEVSHARDD_UPGRADE_OCI_LINUX_AMD64": binary("devshardd-linux-amd64"),
        "DEVSHARDD_UPGRADE_SHA256_LINUX_AMD64": binaries["devshardd-linux-amd64"]["sha256"],
        "DEVSHARD_GATEWAY_IMAGE": deployment_image("devshard-gateway"),
        "DEVSHARD_GATEWAY_IMAGE_OCI": image("devshard-gateway"),
        "DEVSHARD_GATEWAY_IMAGE_ARCHIVE_URL": images["devshard-gateway"]["archive_url"],
        "DEVSHARD_GATEWAY_IMAGE_ARCHIVE_SHA256": images["devshard-gateway"]["archive_sha256"],
        "DEVSHARD_HOST_IMAGE": deployment_image("devshard-host"),
        "DEVSHARD_HOST_IMAGE_OCI": image("devshard-host"),
        "DEVSHARD_HOST_IMAGE_ARCHIVE_URL": images["devshard-host"]["archive_url"],
        "DEVSHARD_HOST_IMAGE_ARCHIVE_SHA256": images["devshard-host"]["archive_sha256"],
        "VERSIOND_IMAGE": deployment_image("versiond"),
        "VERSIOND_IMAGE_OCI": image("versiond"),
        "VERSIOND_IMAGE_ARCHIVE_URL": images["versiond"]["archive_url"],
        "VERSIOND_IMAGE_ARCHIVE_SHA256": images["versiond"]["archive_sha256"],
        "VERSIOND_ROUTER_IMAGE": deployment_image("versiond-router"),
        "VERSIOND_ROUTER_IMAGE_OCI": image("versiond-router"),
        "VERSIOND_ROUTER_IMAGE_ARCHIVE_URL": images["versiond-router"]["archive_url"],
        "VERSIOND_ROUTER_IMAGE_ARCHIVE_SHA256": images["versiond-router"]["archive_sha256"],
        "CANDIDATE_DEVSHARD_SOURCE_REF": definition["repositories"]["devshard_v5"]["ref"],
        "CANDIDATE_DEVSHARD_COMMIT": definition["repositories"]["devshard_v5"]["commit"],
        "CANDIDATE_DEVSHARD_PROTOCOL_VERSION": "v5",
        "CANDIDATE_DEVSHARD_SUPPORTED_PROTOCOLS": "v3 v5",
        "CANDIDATE_LOCAL_GATEWAY_IMAGE": local_archive_image("devshard-gateway"),
        "CANDIDATE_POSTGRES_IMAGE": "postgres:16-alpine@sha256:cf78e76683b9ca8c5733cbbdce6c9262b45b6767934dd0a95e671f9a0fc20685",
        "PROXY_IMAGE": reused["proxy"],
        "MLNODE_GENERIC_IMAGE": reused["mlnode"],
        "MLNODE_PROXY_IMAGE": "nginx:1.28.0@sha256:552e7481ca93ffccd046aa658dbbed22caefbc09c66fa7cd247cbb90b8a5c609",
        "BRIDGE_IMAGE": reused["bridge"],
        "GONKA_UPGRADE_METADATA_URL": f"https://github.com/paranjko/external-test-lab/releases/tag/lab-candidate%2F{profile}",
        "DEVSHARD_HEIGHTSYNC": "true",
        "DEVSHARD_HEIGHTSYNC_K": "10",
        "DEVSHARD_HEIGHTSYNC_SLOTS": "1",
        "GONKA_HA": str(ha["enabled"]).lower(),
        "DEVSHARD_STORAGE_MODE": ha["storage_mode"],
        "GDC_JOIN_EFFECTIVE_EPOCHS": "4",
        "GDC_JOIN_EFFECTIVE_TIMEOUT_SECONDS": "7200",
        "GDC_CPOC_PROBE_EPOCHS": "4",
        "GDC_CPOC_PROBE_TIMEOUT_SECONDS": "7200",
        "GDC_CPOC_PROBE_POLL_SECONDS": "5",
        "GDC_UPGRADE_MIN_LEAD_BLOCKS": "60",
        "GDC_GATE_B_PROGRESS_TIMEOUT_SECONDS": "120",
        "GDC_GATE_B_PROGRESS_POLL_SECONDS": "2",
        "GDC_HOST_UPGRADE_WATCH_TIMEOUT_SECONDS": "21600",
        "GDC_HOST_UPGRADE_WATCH_POLL_SECONDS": "5",
        "GDC_MAX_NODE_LAG_BLOCKS": "5",
    }
    lines = [
        f"# Immutable External Test Lab candidate {profile}.",
        "# This is not an official Gonka release or readiness statement.",
    ]
    lines.extend(f"{key}={shell_quote(str(value))}" for key, value in values.items())
    return "\n".join(lines) + "\n"


def command_profile(args: argparse.Namespace) -> None:
    manifest_path = Path(args.build_manifest).resolve() if args.build_manifest else candidate_state(args.profile) / "build" / "build-manifest.json"
    manifest, manifest_hash = verify_build_manifest(args.profile, manifest_path)
    lock = RELEASES / f"{args.profile}.lock"
    atomic_write(lock, render_lock(args.profile, manifest, manifest_hash))
    print(f"READY profile={args.profile} release_lock={lock} build_manifest_sha256={manifest_hash}")


def parse_lock(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise CandidateError(f"candidate release lock is missing: {path}") from exc
    for line in lines:
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise CandidateError(f"invalid release lock line: {line}")
        key, value = line.split("=", 1)
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key) or key in values:
            raise CandidateError(f"invalid or duplicate release lock key: {key}")
        values[key] = value
    return values


def command_verify(args: argparse.Namespace) -> None:
    _, _, definition_hash = verify_definition(args.profile)
    lock_path = RELEASES / f"{args.profile}.lock"
    lock = parse_lock(lock_path)
    if lock.get("LAB_CANDIDATE") != "true" or lock.get("UPGRADE_FROM_PROFILE") != "v2026.08.06":
        raise CandidateError("candidate release lock classification or upgrade source is invalid")
    if lock.get("CANDIDATE_DEFINITION_SHA256") != definition_hash:
        raise CandidateError("candidate release lock is not bound to its definition")
    manifest_path = Path(args.build_manifest).resolve() if args.build_manifest else candidate_state(args.profile) / "build" / "build-manifest.json"
    _, manifest_hash = verify_build_manifest(args.profile, manifest_path)
    if lock.get("CANDIDATE_BUILD_MANIFEST_SHA256") != manifest_hash:
        raise CandidateError("candidate release lock is not bound to its build manifest")
    expected = render_lock(args.profile, load_json(manifest_path), manifest_hash)
    if lock_path.read_text(encoding="utf-8") != expected:
        raise CandidateError("candidate release lock does not match the verified build manifest")
    print(f"PASS profile={args.profile} definition_sha256={definition_hash} build_manifest_sha256={manifest_hash}")


def parser() -> argparse.ArgumentParser:
    command = argparse.ArgumentParser(description=__doc__)
    subcommands = command.add_subparsers(dest="command", required=True)
    prepare = subcommands.add_parser("prepare")
    prepare.add_argument("--source-ref", required=True)
    prepare.set_defaults(func=command_prepare)
    build = subcommands.add_parser("build")
    build.add_argument("profile")
    build.add_argument("--dry-run", action="store_true")
    build.add_argument("--retry", action="store_true")
    build.add_argument("--wait", action="store_true")
    build.set_defaults(func=command_build)
    profile = subcommands.add_parser("profile")
    profile.add_argument("profile")
    profile.add_argument("--build-manifest")
    profile.set_defaults(func=command_profile)
    verify = subcommands.add_parser("verify")
    verify.add_argument("profile")
    verify.add_argument("--build-manifest")
    verify.set_defaults(func=command_verify)
    return command


def main() -> int:
    try:
        args = parser().parse_args()
        args.func(args)
        return 0
    except CandidateError as exc:
        print(f"ERROR candidate stage={getattr(locals().get('args', None), 'command', 'parse')} detail={exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
