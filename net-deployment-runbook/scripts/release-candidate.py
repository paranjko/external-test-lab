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
import urllib.parse
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
REPOSITORY_ROOT = ROOT.parent
CANDIDATES = ROOT / "profiles" / "candidates"
RELEASES = ROOT / "profiles" / "releases"
DEPLOYMENTS = ROOT / "profiles" / "deployments"
COMPOSITIONS = ROOT / "profiles" / "compositions"
PROFILE_RE = re.compile(r"^v\d{4}\.\d{2}\.\d{2}-rc\.\d+$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
HASH_RE = re.compile(r"^[0-9a-f]{64}$")
CANONICAL_CHAIN_ID = "gonka-devnet-community"
CANONICAL_GENESIS_SHA256 = "93c32ec403d59af6337c0d79c3ee16010c99394f8ecd9aee4fc72a898f64a9a6"
CANONICAL_BASELINE_PROFILE = "v2026.08.06"
REPOSITORY = "paranjko/external-test-lab"
REQUEST_WORKFLOW = "candidate-build.yml"
PUBLISH_WORKFLOW = "candidate-publish.yml"
RUN_DISCOVERY_ATTEMPTS = 120
RUN_DISCOVERY_INTERVAL_SECONDS = 2
CORE_REQUIRED_IMAGES = {
    "inferenced",
    "decentralized-api",
    "edge-api",
    "versiond",
    "versiond-router",
}
CORE_REQUIRED_BINARIES = {
    "inferenced-linux-amd64",
    "inferenced-operator-linux-amd64",
    "decentralized-api-linux-amd64",
    "edge-api-linux-amd64",
}
DEVSHARD_REQUIRED_IMAGES = {
    "devshardd",
    "devshard-gateway",
    "devshard-host",
}
DEVSHARD_REQUIRED_BINARIES = {
    "devshardd-linux-amd64",
}
REQUIRED_IMAGES = CORE_REQUIRED_IMAGES | DEVSHARD_REQUIRED_IMAGES
REQUIRED_BINARIES = CORE_REQUIRED_BINARIES | DEVSHARD_REQUIRED_BINARIES
LEGACY_SOURCE_IDENTITY_DEFINITIONS = {
    "v2026.08.25-rc.0": "74fc6807051c327631c707a69cb5527370e543f0b9c93cecf8db925287174e0f",
    "v2026.08.27-rc.0": "71e9b64d931d3eb8e150a3a5de48f2f20efd644bc9f5e3f06f8eda1d0a3891cc",
    "v2026.08.30-rc.0": "956a7758af5ba16cb47e7c09e8f18a8b3646ee1486d86749e3cf1db5c1820d86",
}


def required_images_for_layer(layer: str) -> set[str]:
    if layer == "core":
        return CORE_REQUIRED_IMAGES
    if layer == "devshard":
        return DEVSHARD_REQUIRED_IMAGES
    return REQUIRED_IMAGES


def required_binaries_for_layer(layer: str) -> set[str]:
    if layer == "core":
        return CORE_REQUIRED_BINARIES
    if layer == "devshard":
        return DEVSHARD_REQUIRED_BINARIES
    return REQUIRED_BINARIES


def publication_contract(definition: dict[str, Any], profile: str) -> dict[str, Any]:
    """Resolve immutable release naming while preserving historical manifests."""
    layer = str(definition.get("layer", "all"))
    required_binaries = required_binaries_for_layer(layer)
    publication = definition.get("publication")
    if publication is None:
        tag = f"lab-candidate/{profile}"
        binary_assets = {name: f"{name}.zip" for name in required_binaries}
    else:
        if not isinstance(publication, dict) or publication.get("schema_version") != 1:
            raise CandidateError("candidate publication contract is invalid")
        tag = str(publication.get("release_tag", ""))
        binary_assets = publication.get("binary_assets")
        if tag != profile:
            raise CandidateError("candidate release tag must equal its profile")
        if not isinstance(binary_assets, dict) or set(binary_assets) != required_binaries:
            raise CandidateError("candidate publication binary asset set is incomplete or unexpected")
        if len(set(binary_assets.values())) != len(binary_assets):
            raise CandidateError("candidate publication binary asset names must be unique")
        for name, asset in binary_assets.items():
            if not isinstance(asset, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.zip", asset):
                raise CandidateError(f"candidate publication binary asset name is invalid: {name}")
    return {
        "release_tag": tag,
        "release_url_segment": urllib.parse.quote(tag, safe=""),
        "binary_assets": binary_assets,
    }


class CandidateError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def component_build_arguments(definition: dict[str, Any], component_id: str) -> dict[str, str]:
    components = definition.get("components", [])
    component = next(
        (
            item
            for item in components
            if isinstance(item, dict) and item.get("id") == component_id
        ),
        None,
    )
    if component is None:
        raise CandidateError(f"candidate component is missing: {component_id}")
    build_args = component.get("build_args", {})
    if not isinstance(build_args, dict) or not all(
        isinstance(key, str) and isinstance(value, str)
        for key, value in build_args.items()
    ):
        raise CandidateError(f"candidate component build arguments are invalid: {component_id}")
    return build_args


def render_build_arguments(build_args: dict[str, str]) -> str:
    return "\n".join(f"{key}={value}" for key, value in build_args.items())


def canonical_github_repository_url(value: str) -> str:
    if value.startswith("git@github.com:"):
        value = "https://github.com/" + value.removeprefix("git@github.com:")
    return value.removesuffix(".git")


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CandidateError(f"cannot read JSON {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise CandidateError(f"JSON root must be an object: {path}")
    return value


def load_json_snapshot(path: Path) -> tuple[dict[str, Any], bytes]:
    try:
        content = path.read_bytes()
        value = json.loads(content.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CandidateError(f"cannot read JSON {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise CandidateError(f"JSON root must be an object: {path}")
    return value, content


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


def atomic_write_bytes(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(temporary, path)
        except FileExistsError:
            if path.read_bytes() == content:
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

    layer = definition.get("layer", "all")
    if layer not in {"core", "devshard", "all"}:
        raise CandidateError(f"invalid candidate layer: {layer}")

    repositories = definition.get("repositories")
    if not isinstance(repositories, dict):
        raise CandidateError("candidate must bind repositories")
    if layer == "core":
        if "gonka_core" not in repositories:
            raise CandidateError("core candidate must bind gonka_core repository")
    elif layer == "devshard":
        if "devshard_v5" not in repositories and "devshard" not in repositories:
            raise CandidateError("devshard candidate must bind devshard_v5 repository")
    elif layer == "all":
        if set(repositories) != {"gonka_core", "devshard_v5"}:
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

    source_identity_contract = definition.get("source_identity_contract")
    if source_identity_contract is None:
        if LEGACY_SOURCE_IDENTITY_DEFINITIONS.get(profile) != actual_hash:
            raise CandidateError(
                "candidate without a source identity contract is not an exact frozen historical definition"
            )
    else:
        if source_identity_contract != "git-object-and-github-signature-v1":
            raise CandidateError("candidate source identity contract is unsupported")
        for name, repository in repositories.items():
            signature = repository.get("signature")
            if not isinstance(signature, dict):
                raise CandidateError(f"repository signature binding is missing: {name}")
            if (
                signature.get("provider") != "github"
                or signature.get("verified") is not True
                or signature.get("reason") != "valid"
                or not HASH_RE.fullmatch(str(signature.get("signature_sha256", "")))
                or not HASH_RE.fullmatch(str(signature.get("payload_sha256", "")))
            ):
                raise CandidateError(f"repository signature binding is invalid: {name}")

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

    if layer == "core":
        expected_core = {
            "inferenced", "decentralized-api", "edge-api",
            "versiond", "versiond-router", "mlnode", "proxy",
            "tmkms", "bridge",
        }
        if not expected_core.issubset(component_ids):
            raise CandidateError("core candidate component matrix is incomplete")
        inferenced = next(
            (c for c in components if isinstance(c, dict) and c.get("id") == "inferenced"),
            None,
        )
        if not inferenced or set(inferenced.get("artifacts", [])) != {
            "oci-image", "upgrade-binary", "operator-binary"
        }:
            raise CandidateError("candidate inferenced artifacts are incomplete or unexpected")
        governance = definition.get("governance", {})
        if governance.get("core_upgrade_name") != "v0.2.16":
            raise CandidateError("candidate core upgrade name must be v0.2.16")
        core_version = governance["core_upgrade_name"].removeprefix("v")
        core_commit = str(repositories["gonka_core"]["commit"])
        inferenced_ldflags = (
            "-X github.com/cosmos/cosmos-sdk/version.Name=inference-chain "
            "-X github.com/cosmos/cosmos-sdk/version.AppName=inferenced "
            f"-X github.com/cosmos/cosmos-sdk/version.Version={core_version} "
            f"-X github.com/cosmos/cosmos-sdk/version.Commit={core_commit}"
        )
        dapi_ldflags = (
            "-X github.com/cosmos/cosmos-sdk/version.Name=decentralized-api "
            "-X github.com/cosmos/cosmos-sdk/version.AppName=decentralized-api "
            f"-X github.com/cosmos/cosmos-sdk/version.Version={core_version} "
            f"-X github.com/cosmos/cosmos-sdk/version.Commit={core_commit}"
        )
        if source_identity_contract is not None:
            expected_inferenced_args = {
                "GOOS": "linux",
                "GOARCH": "amd64",
                "BLST_PORTABLE": "0",
                "LDFLAGS": inferenced_ldflags,
            }
            expected_dapi_args = {
                "GOOS": "linux",
                "GOARCH": "amd64",
                "BLST_PORTABLE": "0",
                "DEVSHARD_VERSION": "v5",
                "LDFLAGS": dapi_ldflags,
            }
            if component_build_arguments(definition, "inferenced") != expected_inferenced_args:
                raise CandidateError("candidate inferenced build arguments are incomplete or unexpected")
            if component_build_arguments(definition, "decentralized-api") != expected_dapi_args:
                raise CandidateError("candidate DAPI build arguments are incomplete or unexpected")

            devshard_baseline = definition.get("devshard_baseline")
            if not isinstance(devshard_baseline, dict):
                raise CandidateError("core candidate required DevShard profile is missing")
            if (
                not PROFILE_RE.fullmatch(str(devshard_baseline.get("profile", "")))
                or not HASH_RE.fullmatch(str(devshard_baseline.get("definition_sha256", "")))
                or not HASH_RE.fullmatch(str(devshard_baseline.get("build_manifest_sha256", "")))
                or not HASH_RE.fullmatch(str(devshard_baseline.get("release_lock_sha256", "")))
            ):
                raise CandidateError("core candidate required DevShard identity is invalid")

    elif layer == "devshard":
        expected_devshard = {"devshard-runtime", "devshard-host"}
        if not expected_devshard.issubset(component_ids):
            raise CandidateError("devshard candidate component matrix is incomplete")
    elif layer == "all":
        expected_components = {
            "inferenced", "decentralized-api", "edge-api", "devshard-runtime",
            "devshard-host", "versiond", "versiond-router", "mlnode", "proxy",
            "tmkms", "bridge",
        }
        if component_ids != expected_components:
            raise CandidateError("candidate component matrix is incomplete or unexpected")
        inferenced = next(
            (c for c in components if isinstance(c, dict) and c.get("id") == "inferenced"),
            None,
        )
        if not inferenced or set(inferenced.get("artifacts", [])) != {
            "oci-image", "upgrade-binary", "operator-binary"
        }:
            raise CandidateError("candidate inferenced artifacts are incomplete or unexpected")
        governance = definition.get("governance", {})
        if governance.get("core_upgrade_name") != "v0.2.16":
            raise CandidateError("candidate core upgrade name must be v0.2.16")

    ha = definition.get("features", {}).get("ha", {})
    if ha and ha != {
        "enabled": False,
        "deployment": "excluded",
        "storage_mode": "memory",
    }:
        raise CandidateError(
            "candidate HA must remain excluded until a reviewed v5 deployment lifecycle exists"
        )
    publication_contract(definition, profile)
    return definition, path, actual_hash


def command_prepare(args: argparse.Namespace) -> None:
    source_ref = args.source_ref.removeprefix("refs/heads/")
    expected_ref = f"refs/heads/{source_ref}"
    target_layer = getattr(args, "layer", None)
    matches: list[tuple[str, str]] = []
    for path in sorted(CANDIDATES.glob("*.definition.json")):
        candidate = load_json(path)
        cand_layer = candidate.get("layer", "all")
        # A layer-qualified prepare must never fall back to a historical
        # combined definition.  That would silently reintroduce components
        # outside the frozen candidate boundary when both definitions bind
        # the same moving upstream ref.
        if target_layer and cand_layer != target_layer:
            continue
        repos = candidate.get("repositories", {})
        if not isinstance(repos, dict):
            continue
        for repo_info in repos.values():
            if isinstance(repo_info, dict) and repo_info.get("ref") == expected_ref:
                matches.append((str(candidate.get("profile", "")), cand_layer))
                break
    if not matches:
        raise CandidateError(
            "no reviewed candidate blueprint is available for this source ref; "
            "freeze the component matrix before resolving a moving upstream ref"
        )
    if len(matches) != 1:
        match_names = [m[0] for m in matches]
        raise CandidateError(f"source ref is bound by multiple candidate definitions: {', '.join(match_names)}")
    profile_name, profile_layer = matches[0]
    definition, path, definition_hash = verify_definition(profile_name)
    repo_key = "gonka_core" if "gonka_core" in definition["repositories"] else list(definition["repositories"].keys())[0]
    repo = definition["repositories"][repo_key]
    print(f"READY profile={profile_name} layer={profile_layer} definition_sha256={definition_hash}")
    print(f"source_ref={repo['ref']} source_commit={repo['commit']} definition={path}")


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


def verify_source_identity(
    profile: str,
    repository_key: str,
    repository_path: Path,
    verification_path: Path,
) -> None:
    definition, _, _ = verify_definition(profile)
    if definition.get("source_identity_contract") != "git-object-and-github-signature-v1":
        raise CandidateError("candidate does not declare the source identity verification contract")
    binding = definition.get("repositories", {}).get(repository_key)
    if not isinstance(binding, dict):
        raise CandidateError(f"candidate repository binding is missing: {repository_key}")
    if not repository_path.is_dir():
        raise CandidateError(f"candidate source repository is missing: {repository_path}")

    expected_url = str(binding["url"])
    actual_url = run(
        ["git", "-C", str(repository_path), "remote", "get-url", "origin"]
    ).stdout.strip()
    if canonical_github_repository_url(actual_url) != canonical_github_repository_url(expected_url):
        raise CandidateError(
            f"candidate source remote mismatch: {repository_key} expected={expected_url} actual={actual_url}"
        )

    commit = str(binding["commit"])
    tree = str(binding["tree"])
    branch = str(binding["ref"]).removeprefix("refs/heads/")
    remote_ref = f"refs/remotes/origin/{branch}"
    run(["git", "-C", str(repository_path), "cat-file", "-e", f"{commit}^{{commit}}"])
    actual_tree = run(
        ["git", "-C", str(repository_path), "rev-parse", f"{commit}^{{tree}}"]
    ).stdout.strip()
    if actual_tree != tree:
        raise CandidateError(
            f"candidate source tree mismatch: {repository_key} expected={tree} actual={actual_tree}"
        )
    run(["git", "-C", str(repository_path), "show-ref", "--verify", remote_ref])
    run(["git", "-C", str(repository_path), "merge-base", "--is-ancestor", commit, remote_ref])

    verification = load_json(verification_path)
    commit_document = verification.get("commit")
    if not isinstance(commit_document, dict):
        raise CandidateError("candidate source verification document is malformed")
    verification_record = commit_document.get("verification")
    tree_document = commit_document.get("tree")
    if not isinstance(verification_record, dict) or not isinstance(tree_document, dict):
        raise CandidateError("candidate source verification document is incomplete")
    expected_signature = binding["signature"]
    signature = verification_record.get("signature")
    payload = verification_record.get("payload")
    if (
        verification.get("sha") != commit
        or tree_document.get("sha") != tree
        or verification_record.get("verified") is not True
        or verification_record.get("reason") != "valid"
        or not isinstance(signature, str)
        or not isinstance(payload, str)
        or sha256_text(signature) != expected_signature["signature_sha256"]
        or sha256_text(payload) != expected_signature["payload_sha256"]
    ):
        raise CandidateError("candidate source signature verification does not match the frozen identity")


def command_source_verify(args: argparse.Namespace) -> None:
    verify_source_identity(
        args.profile,
        args.repository_key,
        Path(args.repository).resolve(),
        Path(args.verification_json).resolve(),
    )
    print(
        f"PASS source_identity profile={args.profile} repository={args.repository_key}"
    )


def candidate_state(profile: str) -> Path:
    data_root = Path(os.environ.get("GDC_HOME", str(Path.home() / ".gdc-data"))).expanduser()
    return data_root / "candidates" / profile


def retained_build_manifest(profile: str) -> Path:
    return RELEASES / profile / "build-manifest.json"


def resolve_build_manifest(
    profile: str,
    supplied: str | None,
    *,
    prefer_retained: bool,
) -> Path:
    if supplied:
        return Path(supplied).resolve()
    retained = retained_build_manifest(profile)
    state_manifest = candidate_state(profile) / "build" / "build-manifest.json"
    if prefer_retained and retained.is_file():
        return retained
    if state_manifest.is_file():
        return state_manifest
    if retained.is_file():
        return retained
    return state_manifest


def preserve_build_manifest(profile: str, content: bytes, manifest_hash: str) -> Path:
    destination = retained_build_manifest(profile)
    if hashlib.sha256(content).hexdigest() != manifest_hash:
        raise CandidateError("candidate build manifest snapshot checksum mismatch")
    atomic_write_bytes(destination, content)
    if sha256(destination) != manifest_hash:
        raise CandidateError("retained candidate build manifest checksum mismatch")
    atomic_write(
        destination.with_suffix(".sha256"),
        f"{manifest_hash}  {destination.name}\n",
    )
    return destination


def verify_retained_manifest_sidecar(path: Path, manifest_hash: str) -> None:
    sidecar = path.with_suffix(".sha256")
    try:
        fields = sidecar.read_text(encoding="utf-8").strip().split()
    except OSError as exc:
        raise CandidateError(f"candidate build manifest checksum is missing: {sidecar}") from exc
    if fields != [manifest_hash, path.name]:
        raise CandidateError(f"candidate build manifest checksum mismatch: {path}")


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
    retry_with_fresh_request = False
    if request and request.get("status") == "completed" and request.get("conclusion") == "success":
        request_run_id = int(request["databaseId"])
        request_attempt = int(request.get("attempt", 0))
        if request_attempt < 1:
            raise CandidateError(f"candidate request run {request_run_id} has no valid attempt")
        previous_publish_title = (
            f"publish {request_title} request-{request_run_id}-attempt-{request_attempt}"
        )
        previous_publication = matching_run(
            PUBLISH_WORKFLOW, "workflow_run", previous_publish_title
        )
        retry_with_fresh_request = bool(
            args.retry
            and previous_publication
            and previous_publication.get("status") == "completed"
            and previous_publication.get("conclusion") != "success"
        )
    if request and request.get("status") != "completed":
        request_run_id = int(request["databaseId"])
        print(f"RESUME profile={args.profile} request_run_id={request_run_id}")
    elif request and request.get("conclusion") != "success" and not args.retry:
        raise CandidateError(
            f"candidate request run {request['databaseId']} concluded {request.get('conclusion')}; "
            "inspect it and rerun with --retry only after the cause is understood"
        )
    elif request and (request.get("conclusion") != "success" or retry_with_fresh_request):
        existing_ids = {int(item["databaseId"]) for item in request_runs}
        run(dispatch)
        print(f"RETRY profile={args.profile} definition_sha256={definition_hash} fresh_request=true")
        if not args.wait:
            return
        request = wait_for_new_run(
            REQUEST_WORKFLOW, "workflow_dispatch", request_title, existing_ids
        )
        request_run_id = int(request["databaseId"])
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
        raise CandidateError(
            f"candidate publication run {publish_run_id} failed after request selection; "
            "rerun with --retry to dispatch a fresh reviewed candidate request"
        )
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


def verify_build_manifest_snapshot(
    profile: str,
    path: Path,
) -> tuple[dict[str, Any], str, bytes]:
    definition, _, definition_hash = verify_definition(profile)
    layer = definition.get("layer", "all")
    manifest, content = load_json_snapshot(path)
    if manifest.get("schema_version") != 1 or manifest.get("kind") != "external-test-lab-candidate-build":
        raise CandidateError("candidate build manifest kind or schema is invalid")
    if manifest.get("profile") != profile or manifest.get("definition_sha256") != definition_hash:
        raise CandidateError("candidate build manifest is not bound to the definition")
    source = manifest.get("source", {})
    for key, repo_info in definition["repositories"].items():
        if source.get(key) != repo_info["commit"]:
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
    publication = publication_contract(definition, profile)
    release_base = (
        "https://github.com/paranjko/external-test-lab/releases/download/"
        f"{publication['release_url_segment']}"
    )
    req_images = required_images_for_layer(layer)
    images = manifest.get("images")
    if not isinstance(images, dict) or set(images) != req_images:
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
    req_binaries = required_binaries_for_layer(layer)
    binaries = manifest.get("binaries")
    if not isinstance(binaries, dict) or set(binaries) != req_binaries:
        raise CandidateError("candidate build binary set is incomplete or unexpected")
    for name, binary in binaries.items():
        component = name.removesuffix("-linux-amd64")
        expected_oci_reference = (
            f"ghcr.io/paranjko/gdc-upgrade-{component}:"
            f"{profile}-{definition_short}-{run_id}"
        )
        expected_url = f"{release_base}/{publication['binary_assets'][name]}"
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
    return manifest, hashlib.sha256(content).hexdigest(), content


def verify_build_manifest(profile: str, path: Path) -> tuple[dict[str, Any], str]:
    manifest, manifest_hash, _ = verify_build_manifest_snapshot(profile, path)
    return manifest, manifest_hash


def shell_quote(value: str) -> str:
    if value == "":
        return "''"
    if re.fullmatch(r"[A-Za-z0-9_./:@+%=-]+", value):
        return value
    if re.fullmatch(r"[A-Za-z0-9_./:@+% =-]+", value):
        return f"'{value}'"
    raise CandidateError(f"release lock value contains unsupported characters: {value!r}")


def render_lock(profile: str, manifest: dict[str, Any], manifest_hash: str) -> str:
    definition, _, definition_hash = verify_definition(profile)
    layer = definition.get("layer", "all")
    images = manifest["images"]
    binaries = manifest["binaries"]
    ha = definition.get("features", {}).get("ha", {"enabled": False, "storage_mode": "memory"})
    reused = {
        component["id"]: component["reference"]
        for component in definition.get("components", [])
        if component.get("action") == "reuse-immutable"
    }
    image = lambda name: f"{images[name]['reference']}@{images[name]['digest']}"
    deployment_image = image
    local_archive_image = lambda name: images[name]["deployment_reference"]
    binary = lambda name: f"{binaries[name]['oci_reference']}@{binaries[name]['oci_digest']}"

    values: dict[str, Any] = {
        "LAB_CANDIDATE": "true",
        "CANDIDATE_LAYER": layer,
        "UPGRADE_FROM_PROFILE": definition["upgrade_from_profile"],
        "CANDIDATE_DEFINITION_SHA256": definition_hash,
        "CANDIDATE_BUILD_MANIFEST_SHA256": manifest_hash,
    }
    if layer in {"core", "all"}:
        values.update({
            "GONKA_SOURCE_REF": definition["repositories"]["gonka_core"]["ref"],
            "GONKA_COMMIT": definition["repositories"]["gonka_core"]["commit"],
            "GONKA_REPOSITORY": definition["repositories"]["gonka_core"]["url"],
            "GONKA_RELEASE": definition["governance"]["core_upgrade_name"].removeprefix("v"),
            "JOIN_BOOTSTRAP_FORMAT": "1",
            "TMKMS_IMAGE": reused.get("tmkms", "ghcr.io/paranjko/gdc-tmkms:v0.15.2@sha256:d5cbba97e74cb2feaa16279f64bfcb2ad76a91ee30ebddbfdc00c3b0dfb9ce1d"),
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
            "VERSIOND_IMAGE": deployment_image("versiond"),
            "VERSIOND_IMAGE_OCI": image("versiond"),
            "VERSIOND_IMAGE_ARCHIVE_URL": images["versiond"]["archive_url"],
            "VERSIOND_IMAGE_ARCHIVE_SHA256": images["versiond"]["archive_sha256"],
            "VERSIOND_ROUTER_IMAGE": deployment_image("versiond-router"),
            "VERSIOND_ROUTER_IMAGE_OCI": image("versiond-router"),
            "VERSIOND_ROUTER_IMAGE_ARCHIVE_URL": images["versiond-router"]["archive_url"],
            "VERSIOND_ROUTER_IMAGE_ARCHIVE_SHA256": images["versiond-router"]["archive_sha256"],
            "PROXY_IMAGE": reused.get("proxy", "nginx:1.28.0@sha256:552e7481ca93ffccd046aa658dbbed22caefbc09c66fa7cd247cbb90b8a5c609"),
            "MLNODE_GENERIC_IMAGE": reused.get("mlnode", "ghcr.io/paranjko/gdc-mlnode:3.0.14-post2@sha256:4d602db5cbba5cbceaa16279f64bfcb2ad76a91ee30ebddbfdc00c3b0dfb9c01"),
            "MLNODE_PROXY_IMAGE": "nginx:1.28.0@sha256:552e7481ca93ffccd046aa658dbbed22caefbc09c66fa7cd247cbb90b8a5c609",
            "BRIDGE_IMAGE": reused.get("bridge", "ghcr.io/paranjko/gdc-bridge:0.2.15@sha256:88df0a7b4ca2f654aa0989f64bfcb2ad76a91ee30ebddbfdc00c3b0dfb9c02"),
            "GONKA_UPGRADE_METADATA_URL": (
                "https://github.com/paranjko/external-test-lab/releases/tag/"
                f"{publication_contract(definition, profile)['release_url_segment']}"
            ),
        })
        required_devshard = definition.get("devshard_baseline")
        if isinstance(required_devshard, dict) and required_devshard.get("profile"):
            values.update({
                "REQUIRED_DEVSHARD_PROFILE": required_devshard["profile"],
                "REQUIRED_DEVSHARD_DEFINITION_SHA256": required_devshard["definition_sha256"],
                "REQUIRED_DEVSHARD_BUILD_MANIFEST_SHA256": required_devshard["build_manifest_sha256"],
                "REQUIRED_DEVSHARD_RELEASE_LOCK_SHA256": required_devshard["release_lock_sha256"],
            })

    if layer in {"devshard", "all"}:
        repo_devshard = definition["repositories"].get("devshard_v5") or definition["repositories"].get("devshard", {})
        values.update({
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
            "CANDIDATE_DEVSHARD_SOURCE_REF": repo_devshard.get("ref", "refs/heads/main"),
            "CANDIDATE_DEVSHARD_COMMIT": repo_devshard.get("commit", ""),
            "CANDIDATE_DEVSHARD_PROTOCOL_VERSION": "v5",
            "CANDIDATE_DEVSHARD_SUPPORTED_PROTOCOLS": "v3 v5",
            "CANDIDATE_LOCAL_GATEWAY_IMAGE": local_archive_image("devshard-gateway"),
            **(
                {
                    "CANDIDATE_POSTGRES_IMAGE": (
                        "postgres:16-alpine@sha256:"
                        "cf78e76683b9ca8c5733cbbdce6c9262b45b6767934dd0a95e671f9a0fc20685"
                    )
                }
                if definition.get("publication") is None
                else {}
            ),
            "DEVSHARD_HEIGHTSYNC": "true",
            "DEVSHARD_HEIGHTSYNC_K": "10",
            "DEVSHARD_HEIGHTSYNC_SLOTS": "1",
            "GONKA_HA": str(ha.get("enabled", False)).lower(),
            "DEVSHARD_STORAGE_MODE": ha.get("storage_mode", "memory"),
        })

    values.update({
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
    })

    lines = [
        f"# Immutable External Test Lab candidate {profile}.",
        "# This is not an official Gonka release or readiness statement.",
    ]
    lines.extend(f"{key}={shell_quote(str(value))}" for key, value in values.items())
    return "\n".join(lines) + "\n"


def command_profile(args: argparse.Namespace) -> None:
    manifest_path = resolve_build_manifest(args.profile, args.build_manifest, prefer_retained=False)
    manifest, manifest_hash, manifest_content = verify_build_manifest_snapshot(
        args.profile,
        manifest_path,
    )
    lock = RELEASES / f"{args.profile}.lock"
    atomic_write(lock, render_lock(args.profile, manifest, manifest_hash))
    retained = preserve_build_manifest(args.profile, manifest_content, manifest_hash)
    print(
        f"READY profile={args.profile} release_lock={lock} "
        f"build_manifest={retained} build_manifest_sha256={manifest_hash}"
    )


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
    manifest_path = resolve_build_manifest(args.profile, args.build_manifest, prefer_retained=True)
    manifest, manifest_hash, _ = verify_build_manifest_snapshot(
        args.profile,
        manifest_path,
    )
    if manifest_path == retained_build_manifest(args.profile):
        verify_retained_manifest_sidecar(manifest_path, manifest_hash)
    if lock.get("CANDIDATE_BUILD_MANIFEST_SHA256") != manifest_hash:
        raise CandidateError("candidate release lock is not bound to its build manifest")
    expected = render_lock(args.profile, manifest, manifest_hash)
    if lock_path.read_text(encoding="utf-8") != expected:
        raise CandidateError("candidate release lock does not match the verified build manifest")
    print(f"PASS profile={args.profile} definition_sha256={definition_hash} build_manifest_sha256={manifest_hash}")


def composition_path(name: str) -> Path:
    clean_name = name.removesuffix(".json")
    if not re.fullmatch(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$", clean_name):
        raise CandidateError(f"invalid composition name: {name}")
    return COMPOSITIONS / f"{clean_name}.json"


def load_deployment_lock(deployment: str = "community-lab") -> tuple[dict[str, str], str]:
    path = DEPLOYMENTS / f"{deployment}.lock"
    if not path.is_file():
        raise CandidateError(f"deployment profile lock is missing: {path}")
    lock = parse_lock(path)
    return lock, sha256(path)


def load_profile_lock(profile: str) -> tuple[dict[str, str], str]:
    path = RELEASES / f"{profile}.lock"
    if not path.is_file():
        raise CandidateError(f"release profile lock is missing: {path}")
    lock = parse_lock(path)
    return lock, sha256(path)


def build_canonical_composition(
    core_profile: str,
    devshard_profile: str,
    comp_name: str,
) -> dict[str, Any]:
    core_lock, core_lock_hash = load_profile_lock(core_profile)
    devshard_lock, devshard_lock_hash = load_profile_lock(devshard_profile)

    core_classification = "lab-candidate" if core_lock.get("LAB_CANDIDATE") == "true" else "stable"
    core_info: dict[str, Any] = {
        "profile": core_profile,
        "classification": core_classification,
        "release_version": core_lock.get("GONKA_RELEASE", "0.2.15"),
        "source_commit": core_lock.get("GONKA_COMMIT", "4d687ed6782bcea3931d2d9135bf322f84e190ab"),
        "source_ref": core_lock.get("GONKA_SOURCE_REF", "refs/heads/main"),
        "lock_hash": core_lock_hash,
        "upgrade_from_profile": core_lock.get("UPGRADE_FROM_PROFILE", CANONICAL_BASELINE_PROFILE),
    }
    if "CANDIDATE_DEFINITION_SHA256" in core_lock:
        core_info["definition_sha256"] = core_lock["CANDIDATE_DEFINITION_SHA256"]
    if "CANDIDATE_BUILD_MANIFEST_SHA256" in core_lock:
        core_info["build_manifest_sha256"] = core_lock["CANDIDATE_BUILD_MANIFEST_SHA256"]

    core_images = {
        "inferenced": core_lock.get("INFERENCED_IMAGE", ""),
        "decentralized-api": core_lock.get("DAPI_IMAGE", ""),
        "edge-api": core_lock.get("EDGE_API_IMAGE", ""),
        "versiond": core_lock.get("VERSIOND_IMAGE", ""),
        "versiond-router": core_lock.get("VERSIOND_ROUTER_IMAGE", ""),
        "proxy": core_lock.get("PROXY_IMAGE", ""),
        "mlnode": core_lock.get("MLNODE_GENERIC_IMAGE", ""),
        "tmkms": core_lock.get("TMKMS_IMAGE", ""),
        "bridge": core_lock.get("BRIDGE_IMAGE", ""),
    }
    core_binaries = {
        "inferenced-linux-amd64": {
            "url": core_lock.get("INFERENCED_UPGRADE_URL", ""),
            "sha256": core_lock.get("INFERENCED_UPGRADE_SHA256", ""),
        },
        "inferenced-operator-linux-amd64": {
            "url": core_lock.get("INFERENCED_OPERATOR_URL_LINUX_AMD64", ""),
            "sha256": core_lock.get("INFERENCED_OPERATOR_SHA256_LINUX_AMD64", ""),
        },
        "decentralized-api-linux-amd64": {
            "url": core_lock.get("DAPI_UPGRADE_URL", ""),
            "sha256": core_lock.get("DAPI_UPGRADE_SHA256", ""),
        },
        "edge-api-linux-amd64": {
            "url": core_lock.get("EDGE_API_UPGRADE_URL", ""),
            "sha256": core_lock.get("EDGE_API_UPGRADE_SHA256", ""),
        },
    }
    core_info["images"] = {k: v for k, v in core_images.items() if v}
    core_info["binaries"] = {k: v for k, v in core_binaries.items() if v.get("url") and v.get("sha256")}

    core_baseline = core_lock.get("UPGRADE_FROM_PROFILE", core_profile)
    devshard_baseline = devshard_lock.get("UPGRADE_FROM_PROFILE", devshard_profile)
    is_cand_core = core_lock.get("LAB_CANDIDATE") == "true"
    is_candidate_devshard = devshard_lock.get("LAB_CANDIDATE") == "true" and (
        "CANDIDATE_DEVSHARD_COMMIT" in devshard_lock or "DEVSHARDD_IMAGE" in devshard_lock
    )

    required_devshard_profile = core_lock.get("REQUIRED_DEVSHARD_PROFILE")
    if required_devshard_profile:
        if devshard_profile != required_devshard_profile:
            raise CandidateError(
                f"core candidate {core_profile} requires DevShard profile {required_devshard_profile}, got {devshard_profile}"
            )
        required_definition = core_lock.get("REQUIRED_DEVSHARD_DEFINITION_SHA256", "")
        required_manifest = core_lock.get("REQUIRED_DEVSHARD_BUILD_MANIFEST_SHA256", "")
        required_release_lock = core_lock.get("REQUIRED_DEVSHARD_RELEASE_LOCK_SHA256", "")
        if (
            devshard_lock.get("CANDIDATE_DEFINITION_SHA256") != required_definition
            or devshard_lock.get("CANDIDATE_BUILD_MANIFEST_SHA256") != required_manifest
            or devshard_lock_hash != required_release_lock
        ):
            raise CandidateError(
                f"DevShard profile {devshard_profile} release lock does not match the exact identity required by core candidate {core_profile}"
            )

    if is_cand_core:
        if is_candidate_devshard:
            if core_baseline != devshard_baseline:
                raise CandidateError(
                    f"core candidate ({core_profile}, baseline {core_baseline}) and devshard candidate ({devshard_profile}, baseline {devshard_baseline}) have incompatible lineage"
                )
        else:
            if core_baseline != devshard_profile:
                raise CandidateError(
                    f"core candidate ({core_profile}, baseline {core_baseline}) cannot compose with devshard profile {devshard_profile}"
                )
    else:
        if is_candidate_devshard:
            if devshard_baseline != core_profile:
                raise CandidateError(
                    f"devshard candidate ({devshard_profile}, baseline {devshard_baseline}) cannot compose with core profile {core_profile}"
                )
        else:
            if core_profile != devshard_profile and core_baseline != devshard_baseline:
                raise CandidateError(
                    f"stable core ({core_profile}) and stable devshard ({devshard_profile}) baselines disagree"
                )

    if is_candidate_devshard:
        devshard_protocol = devshard_lock.get("CANDIDATE_DEVSHARD_PROTOCOL_VERSION", "v5")
        devshard_source_ref = devshard_lock.get("CANDIDATE_DEVSHARD_SOURCE_REF", "refs/heads/main")
        devshard_source_commit = devshard_lock.get("CANDIDATE_DEVSHARD_COMMIT", "")
        devshard_classification = "lab-candidate"
        devshard_images = {
            "devshardd": devshard_lock.get("DEVSHARDD_IMAGE", ""),
            "devshard-gateway": devshard_lock.get("DEVSHARD_GATEWAY_IMAGE", ""),
            "devshard-host": devshard_lock.get("DEVSHARD_HOST_IMAGE", ""),
        }
        if devshard_lock.get("CANDIDATE_POSTGRES_IMAGE"):
            devshard_images["postgres"] = devshard_lock["CANDIDATE_POSTGRES_IMAGE"]
        devshard_binaries = {
            "devshardd-linux-amd64": {
                "url": devshard_lock.get("DEVSHARD_V5_URL", ""),
                "sha256": devshard_lock.get("DEVSHARD_V5_SHA256", ""),
            },
        }
        devshard_features = {
            "heightsync": devshard_lock.get("DEVSHARD_HEIGHTSYNC", "true") == "true",
            "heightsync_k": int(devshard_lock.get("DEVSHARD_HEIGHTSYNC_K", "10")),
            "heightsync_slots": int(devshard_lock.get("DEVSHARD_HEIGHTSYNC_SLOTS", "1")),
            "storage_mode": devshard_lock.get("DEVSHARD_STORAGE_MODE", "memory"),
        }
        devshard_info = {
            "profile": devshard_profile,
            "classification": devshard_classification,
            "protocol_version": devshard_protocol,
            "source_commit": devshard_source_commit,
            "source_ref": devshard_source_ref,
            "lock_hash": devshard_lock_hash,
            "upgrade_from_profile": devshard_baseline,
            "features": devshard_features,
            "images": {k: v for k, v in devshard_images.items() if v},
            "binaries": {k: v for k, v in devshard_binaries.items() if v.get("url") and v.get("sha256")},
        }
        gw_arch_url = devshard_lock.get("CANDIDATE_LOCAL_GATEWAY_ARCHIVE_URL") or devshard_lock.get("DEVSHARD_GATEWAY_IMAGE_ARCHIVE_URL", "")
        gw_arch_sha = devshard_lock.get("CANDIDATE_LOCAL_GATEWAY_ARCHIVE_SHA256") or devshard_lock.get("DEVSHARD_GATEWAY_IMAGE_ARCHIVE_SHA256", "")
        if gw_arch_url and gw_arch_sha:
            devshard_info["gateway_archive_url"] = gw_arch_url
            devshard_info["gateway_archive_sha256"] = gw_arch_sha
        if "CANDIDATE_DEFINITION_SHA256" in devshard_lock:
            devshard_info["definition_sha256"] = devshard_lock["CANDIDATE_DEFINITION_SHA256"]
        if "CANDIDATE_BUILD_MANIFEST_SHA256" in devshard_lock:
            devshard_info["build_manifest_sha256"] = devshard_lock["CANDIDATE_BUILD_MANIFEST_SHA256"]
    else:
        # Stable deployed DevShard inputs from community-lab.lock and release lock
        dept_lock, dept_lock_hash = load_deployment_lock("community-lab")
        devshard_protocol = dept_lock.get("DEVSHARD_PROTOCOL_VERSION", "v3")
        devshard_source_ref = dept_lock.get("DEVSHARD_V4_SOURCE_REF", "release/v0.2.15-devshard-v4.0.1")
        devshard_source_commit = "3c034a72a80f82c33f71a73737c329f41c7ddf7b"
        devshard_classification = "stable"
        devshard_images = {
            "devshard-gateway": dept_lock.get("LOCAL_GATEWAY_IMAGE", "gdc/devshard-gateway:0.2.15-v3"),
            "postgres": dept_lock.get("POSTGRES_IMAGE", "postgres:16.9-bookworm@sha256:253815cf7579ffa05e1673d92e78d37273e61be0e4414e9a1449337d7925be94"),
        }
        devshard_binaries = {
            "devshardd-linux-amd64": {
                "url": dept_lock.get("DEVSHARD_V4_URL") or dept_lock.get("DEVSHARD_V3_URL", ""),
                "sha256": dept_lock.get("DEVSHARD_V4_SHA256") or dept_lock.get("DEVSHARD_V3_SHA256", ""),
            },
        }
        devshard_features = {
            "heightsync": False,
            "heightsync_k": 0,
            "heightsync_slots": 0,
            "storage_mode": "memory",
        }
        devshard_info = {
            "profile": devshard_profile,
            "classification": devshard_classification,
            "protocol_version": devshard_protocol,
            "source_commit": devshard_source_commit,
            "source_ref": devshard_source_ref,
            "lock_hash": devshard_lock_hash,
            "upgrade_from_profile": devshard_baseline,
            "deployment_profile": "community-lab",
            "deployment_lock_hash": dept_lock_hash,
            "host_stack_commit": devshard_lock.get("GONKA_HOST_STACK_COMMIT", "ce33c851282b8f4c0f63d78d46ddd4d8bb248207"),
            "features": devshard_features,
            "images": {k: v for k, v in devshard_images.items() if v},
            "binaries": {k: v for k, v in devshard_binaries.items() if v.get("url") and v.get("sha256")},
        }

    # Reject missing artifact bindings
    if not devshard_info["images"].get("devshard-gateway"):
        raise CandidateError("devshard profile is missing devshard-gateway image binding")
    if not devshard_info["binaries"].get("devshardd-linux-amd64"):
        raise CandidateError("devshard profile is missing devshardd binary artifact binding")

    # Component role names are intentionally layer-qualified by the schema:
    # core roles and DevShard roles occupy disjoint namespaces. The merged
    # dictionaries therefore preserve both layers without collision; artifact
    # bindings are validated independently above and below.

    components = {
        "images": {**core_info["images"], **devshard_info["images"]},
        "binaries": {**core_info["binaries"], **devshard_info["binaries"]},
    }

    manifest = {
        "schema_version": 1,
        "kind": "external-test-lab-composition-manifest",
        "composition": comp_name,
        "network": {
            "chain_id": CANONICAL_CHAIN_ID,
            "genesis_sha256": CANONICAL_GENESIS_SHA256,
            "baseline_profile": CANONICAL_BASELINE_PROFILE,
        },
        "core": core_info,
        "devshard": devshard_info,
        "components": components,
    }
    return manifest


COMPOSITION_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")


def sha256_content(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def create_composition(
    core_profile: str,
    devshard_profile: str,
    name: str | None = None,
    output_path: Path | None = None,
    materialize_path: Path | None = None,
) -> tuple[dict[str, Any], Path, str]:
    comp_name = name or f"core-{core_profile}+devshard-{devshard_profile}"
    if not COMPOSITION_NAME_RE.fullmatch(comp_name):
        raise CandidateError(f"composition identifier is malformed: {comp_name!r}")
    dest_path = output_path or composition_path(comp_name)

    manifest = build_canonical_composition(
        core_profile=core_profile,
        devshard_profile=devshard_profile,
        comp_name=comp_name,
    )

    content = json.dumps(manifest, indent=2) + "\n"
    atomic_write(dest_path, content)
    comp_hash = sha256(dest_path)
    sidecar = dest_path.with_suffix(".sha256")
    sidecar.write_text(f"{comp_hash}  {dest_path.name}\n", encoding="utf-8")

    if materialize_path:
        lock_content = materialize_composition_lock(manifest)
        atomic_write(materialize_path, lock_content)

    return manifest, dest_path, comp_hash


def verify_composition(manifest_path_or_name: str | Path) -> tuple[dict[str, Any], Path, str]:
    if isinstance(manifest_path_or_name, Path):
        path = manifest_path_or_name
    elif Path(manifest_path_or_name).is_file():
        path = Path(manifest_path_or_name)
    else:
        path = composition_path(manifest_path_or_name)

    if not path.is_file():
        raise CandidateError(f"composition manifest is missing: {path}")

    actual_hash = sha256(path)
    sidecar = path.with_suffix(".sha256")
    try:
        fields = sidecar.read_text(encoding="utf-8").strip().split()
    except OSError as exc:
        raise CandidateError(f"composition checksum is missing: {sidecar}") from exc
    if fields != [actual_hash, path.name]:
        raise CandidateError(f"composition checksum mismatch: {path}")

    manifest = load_json(path)
    if manifest.get("schema_version") != 1:
        raise CandidateError("composition schema_version must be 1")
    if manifest.get("kind") != "external-test-lab-composition-manifest":
        raise CandidateError("composition kind is invalid")
    comp_name = manifest.get("composition")
    if not comp_name or not isinstance(comp_name, str) or not COMPOSITION_NAME_RE.fullmatch(comp_name):
        raise CandidateError(f"composition identifier is malformed: {comp_name!r}")
    if path.name.endswith(".json") and path.stem != comp_name and (path.parent == COMPOSITIONS or not Path(manifest_path_or_name).is_file()):
        raise CandidateError(f"composition identifier {comp_name!r} does not match manifest filename {path.name!r}")

    network = manifest.get("network", {})
    if network.get("chain_id") != CANONICAL_CHAIN_ID:
        raise CandidateError(f"composition chain_id must be {CANONICAL_CHAIN_ID}")
    if network.get("genesis_sha256") != CANONICAL_GENESIS_SHA256:
        raise CandidateError(f"composition genesis_sha256 mismatch: {network.get('genesis_sha256')}")
    if network.get("baseline_profile") != CANONICAL_BASELINE_PROFILE:
        raise CandidateError(f"composition baseline_profile must be {CANONICAL_BASELINE_PROFILE}")

    core = manifest.get("core")
    if not isinstance(core, dict) or not core.get("profile"):
        raise CandidateError("composition core profile declaration is missing")
    core_lock, core_lock_hash = load_profile_lock(core["profile"])
    if core.get("lock_hash") != core_lock_hash:
        raise CandidateError(f"composition core lock_hash mismatch: {core['profile']}")

    devshard = manifest.get("devshard")
    if not isinstance(devshard, dict) or not devshard.get("profile"):
        raise CandidateError("composition devshard profile declaration is missing")
    devshard_lock, devshard_lock_hash = load_profile_lock(devshard["profile"])
    if devshard.get("lock_hash") != devshard_lock_hash:
        raise CandidateError(f"composition devshard lock_hash mismatch: {devshard['profile']}")

    # Reconstruct canonical composition from the locks and assert exact equality
    expected_manifest = build_canonical_composition(
        core_profile=core["profile"],
        devshard_profile=devshard["profile"],
        comp_name=comp_name,
    )
    if manifest != expected_manifest:
        raise CandidateError("composition manifest content does not match reconstructed canonical composition from locks")

    components = manifest.get("components", {})
    images = components.get("images", {})
    binaries = components.get("binaries", {})
    if not isinstance(images, dict) or not isinstance(binaries, dict):
        raise CandidateError("composition component matrix is invalid")
    if not {"inferenced", "decentralized-api"}.issubset(set(images)):
        raise CandidateError("composition images lack required core components")
    if not {"devshard-gateway"}.issubset(set(images)):
        raise CandidateError("composition images lack required devshard components")

    return manifest, path, actual_hash


def materialize_composition_lock(manifest: dict[str, Any]) -> str:
    core_info = manifest["core"]
    devshard_info = manifest["devshard"]
    components = manifest["components"]
    images = components["images"]
    binaries = components["binaries"]
    comp_name = manifest["composition"]
    gateway_image = images.get("devshard-gateway", "")
    local_gateway_image = gateway_image.split("@sha256:", 1)[0]

    values: dict[str, Any] = {
        "LAB_CANDIDATE": "true" if core_info.get("classification") == "lab-candidate" or devshard_info.get("classification") == "lab-candidate" else "false",
        "UPGRADE_FROM_PROFILE": core_info.get("upgrade_from_profile", CANONICAL_BASELINE_PROFILE),
        "CANDIDATE_COMPOSITION": comp_name,
        "GONKA_SOURCE_REF": core_info.get("source_ref", "refs/heads/main"),
        "GONKA_COMMIT": core_info.get("source_commit", "4d687ed6782bcea3931d2d9135bf322f84e190ab"),
        "GONKA_REPOSITORY": "https://github.com/gonka-ai/gonka.git",
        "GONKA_RELEASE": str(core_info.get("release_version", "0.2.15")),
        "JOIN_BOOTSTRAP_FORMAT": "1",
        "TMKMS_IMAGE": images.get("tmkms", "ghcr.io/paranjko/gdc-tmkms:v0.15.2@sha256:d5cbba97e74cb2feaa16279f64bfcb2ad76a91ee30ebddbfdc00c3b0dfb9ce1d"),
        "INFERENCED_IMAGE": images.get("inferenced", ""),
        "DAPI_IMAGE": images.get("decentralized-api", ""),
        "EDGE_API_IMAGE": images.get("edge-api", ""),
        "EDGE_API_ENABLED": "true",
        "EDGE_API_COMPOSE_PROFILE": "edge-api",
        "EDGE_API_SERVICE_NAME": "edge-api",
        "VERSIOND_IMAGE": images.get("versiond", ""),
        "VERSIOND_ROUTER_IMAGE": images.get("versiond-router", ""),
        "PROXY_IMAGE": images.get("proxy", "nginx:1.28.0@sha256:552e7481ca93ffccd046aa658dbbed22caefbc09c66fa7cd247cbb90b8a5c609"),
        "MLNODE_GENERIC_IMAGE": images.get("mlnode", "ghcr.io/gonka-ai/mlnode:3.0.14-post2@sha256:41d765d1bf2b0f2e1c2aa7b131ff5a5da7a6eaebfe8c3276f67478924e466cd5"),
        "MLNODE_PROXY_IMAGE": "nginx:1.28.0@sha256:552e7481ca93ffccd046aa658dbbed22caefbc09c66fa7cd247cbb90b8a5c609",
        "BRIDGE_IMAGE": images.get("bridge", "ghcr.io/product-science/bridge:0.2.15@sha256:ac01165eb8eb60dbafe5d1e060a11b474efb44146b12f308bef6153b55a2c22d"),
    }
    if "inferenced-linux-amd64" in binaries:
        values["INFERENCED_UPGRADE_URL"] = binaries["inferenced-linux-amd64"].get("url", "")
        values["INFERENCED_UPGRADE_SHA256"] = binaries["inferenced-linux-amd64"].get("sha256", "")
    if "inferenced-operator-linux-amd64" in binaries:
        values["INFERENCED_OPERATOR_URL_LINUX_AMD64"] = binaries["inferenced-operator-linux-amd64"].get("url", "")
        values["INFERENCED_OPERATOR_SHA256_LINUX_AMD64"] = binaries["inferenced-operator-linux-amd64"].get("sha256", "")
    if "decentralized-api-linux-amd64" in binaries:
        values["DAPI_UPGRADE_URL"] = binaries["decentralized-api-linux-amd64"].get("url", "")
        values["DAPI_UPGRADE_SHA256"] = binaries["decentralized-api-linux-amd64"].get("sha256", "")
    if "edge-api-linux-amd64" in binaries:
        values["EDGE_API_UPGRADE_URL"] = binaries["edge-api-linux-amd64"].get("url", "")
        values["EDGE_API_UPGRADE_SHA256"] = binaries["edge-api-linux-amd64"].get("sha256", "")

    devshard_proto = devshard_info.get("protocol_version", "v3")
    values["DEVSHARD_PROTOCOL_VERSION"] = devshard_proto
    values["DEVSHARD_SUPPORTED_PROTOCOLS"] = "v3 v5" if devshard_proto == "v5" else "v3"
    values["DEVSHARD_SOURCE_REF"] = devshard_info.get("source_ref", "refs/heads/main")
    values["DEVSHARD_COMMIT"] = devshard_info.get("source_commit", "")
    if "host_stack_commit" in devshard_info:
        values["GONKA_HOST_STACK_COMMIT"] = devshard_info["host_stack_commit"]
    if "devshard-gateway" in images:
        values["LOCAL_GATEWAY_IMAGE"] = local_gateway_image
        values["DEVSHARD_GATEWAY_IMAGE"] = gateway_image
    if "gateway_archive_url" in devshard_info:
        values["DEVSHARD_GATEWAY_IMAGE_ARCHIVE_URL"] = devshard_info["gateway_archive_url"]
        values["DEVSHARD_GATEWAY_IMAGE_ARCHIVE_SHA256"] = devshard_info["gateway_archive_sha256"]
        values["CANDIDATE_LOCAL_GATEWAY_ARCHIVE_URL"] = devshard_info["gateway_archive_url"]
        values["CANDIDATE_LOCAL_GATEWAY_ARCHIVE_SHA256"] = devshard_info["gateway_archive_sha256"]
    if "devshard-host" in images:
        values["DEVSHARD_HOST_IMAGE"] = images["devshard-host"]
    if "postgres" in images:
        values["POSTGRES_IMAGE"] = images["postgres"]
        if devshard_info.get("classification") == "lab-candidate":
            values["CANDIDATE_POSTGRES_IMAGE"] = images["postgres"]
    if "devshardd" in images:
        values["DEVSHARDD_IMAGE"] = images["devshardd"]
    if "devshardd-linux-amd64" in binaries:
        if devshard_proto == "v5":
            values["DEVSHARD_V5_URL"] = binaries["devshardd-linux-amd64"].get("url", "")
            values["DEVSHARD_V5_SHA256"] = binaries["devshardd-linux-amd64"].get("sha256", "")
        else:
            values["DEVSHARD_V4_URL"] = binaries["devshardd-linux-amd64"].get("url", "")
            values["DEVSHARD_V4_SHA256"] = binaries["devshardd-linux-amd64"].get("sha256", "")
    features = devshard_info.get("features", {})
    values["DEVSHARD_HEIGHTSYNC"] = "true" if features.get("heightsync", False) else "false"
    values["DEVSHARD_HEIGHTSYNC_K"] = str(features.get("heightsync_k", 10))
    values["DEVSHARD_HEIGHTSYNC_SLOTS"] = str(features.get("heightsync_slots", 1))
    values["DEVSHARD_STORAGE_MODE"] = features.get("storage_mode", "memory")

    values.update({
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
    })

    lines = [
        f"# Materialized composite profile for {comp_name}.",
        "# This lock combines verified core and devshard profiles into a single deployable environment.",
    ]
    lines.extend(f"{key}={shell_quote(str(value))}" for key, value in values.items() if value != "")
    return "\n".join(lines) + "\n"


def composition_env(manifest: dict[str, Any]) -> str:
    core_info = manifest["core"]
    devshard_info = manifest["devshard"]
    components = manifest["components"]
    images = components["images"]
    binaries = components["binaries"]
    comp_name = manifest["composition"]
    gateway_image = images.get("devshard-gateway", "")
    local_gateway_image = gateway_image.split("@sha256:", 1)[0]
    core_profile = core_info["profile"]
    manifest_hash = sha256_content(json.dumps(manifest, indent=2) + "\n")

    env: dict[str, str] = {
        "GDC_COMPOSITION": comp_name,
        "GDC_COMPOSITION_HASH": manifest_hash,
        "GDC_COMPOSITION_DEVSHARD_PROFILE": devshard_info["profile"],
        "GDC_COMPOSITION_DEVSHARD_DEFINITION_SHA256": devshard_info.get("definition_sha256", ""),
        "GDC_COMPOSITION_DEVSHARD_BUILD_MANIFEST_SHA256": devshard_info.get("build_manifest_sha256", ""),
        "GDC_COMPOSITION_DEVSHARD_RELEASE_LOCK_SHA256": devshard_info["lock_hash"],
        "GDC_RELEASE_PROFILE": core_profile,
        "GONKA_REPOSITORY": "https://github.com/gonka-ai/gonka.git",
        "GONKA_SOURCE_REF": core_info.get("source_ref", "refs/heads/main"),
        "GONKA_COMMIT": core_info.get("source_commit", "4d687ed6782bcea3931d2d9135bf322f84e190ab"),
        "GONKA_RELEASE": str(core_info.get("release_version", "0.2.15")),
        "JOIN_BOOTSTRAP_FORMAT": "1",
        "TMKMS_IMAGE": images.get("tmkms", ""),
        "INFERENCED_IMAGE": images.get("inferenced", ""),
        "DAPI_IMAGE": images.get("decentralized-api", ""),
        "EDGE_API_IMAGE": images.get("edge-api", ""),
        "EDGE_API_ENABLED": "true",
        "EDGE_API_COMPOSE_PROFILE": "edge-api",
        "EDGE_API_SERVICE_NAME": "edge-api",
        "VERSIOND_IMAGE": images.get("versiond", ""),
        "VERSIOND_ROUTER_IMAGE": images.get("versiond-router", ""),
        "PROXY_IMAGE": images.get("proxy", "nginx:1.28.0@sha256:552e7481ca93ffccd046aa658dbbed22caefbc09c66fa7cd247cbb90b8a5c609"),
        "MLNODE_GENERIC_IMAGE": images.get("mlnode", ""),
        "MLNODE_BLACKWELL_IMAGE": images.get("mlnode", ""),
        "MLNODE_PROXY_IMAGE": "nginx:1.28.0@sha256:552e7481ca93ffccd046aa658dbbed22caefbc09c66fa7cd247cbb90b8a5c609",
        "BRIDGE_IMAGE": images.get("bridge", ""),
        "DEVSHARD_PROTOCOL_VERSION": devshard_info.get("protocol_version", "v3"),
        "DEVSHARD_SUPPORTED_PROTOCOLS": "v3 v5" if devshard_info.get("protocol_version") == "v5" else "v3",
        "DEVSHARD_SOURCE_REF": devshard_info.get("source_ref", "refs/heads/main"),
        "DEVSHARD_COMMIT": devshard_info.get("source_commit", ""),
        "LOCAL_GATEWAY_IMAGE": local_gateway_image,
        "DEVSHARD_GATEWAY_IMAGE": gateway_image,
        "DEVSHARD_HOST_IMAGE": images.get("devshard-host", ""),
    }
    if "postgres" in images:
        env["POSTGRES_IMAGE"] = images["postgres"]
    if "gateway_archive_url" in devshard_info:
        env["DEVSHARD_GATEWAY_IMAGE_ARCHIVE_URL"] = devshard_info["gateway_archive_url"]
        env["DEVSHARD_GATEWAY_IMAGE_ARCHIVE_SHA256"] = devshard_info["gateway_archive_sha256"]
        env["CANDIDATE_LOCAL_GATEWAY_ARCHIVE_URL"] = devshard_info["gateway_archive_url"]
        env["CANDIDATE_LOCAL_GATEWAY_ARCHIVE_SHA256"] = devshard_info["gateway_archive_sha256"]
    if devshard_info.get("classification") == "lab-candidate" or core_info.get("classification") == "lab-candidate":
        env["LAB_CANDIDATE"] = "true"
        env["CANDIDATE_DEVSHARD_SOURCE_REF"] = devshard_info.get("source_ref", "")
        env["CANDIDATE_DEVSHARD_COMMIT"] = devshard_info.get("source_commit", "")
        env["CANDIDATE_DEVSHARD_PROTOCOL_VERSION"] = devshard_info.get("protocol_version", "v5")
        env["CANDIDATE_DEVSHARD_SUPPORTED_PROTOCOLS"] = "v3 v5" if devshard_info.get("protocol_version") == "v5" else "v3"
        env["CANDIDATE_LOCAL_GATEWAY_IMAGE"] = local_gateway_image
        if "postgres" in images:
            env["CANDIDATE_POSTGRES_IMAGE"] = images["postgres"]

    if "devshardd" in images:
        env["DEVSHARDD_IMAGE"] = images["devshardd"]
    if "devshardd-linux-amd64" in binaries:
        if devshard_info.get("protocol_version") == "v5":
            env["DEVSHARD_V5_URL"] = binaries["devshardd-linux-amd64"].get("url", "")
            env["DEVSHARD_V5_SHA256"] = binaries["devshardd-linux-amd64"].get("sha256", "")
        else:
            env["DEVSHARD_V4_URL"] = binaries["devshardd-linux-amd64"].get("url", "")
            env["DEVSHARD_V4_SHA256"] = binaries["devshardd-linux-amd64"].get("sha256", "")
    features = devshard_info.get("features", {})
    env["DEVSHARD_HEIGHTSYNC"] = "true" if features.get("heightsync", False) else "false"
    env["DEVSHARD_HEIGHTSYNC_K"] = str(features.get("heightsync_k", 10))
    env["DEVSHARD_HEIGHTSYNC_SLOTS"] = str(features.get("heightsync_slots", 1))
    env["DEVSHARD_STORAGE_MODE"] = features.get("storage_mode", "memory")
    if "host_stack_commit" in devshard_info:
        env["GONKA_HOST_STACK_COMMIT"] = devshard_info["host_stack_commit"]

    lines = [f"export {key}={shell_quote(val)}" for key, val in env.items() if val != ""]
    return "\n".join(lines) + "\n"


def workflow_matrix(profile: str) -> dict[str, Any]:
    definition, _, _ = verify_definition(profile)
    layer = definition.get("layer", "all")
    repositories = definition.get("repositories", {})
    core_repo = repositories.get("gonka_core", {})
    core_commit = str(core_repo.get("commit", ""))
    core_version = str(definition.get("governance", {}).get("core_upgrade_name", "")).lstrip("v")
    devshard_repo = repositories.get("devshard_v5") or repositories.get("devshard", {})
    v5_commit = str(devshard_repo.get("commit", ""))
    v5_short = v5_commit[:8] if v5_commit else ""
    profile_name = str(definition.get("profile", profile))

    if definition.get("source_identity_contract"):
        inferenced_build_args = render_build_arguments(
            component_build_arguments(definition, "inferenced")
        )
        dapi_build_args = render_build_arguments(
            component_build_arguments(definition, "decentralized-api")
        )
        edge_api_build_args = render_build_arguments(
            component_build_arguments(definition, "edge-api")
        )
    else:
        inferenced_build_args = (
            "GOOS=linux\n"
            "GOARCH=amd64\n"
            "BLST_PORTABLE=0\n"
            f"LDFLAGS=-X github.com/cosmos/cosmos-sdk/version.Name=inference-chain "
            f"-X github.com/cosmos/cosmos-sdk/version.AppName=inferenced "
            f"-X github.com/cosmos/cosmos-sdk/version.Version={core_version} "
            f"-X github.com/cosmos/cosmos-sdk/version.Commit={core_commit}"
        )

        dapi_build_args = (
            "GOOS=linux\n"
            "GOARCH=amd64\n"
            "BLST_PORTABLE=0\n"
            "DEVSHARD_VERSION=v5\n"
            f"LDFLAGS=-X github.com/cosmos/cosmos-sdk/version.Name=decentralized-api "
            f"-X github.com/cosmos/cosmos-sdk/version.AppName=decentralized-api "
            f"-X github.com/cosmos/cosmos-sdk/version.Version={core_version} "
            f"-X github.com/cosmos/cosmos-sdk/version.Commit={core_commit}\n"
            f"INFERENCED_LDFLAGS=-X github.com/cosmos/cosmos-sdk/version.Name=inference-chain "
            f"-X github.com/cosmos/cosmos-sdk/version.AppName=inferenced "
            f"-X github.com/cosmos/cosmos-sdk/version.Version={core_version} "
            f"-X github.com/cosmos/cosmos-sdk/version.Commit={core_commit}"
        )
        edge_api_build_args = "GOOS=linux\nGOARCH=amd64\nBLST_PORTABLE=0"

    devshardd_build_args = (
        "GOOS=linux\n"
        "GOARCH=amd64\n"
        "BLST_PORTABLE=0\n"
        "DEVSHARD_VERSION=v5\n"
        f"DEVSHARD_BINARY_VERSION={profile_name}-{v5_short}"
    )

    legacy_dapi_metadata = definition.get("source_identity_contract") is None

    all_images = [
        {
            "id": "inferenced",
            "source": "core",
            "dockerfile": "inference-chain/Dockerfile",
            "context": ".",
            "target": "final",
            "build_args": inferenced_build_args,
        },
        {
            "id": "decentralized-api",
            "source": "core",
            "dockerfile": "decentralized-api/Dockerfile",
            "context": ".",
            "target": "final",
            "build_args": dapi_build_args,
            "legacy_dapi_metadata": legacy_dapi_metadata,
        },
        {
            "id": "edge-api",
            "source": "core",
            "dockerfile": "edge-api/Dockerfile",
            "context": ".",
            "target": "runtime",
            "build_args": edge_api_build_args,
        },
        {
            "id": "devshardd",
            "source": "v5",
            "dockerfile": "devshard/Dockerfile",
            "context": ".",
            "target": "runtime",
            "build_args": devshardd_build_args,
        },
        {
            "id": "devshard-gateway",
            "source": "v5",
            "dockerfile": "devshard/Dockerfile",
            "context": ".",
            "target": "devshardctl-runtime",
            "build_args": "DEVSHARD_VERSION=v5",
        },
        {
            "id": "devshard-host",
            "source": "v5",
            "dockerfile": "devshard/Dockerfile.host",
            "context": ".",
            "target": "",
            "build_args": "DEVSHARD_VERSION=v5",
        },
        {
            "id": "versiond",
            "source": "core",
            "dockerfile": "versioned/Dockerfile",
            "context": "versioned",
            "target": "",
            "build_args": "",
        },
        {
            "id": "versiond-router",
            "source": "core",
            "dockerfile": "versiond-router/Dockerfile",
            "context": "versiond-router",
            "target": "",
            "build_args": "",
        },
    ]

    all_binaries = [
        {
            "id": "inferenced",
            "member": "inferenced",
            "source": "core",
            "dockerfile_checkout": "source",
            "dockerfile": "inference-chain/Dockerfile",
        },
        {
            "id": "inferenced-operator",
            "member": "inferenced",
            "source": "core",
            "dockerfile_checkout": "automation",
            "dockerfile": "net-deployment-runbook/candidate/Dockerfile.inferenced-operator",
        },
        {
            "id": "decentralized-api",
            "member": "decentralized-api",
            "source": "core",
            "dockerfile_checkout": "source",
            "dockerfile": "decentralized-api/Dockerfile",
            "legacy_dapi_metadata": legacy_dapi_metadata,
        },
        {
            "id": "edge-api",
            "member": "edge-api",
            "source": "core",
            "dockerfile_checkout": "source",
            "dockerfile": "edge-api/Dockerfile",
        },
        {
            "id": "devshardd",
            "member": "devshardd",
            "source": "v5",
            "dockerfile_checkout": "source",
            "dockerfile": "devshard/Dockerfile",
        },
    ]

    if layer == "core":
        images = [img for img in all_images if img["source"] == "core"]
        binaries = [b for b in all_binaries if b["source"] == "core"]
    elif layer == "devshard":
        images = [img for img in all_images if img["source"] == "v5"]
        binaries = [b for b in all_binaries if b["source"] == "v5"]
    else:
        images = all_images
        binaries = all_binaries

    publish_images = [{"id": img["id"]} for img in images]
    publication = publication_contract(definition, profile)
    publish_binaries = [
        {
            "id": b["id"],
            "member": b["member"],
            "release_name": publication["binary_assets"][f"{b['id']}-linux-amd64"],
        }
        for b in binaries
    ]

    return {
        "layer": layer,
        "release_tag": publication["release_tag"],
        "release_url_segment": publication["release_url_segment"],
        "image_matrix": {"include": images},
        "binary_matrix": {"include": binaries},
        "publish_image_matrix": {"include": publish_images},
        "publish_binary_matrix": {"include": publish_binaries},
    }


def command_composition_create(args: argparse.Namespace) -> None:
    manifest, path, comp_hash = create_composition(
        args.core,
        args.devshard,
        name=args.name,
        output_path=Path(args.output).resolve() if args.output else None,
        materialize_path=Path(args.materialize).resolve() if args.materialize else None,
    )
    print(f"READY composition={manifest['composition']} sha256={comp_hash} path={path}")


def command_composition_verify(args: argparse.Namespace) -> None:
    manifest, path, comp_hash = verify_composition(args.manifest)
    print(f"PASS composition={manifest['composition']} sha256={comp_hash} path={path}")


def command_composition_materialize(args: argparse.Namespace) -> None:
    manifest, _, _ = verify_composition(args.manifest)
    comp_name = manifest["composition"]
    out_path = Path(args.output).resolve() if args.output else RELEASES / f"{comp_name}.lock"
    content = materialize_composition_lock(manifest)
    atomic_write(out_path, content)
    print(f"READY composition={comp_name} lock={out_path}")


def command_composition_export_env(args: argparse.Namespace) -> None:
    manifest, _, _ = verify_composition(args.manifest)
    sys.stdout.write(composition_env(manifest))


def command_workflow_matrix(args: argparse.Namespace) -> None:
    result = workflow_matrix(args.profile)
    print(f"layer={result['layer']}")
    print(f"release_tag={result['release_tag']}")
    print(f"release_url_segment={result['release_url_segment']}")
    print(f"image_matrix={json.dumps(result['image_matrix'])}")
    print(f"binary_matrix={json.dumps(result['binary_matrix'])}")
    print(f"publish_image_matrix={json.dumps(result['publish_image_matrix'])}")
    print(f"publish_binary_matrix={json.dumps(result['publish_binary_matrix'])}")


def parser() -> argparse.ArgumentParser:
    command = argparse.ArgumentParser(description=__doc__)
    subcommands = command.add_subparsers(dest="command", required=True)

    prepare = subcommands.add_parser("prepare")
    prepare.add_argument("--source-ref", required=True)
    prepare.add_argument("--layer", choices=["core", "devshard", "all"], default="all")
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

    source_verify = subcommands.add_parser("source-verify")
    source_verify.add_argument("profile")
    source_verify.add_argument("--repository-key", required=True)
    source_verify.add_argument("--repository", required=True)
    source_verify.add_argument("--verification-json", required=True)
    source_verify.set_defaults(func=command_source_verify)

    comp = subcommands.add_parser("composition")
    comp_sub = comp.add_subparsers(dest="composition_command", required=True)

    comp_create = comp_sub.add_parser("create")
    comp_create.add_argument("--core", required=True, help="Core profile name")
    comp_create.add_argument("--devshard", required=True, help="DevShard profile name")
    comp_create.add_argument("--name", help="Custom composition name")
    comp_create.add_argument("--output", help="Custom output JSON path")
    comp_create.add_argument("--materialize", help="Materialize complete release lock to destination path")
    comp_create.set_defaults(func=command_composition_create)

    comp_verify = comp_sub.add_parser("verify")
    comp_verify.add_argument("manifest", help="Path to composition manifest or composition name")
    comp_verify.set_defaults(func=command_composition_verify)

    comp_mat = comp_sub.add_parser("materialize")
    comp_mat.add_argument("manifest", help="Path to composition manifest or composition name")
    comp_mat.add_argument("--output", help="Custom output lock path")
    comp_mat.set_defaults(func=command_composition_materialize)

    comp_env = comp_sub.add_parser("export-env")
    comp_env.add_argument("manifest", help="Path to composition manifest or composition name")
    comp_env.set_defaults(func=command_composition_export_env)

    matrix = subcommands.add_parser("workflow-matrix")
    matrix.add_argument("profile", help="Candidate profile name")
    matrix.set_defaults(func=command_workflow_matrix)

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
