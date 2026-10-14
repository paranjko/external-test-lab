#!/usr/bin/env python3
"""Build, verify, and publish the frozen DevShard v6 image artifact bundle."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import tempfile
from urllib.parse import urlsplit
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
DEFINITION = ROOT / "releases/devshard-v6-artifacts.json"
COVERAGE = ROOT / "releases/devshard-v6-coverage.json"
REPOSITORY = "paranjko/external-test-lab"
ZIP_ASSET = "devshardd.zip"
MANIFEST_ASSET = "artifacts.json"
CHECKSUMS_ASSET = "SHA256SUMS"
COVERAGE_ASSET = "coverage.json"
SHA_RE = re.compile(r"sha256:[0-9a-f]{64}")
HEX_RE = re.compile(r"[0-9a-f]{64}")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def run(*args: str, **kwargs) -> str:
    return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE, **kwargs).stdout.strip()


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def dependencies(command: str) -> None:
    commands = {"python3"}
    if command == "fetch":
        commands.add("git")
    elif command == "build":
        commands.update(("git", "tar", "docker"))
    elif command == "publish":
        commands.update(("gh", "skopeo"))
    elif command == "verify-reuse":
        commands.add("skopeo")
    elif command == "smoke":
        commands.update(("docker", "go"))
    missing = sorted(name for name in commands if shutil.which(name) is None)
    require(not missing, "missing DevShard artifact release dependencies: " + ", ".join(missing))


def load_definition(path: Path = DEFINITION) -> dict:
    value = json.loads(path.read_text(encoding="utf-8"))
    require(set(value) == {"schema_version", "classification", "source_repository", "source_commit",
                           "source_tree", "platform", "release_tag", "buildkit_image", "ghcr_namespace",
                           "devshard_zip", "groups", "components"},
            "unexpected artifact definition fields")
    require(value["schema_version"] == 1 and value["classification"] == "lab-candidate-artifacts",
            "unsupported artifact definition")
    require(value["source_repository"] == "gonka-ai/gonka" and value["platform"] == "linux/amd64",
            "unsupported source or platform")
    for field in ("source_commit", "source_tree"):
        require(bool(re.fullmatch(r"[0-9a-f]{40}", value[field])), f"invalid {field}")
    require(value["release_tag"] == f"lab-devshard-v6-artifacts-{value['source_commit'][:12]}",
            "artifact tag does not bind source commit")
    require(value["buildkit_image"] == "moby/buildkit@sha256:cec9f139f45e93c5c69c60f8b07cfad9f43f4ef6b6a6cd917527fea5ff2e3dea",
            "unreviewed BuildKit builder image")
    require(value["ghcr_namespace"] == "ghcr.io/paranjko/external-test-lab", "unreviewed GHCR namespace")
    zip_binding = value["devshard_zip"]
    require(zip_binding == {
        "url": "https://github.com/paranjko/external-test-lab/releases/download/lab-devshard-v6-f2c6b03a53bd/devshardd.zip",
        "sha256": "049692d3bfdf55d9d8f7feb24091362908c05c063043420cca089817de0101aa",
    }, "published ZIP binding changed")
    groups, components = value["groups"], value["components"]
    require(set(groups) == {"manual-matrix", "dapi-edge"}, "group set changed")
    require(groups["manual-matrix"] == ["devshard-gateway", "gateway-v4.2", "versiond", "versiond-router", "proxy-router", "proxy-policy"],
            "manual-matrix component contract changed")
    require(groups["dapi-edge"] == ["decentralized-api", "edge-api"], "DAPI/edge group contract changed")
    require(set(components) == set(groups["manual-matrix"] + groups["dapi-edge"]), "component inventory mismatch")
    for name, component in components.items():
        require(set(component) <= {"source", "dockerfile", "context", "target", "base_images", "build_args"},
                f"unexpected fields for {name}")
        if "source" in component:
            binding = component["source"]
            require(name == "gateway-v4.2" and binding == {
                "repository": "gonka-ai/gonka", "commit": "b88062c9529389a61d4ba15b8b5603716a50909e",
                "tree": "dd0ff53244f341f9d4cb03f7218a47c34accf3b8"},
                f"unreviewed independent source binding for {name}")
        require(not PurePosixPath(component["dockerfile"]).is_absolute() and
                ".." not in PurePosixPath(component["dockerfile"]).parts,
                f"unsafe Dockerfile path for {name}")
        require(component["context"] == "." or (not PurePosixPath(component["context"]).is_absolute() and
                ".." not in PurePosixPath(component["context"]).parts), f"unsafe context for {name}")
        require(component["base_images"] and all(SHA_RE.fullmatch(digest) for digest in component["base_images"].values()),
                f"unpinned base image for {name}")
    return value


def selected_components(value: dict, groups: list[str]) -> list[str]:
    require(groups and len(groups) == len(set(groups)), "select one or more unique groups")
    require(set(groups) <= set(value["groups"]), "unsupported artifact group")
    require(groups == [name for name in value["groups"] if name in groups], "artifact groups must use manifest order")
    return [component for group in groups for component in value["groups"][group]]


def source_identity(source: Path, value: dict, binding: dict | None = None) -> None:
    binding = binding or value
    require(run("git", "-C", str(source), "rev-parse", "HEAD") == binding["commit" if "commit" in binding else "source_commit"],
            "source HEAD mismatch")
    require(run("git", "-C", str(source), "rev-parse", "HEAD^{tree}") == binding["tree" if "tree" in binding else "source_tree"],
            "source tree mismatch")


def fetch_source(source: Path, value: dict) -> None:
    require(not source.exists(), "source destination already exists; never overwrite a checkout")
    source.mkdir(parents=True)
    run("git", "-C", str(source), "init", "--quiet")
    run("git", "-C", str(source), "-c", "credential.helper=", "fetch", "--no-tags", "--depth=1",
        "https://github.com/gonka-ai/gonka.git", value["source_commit"])
    run("git", "-C", str(source), "checkout", "--quiet", "--detach", "FETCH_HEAD")
    source_identity(source, value)


def fetch_bound_source(source: Path, binding: dict) -> None:
    require(not source.exists(), "bound source destination already exists; never overwrite")
    source.mkdir(parents=True)
    run("git", "-C", str(source), "init", "--quiet")
    run("git", "-C", str(source), "-c", "credential.helper=", "fetch", "--no-tags", "--depth=1",
        f"https://github.com/{binding['repository']}.git", binding["commit"])
    run("git", "-C", str(source), "checkout", "--quiet", "--detach", "FETCH_HEAD")
    source_identity(source, {}, binding)


def fetch_zip(destination: Path, value: dict) -> None:
    require(not destination.exists(), "ZIP destination already exists; never overwrite")
    destination.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(value["devshard_zip"]["url"], headers={"User-Agent": "external-test-lab-release"})
    with urllib.request.urlopen(request, timeout=60) as response, destination.open("xb") as output:
        shutil.copyfileobj(response, output)
    require(sha256(destination) == value["devshard_zip"]["sha256"], "published ZIP checksum mismatch")


def verify_oci_archive(path: Path, expected_name: str, value: dict) -> dict:
    require(path.is_file() and not path.is_symlink(), f"missing regular OCI archive: {expected_name}")
    with tarfile.open(path, "r:") as archive:
        entries = archive.getmembers()
        names = [item.name for item in entries]
        require(len(names) == len(set(names)), "duplicate OCI archive paths")
        for item in entries:
            member = PurePosixPath(item.name)
            require(not member.is_absolute() and ".." not in member.parts and (item.isfile() or item.isdir()),
                    f"unsafe OCI archive entry: {item.name}")
        by_name = {item.name: item for item in entries}
        require("index.json" in by_name and "oci-layout" in by_name, "not an OCI image archive")

        def read_json(name: str) -> dict:
            raw = archive.extractfile(by_name[name])
            require(raw is not None, f"missing OCI object {name}")
            return json.load(raw)

        index = read_json("index.json")
        require(index.get("schemaVersion") == 2 and len(index.get("manifests", [])) == 1,
                "OCI archive must contain exactly one image manifest")
        descriptor = index["manifests"][0]
        require(descriptor.get("mediaType") == "application/vnd.oci.image.manifest.v1+json",
                "unexpected OCI manifest type")
        manifest_path = f"blobs/sha256/{descriptor['digest'].removeprefix('sha256:')}"
        manifest_bytes = archive.extractfile(by_name[manifest_path]).read()
        require(hashlib.sha256(manifest_bytes).hexdigest() == descriptor["digest"].removeprefix("sha256:"),
                "OCI manifest digest mismatch")
        manifest = json.loads(manifest_bytes)
        config_digest = manifest["config"]["digest"]
        config_path = f"blobs/sha256/{config_digest.removeprefix('sha256:')}"
        config_bytes = archive.extractfile(by_name[config_path]).read()
        require(hashlib.sha256(config_bytes).hexdigest() == config_digest.removeprefix("sha256:"),
                "OCI config digest mismatch")
        config = json.loads(config_bytes)
        require(config.get("os") == "linux" and config.get("architecture") == "amd64",
                "OCI image platform mismatch")
        for blob in [manifest["config"], *manifest["layers"]]:
            blob_path = f"blobs/sha256/{blob['digest'].removeprefix('sha256:')}"
            require(blob_path in by_name and sha256_member(archive, by_name[blob_path]) == blob["digest"].removeprefix("sha256:"),
                    "OCI blob missing or digest mismatch")
        expected_files = {"oci-layout", "index.json", manifest_path, config_path}
        expected_files.update(f"blobs/sha256/{blob['digest'].removeprefix('sha256:')}" for blob in manifest["layers"])
        require({item.name for item in entries if item.isfile()} == expected_files,
                "OCI archive contains unbound or missing files")
        repository = f"{value['ghcr_namespace']}/{expected_name}"
        binding = value["components"][expected_name].get("source", value)
        return {"oci_manifest_digest": descriptor["digest"], "image_config_digest": config_digest,
                "platform": value["platform"], "archive_sha256": sha256(path),
                "source_commit": binding.get("commit", binding.get("source_commit")),
                "source_tree": binding.get("tree", binding.get("source_tree")),
                "ghcr_tag": f"{repository}:{value['release_tag']}",
                "ghcr_digest_reference": f"{repository}@{descriptor['digest']}"}


def sha256_member(archive: tarfile.TarFile, member: tarfile.TarInfo) -> str:
    digest = hashlib.sha256()
    stream = archive.extractfile(member)
    require(stream is not None, "unreadable OCI blob")
    while chunk := stream.read(1024 * 1024):
        digest.update(chunk)
    return digest.hexdigest()


def registry_identity(reference: str, authfile: Path, home: Path) -> dict | None:
    # Skopeo rejects tag+digest references; the digest remains authoritative.
    transport_reference = reference
    if "@" in reference:
        name, digest = reference.rsplit("@", 1)
        prefix, separator, image = name.rpartition("/")
        transport_reference = f"{prefix}{separator}{image.split(':', 1)[0]}@{digest}"
    environment = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(home)}
    result = subprocess.run(["skopeo", "inspect", "--raw", "--authfile", str(authfile),
                             f"docker://{transport_reference}"], text=True, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, env=environment)
    if result.returncode:
        diagnostic = result.stderr.lower()
        require("manifest unknown" in diagnostic or "status code: 404" in diagnostic,
                f"GHCR identity lookup failed (closed): {reference}")
        return None
    raw = result.stdout.encode()
    digest = "sha256:" + hashlib.sha256(raw).hexdigest()
    try:
        manifest = json.loads(raw)
        require(manifest.get("schemaVersion") == 2, "unexpected GHCR manifest schema")
        config = subprocess.run(["skopeo", "inspect", "--config", "--authfile", str(authfile),
                                 f"docker://{transport_reference}"], text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, env=environment, check=True)
        image_config = json.loads(config.stdout)
    except (json.JSONDecodeError, subprocess.CalledProcessError) as error:
        raise ValueError(f"GHCR config readback failed: {reference}") from error
    platform = f"{image_config.get('os')}/{image_config.get('architecture')}"
    return {"oci_manifest_digest": digest, "platform": platform}


def publish_registry(manifest: dict, component_paths: dict[str, Path], value: dict,
                     authfile: Path, home: Path, token: str, actor: str) -> None:
    require(token and "\n" not in token and re.fullmatch(r"[A-Za-z0-9-]+", actor or ""),
            "invalid trusted publisher registry credentials")
    environment = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(home)}
    login = subprocess.run(["skopeo", "login", "--authfile", str(authfile), "--username", actor,
                            "--password-stdin", "ghcr.io"], input=token + "\n", text=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
    require(login.returncode == 0, "GHCR login failed")

    tag_states = {name: registry_identity(manifest["artifacts"][name]["ghcr_tag"], authfile, home)
                  for name in component_paths}
    for name, identity in tag_states.items():
        expected = manifest["artifacts"][name]
        require(identity is None or (identity["oci_manifest_digest"] == expected["oci_manifest_digest"] and
                identity["platform"] == value["platform"]),
                f"GHCR tag collision with different bytes or platform: {expected['ghcr_tag']}")
    # Preflight the complete set before any push. Existing identical tags are idempotent skips.
    for name, path in component_paths.items():
        if tag_states[name] is None:
            reference = manifest["artifacts"][name]["ghcr_tag"]
            copy = subprocess.run(["skopeo", "copy", "--all", "--preserve-digests", "--dest-authfile",
                                   str(authfile), f"oci-archive:{path}", f"docker://{reference}"],
                                  text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
            require(copy.returncode == 0, f"GHCR copy failed for {name}")
        observed = registry_identity(manifest["artifacts"][name]["ghcr_tag"], authfile, home)
        expected = manifest["artifacts"][name]
        require(observed is not None and observed["oci_manifest_digest"] == expected["oci_manifest_digest"] and
                observed["platform"] == value["platform"], f"GHCR authenticated readback mismatch: {name}")
    # Verify the digest-pinned pull references anonymously; authenticated access is not public availability.
    anonymous_auth = authfile.parent / "anonymous-auth.json"
    anonymous_auth.write_text("{}\n")
    for name in component_paths:
        reference = manifest["artifacts"][name]["ghcr_digest_reference"]
        try:
            public = registry_identity(reference, anonymous_auth, home)
        except ValueError as error:
            raise ValueError(
                f"GHCR anonymous readback failed for {reference}; package visibility may still be private. "
                "Set this repository-linked package public through the owner-controlled package settings, "
                "then rerun the failed publish job using the same retained bundle; do not rebuild or change tags."
            ) from error
        expected = manifest["artifacts"][name]
        require(public is not None and public["oci_manifest_digest"] == expected["oci_manifest_digest"] and
                public["platform"] == value["platform"],
                f"GHCR anonymous readback digest/platform mismatch: {reference}; package may be private. "
                "Owner must resolve visibility, then rerun the failed publish job with the same bundle; "
                "do not rebuild or change tags.")
        print(f"PASS {reference} {public['platform']}")


def checksums(directory: Path) -> str:
    names = sorted(path.name for path in directory.iterdir() if path.name != CHECKSUMS_ASSET)
    return "".join(f"{sha256(directory / name)}  {name}\n" for name in names)


def validate_coverage(coverage: dict, value: dict, groups: list[str], manifest: dict) -> None:
    require(coverage.get("status") == "complete" and coverage.get("open_gaps") == [],
            "full artifact coverage is incomplete; do not publish a partial PR/issue artifact set")
    source = coverage.get("source", {})
    require(source.get("commit") == value["source_commit"] and source.get("expanded_cases") == 42 and
            source.get("scenarios") == 24 and HEX_RE.fullmatch(source.get("feature_sha256", "")),
            "coverage map is not bound to the frozen 24-scenario/42-case source")
    rules, counts = coverage.get("scenario_rules", {}), coverage.get("expanded_case_counts", {})
    require(rules and set(rules) == set(counts) and sum(counts.values()) == 42,
            "coverage map does not enumerate the frozen 42 case count")
    inputs = coverage.get("artifact_status", {})
    aliases = {"gateway-v6": "devshard-gateway", "versiond-v6": "versiond",
               "versiond-router": "versiond-router", "proxy-router": "proxy-router",
               "proxy-policy": "proxy-policy", "decentralized-api": "decentralized-api",
               "edge-api": "edge-api"}
    selected = set(manifest.get("artifacts", {}))

    def resolve(artifact_id: str, visiting: set[str] | None = None) -> set[str]:
        require(artifact_id in inputs, f"coverage references unknown artifact: {artifact_id}")
        record = inputs[artifact_id]
        visiting = set() if visiting is None else visiting
        require(artifact_id not in visiting, f"coverage group cycle: {artifact_id}")
        if record.get("status") == "group":
            parts = record.get("components", [])
            require(parts, f"empty coverage group: {artifact_id}")
            leaves: set[str] = set()
            for part in parts:
                leaves.update(resolve(part, visiting | {artifact_id}))
            return leaves
        require(record.get("status") in {"verified-reuse", "built", "build-required", "source-recipe"},
                f"coverage dependency is unavailable: {artifact_id}")
        component = record.get("component", aliases.get(artifact_id))
        if component:
            require(component in value["components"], f"coverage component has no frozen recipe: {artifact_id}")
            require(component in selected, f"coverage component omitted from computed bundle: {artifact_id}")
            binding = value["components"][component].get("source", value)
            expected_commit = binding.get("commit", binding.get("source_commit"))
            expected_tree = binding.get("tree", binding.get("source_tree"))
            artifact = manifest["artifacts"][component]
            require(artifact.get("source_commit") == expected_commit and artifact.get("source_tree") == expected_tree,
                    f"coverage source binding mismatch: {artifact_id}")
            require(artifact.get("platform") == record.get("platform", value["platform"]),
                    f"coverage platform mismatch: {artifact_id}")
            return {component}
        if "image" in record:
            image_pattern = (r"postgres:16\.9-bookworm@sha256:[0-9a-f]{64}" if artifact_id == "postgres-shared"
                            else r"ghcr\.io/[a-z0-9][a-z0-9._/-]*(?::[A-Za-z0-9][A-Za-z0-9._-]*)?@sha256:[0-9a-f]{64}")
            require(bool(re.fullmatch(image_pattern, record["image"])) and
                    record.get("platform") == "linux/amd64",
                    f"coverage reuse is not immutable Linux amd64: {artifact_id}")
            if artifact_id.startswith("gateway-"):
                require(record.get("protocol") in {"v4", "v5"},
                        f"coverage gateway protocol is not verified: {artifact_id}")
        if "sha256" in record:
            require(HEX_RE.fullmatch(record["sha256"]) and record.get("platform") == "linux/amd64",
                    f"coverage archive binding is invalid: {artifact_id}")
            if artifact_id == "devshard-v6-zip":
                require(record["sha256"] == value["devshard_zip"]["sha256"],
                        "coverage v6 ZIP checksum differs from immutable manifest")
            if artifact_id.startswith("devshard-") and artifact_id.endswith("-zip") and artifact_id != "devshard-v6-zip":
                parsed = urlsplit(record.get("url", ""))
                require(parsed.scheme == "https" and parsed.hostname == "github.com" and
                        parsed.path.startswith("/gonka-ai/gonka/releases/download/") and
                        record.get("protocol") in {"v4", "v4.1", "v4.2", "v5"},
                        f"coverage archive URL/protocol is not bound: {artifact_id}")
        require("image" in record or "sha256" in record,
                f"coverage leaf has no immutable reference or archive digest: {artifact_id}")
        return {artifact_id}

    declared = set(coverage.get("case_defaults", []))
    for selectors in coverage.get("case_selectors", {}).values():
        if isinstance(selectors, dict):
            for item in selectors.values():
                declared.update(item if isinstance(item, list) else [item])
        elif isinstance(selectors, list):
            declared.update(selectors)
    for bindings in rules.values():
        declared.update(item for item in bindings if item not in {"gateway-legacy", "wrapping-legacy-and-v6"})
    declared.update(coverage.get("issue_225", {}).get("required", []))
    for pair in coverage.get("issue_225", {}).get("gateway_pair_options", []):
        declared.update(pair)
    for artifact_id in sorted(declared):
        resolve(artifact_id)
    require(coverage.get("full_pr", {}).get("required_groups") == ["manual-matrix", "dapi-edge"] and
            groups == ["manual-matrix", "dapi-edge"], "full PR artifact selection is incomplete")


def verify_reused_inputs(coverage: dict, value: dict) -> None:
    with tempfile.TemporaryDirectory(prefix="devshard-artifacts-reuse-") as temporary_name:
        temporary = Path(temporary_name)
        authfile, home = temporary / "anonymous-auth.json", temporary / "home"
        home.mkdir()
        authfile.write_text("{}\n")
        checked: set[str] = set()
        for artifact_id, record in coverage["artifact_status"].items():
            if record.get("status") == "group":
                continue
            if record.get("status") != "verified-reuse":
                continue
            if artifact_id == "devshard-v6-zip":
                require(record.get("sha256") == value["devshard_zip"]["sha256"],
                        "published v6 ZIP coverage checksum differs from immutable manifest")
                checked.add(artifact_id)
                continue
            if "image" in record:
                reference = record["image"]
                image_pattern = (r"postgres:16\.9-bookworm@sha256:[0-9a-f]{64}" if artifact_id == "postgres-shared"
                                 else r"ghcr\.io/[a-z0-9][a-z0-9._/-]*(?::[A-Za-z0-9][A-Za-z0-9._-]*)?@sha256:[0-9a-f]{64}")
                require(bool(re.fullmatch(image_pattern, reference)),
                        f"reused image is not a bounded immutable registry reference: {artifact_id}")
                identity = registry_identity(reference, authfile, home)
                expected_digest = reference.rsplit("@", 1)[1]
                require(identity is not None, f"required reused image is confirmed absent: {artifact_id}")
                require(identity["oci_manifest_digest"] == expected_digest and
                        identity["platform"] == record.get("platform") == value["platform"],
                        f"anonymous reused-image digest/platform mismatch: {artifact_id}")
                if artifact_id.startswith("gateway-"):
                    require(record.get("protocol") in {"v4", "v5"},
                            f"reused gateway protocol identity is unverified: {artifact_id}")
            if "url" in record:
                url = record["url"]
                parsed = urlsplit(url)
                require(parsed.scheme == "https" and parsed.hostname == "github.com" and
                        parsed.path.startswith("/gonka-ai/gonka/releases/download/") and ".." not in parsed.path,
                        f"legacy ZIP URL is not an approved immutable GitHub release asset: {artifact_id}")
                expected_hash = record.get("sha256", "")
                require(bool(HEX_RE.fullmatch(expected_hash)) and record.get("protocol") in {"v4", "v4.1", "v4.2", "v5"} and
                        record.get("platform") == value["platform"],
                        f"legacy ZIP protocol/platform/digest binding is incomplete: {artifact_id}")
                digest = hashlib.sha256()
                request = urllib.request.Request(url, headers={"User-Agent": "external-test-lab-artifact-verifier"})
                with urllib.request.urlopen(request, timeout=90) as response:
                    while chunk := response.read(1024 * 1024):
                        digest.update(chunk)
                require(digest.hexdigest() == expected_hash,
                        f"anonymous legacy ZIP checksum mismatch: {artifact_id}")
            checked.add(artifact_id)
        required_reuse = {"devshard-v6-zip", "devshard-v4-zip", "devshard-v4.1-zip", "devshard-v4.2-zip", "devshard-v5-zip",
                          "gateway-v4", "gateway-v5", "versiond-v4", "versiond-v5",
                          "versiond-router-v4", "versiond-router-v5", "proxy-router-v5",
                          "proxy-policy-v4", "proxy-policy-current", "postgres-shared"}
        if value.get("unified_binary_definition"):
            required_reuse.remove("devshard-v6-zip")
        require(required_reuse <= checked,
                "required legacy/current-lock immutable references were not anonymously verified")


def verify(output: Path, value: dict, groups: list[str]) -> dict:
    required_components = selected_components(value, groups)
    required = {f"{name}.oci.tar" for name in required_components} | {
        ZIP_ASSET, MANIFEST_ASSET, CHECKSUMS_ASSET, COVERAGE_ASSET}
    if value.get("unified_binary_definition"):
        required.update({"source.json", "approved-version.json", "build-info.txt"})
    require(output.is_dir() and {path.name for path in output.iterdir()} == required,
            "bundle file set does not exactly match selected component groups")
    require(all(path.is_file() and not path.is_symlink() for path in output.iterdir()), "bundle contains non-regular files")
    require(sha256(output / ZIP_ASSET) == value["devshard_zip"]["sha256"], "published ZIP input mismatch")
    if value.get("unified_binary_definition"):
        binary = value["unified_binary_definition"]
        require(json.loads((output / "source.json").read_text()) == binary,
                "unified binary source definition mismatch")
        require(json.loads((output / "approved-version.json").read_text()) == {
            "name": binary["protocol"],
            "binary": value["devshard_zip"]["url"],
            "sha256": value["devshard_zip"]["sha256"],
        }, "unified approved version does not bind this ZIP")
        require((output / "build-info.txt").is_file(), "unified binary build information is missing")
    manifest = json.loads((output / MANIFEST_ASSET).read_text(encoding="utf-8"))
    require(manifest.get("schema_version") == 1 and manifest.get("definition") == value,
            "artifact manifest definition mismatch")
    require(manifest.get("groups") == groups and manifest.get("source_commit") == value["source_commit"] and
            manifest.get("source_tree") == value["source_tree"], "artifact manifest source/group mismatch")
    require(set(manifest.get("artifacts", {})) == set(required_components), "artifact manifest component set mismatch")
    for name in required_components:
        observed = verify_oci_archive(output / f"{name}.oci.tar", name, value)
        observed["ghcr_tag"] = f"{value['ghcr_namespace']}/{name}:{value['release_tag']}"
        observed["ghcr_digest_reference"] = f"{value['ghcr_namespace']}/{name}@{observed['oci_manifest_digest']}"
        require(manifest["artifacts"][name] == observed, f"artifact identity mismatch: {name}")
    require((output / CHECKSUMS_ASSET).read_text() == checksums(output), "bundle checksums mismatch")
    coverage = json.loads((output / COVERAGE_ASSET).read_text(encoding="utf-8"))
    expected_coverage = json.loads(COVERAGE.read_text(encoding="utf-8"))
    expected_coverage["artifact_status"]["devshard-v6-zip"]["sha256"] = value["devshard_zip"]["sha256"]
    require(coverage == expected_coverage, "published coverage map differs from the reviewed complete binding")
    return manifest


def build(source: Path, output: Path, value: dict, groups: list[str], binary_assets: Path | None = None) -> None:
    source_identity(source, value)
    binary_names = {ZIP_ASSET, "source.json", "approved-version.json", "build-info.txt"}
    if binary_assets is None:
        require(not output.exists() or not any(output.iterdir()), "artifact output must be empty; never overwrite")
    else:
        require(binary_assets.is_dir() and {path.name for path in binary_assets.iterdir()} >= binary_names,
                "unified binary assets are incomplete")
        if output.exists() and any(output.iterdir()):
            require({path.name for path in output.iterdir()} == binary_names,
                    "unified artifact output contains unexpected pre-existing files")
    output.mkdir(parents=True, exist_ok=True)
    if binary_assets is not None and not any(output.iterdir()):
        for name in binary_names:
            shutil.copy2(binary_assets / name, output / name)
    runtime_output = output.with_name(output.name + "-runtime")
    require(not runtime_output.exists(), "runtime smoke output already exists; never overwrite")
    runtime_output.mkdir(parents=True)
    components = selected_components(value, groups)
    builder_name = f"devshard-v6-artifacts-{os.getpid()}"
    with tempfile.TemporaryDirectory(prefix="devshard-artifacts-build-") as temporary_name, \
            tempfile.TemporaryDirectory(prefix="devshard-artifacts-docker-config-") as docker_config_name:
        temporary = Path(temporary_name)
        docker_config = Path(docker_config_name)
        (docker_config / "config.json").write_text("{}\n")
        clean_env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "DOCKER_CONFIG": str(docker_config)}
        archive = temporary / "source.tar"
        context_root = temporary / "source"
        context_root.mkdir()
        run("git", "-C", str(source), "archive", "--format=tar", f"--output={archive}", value["source_commit"])
        # Preserve Git's executable/read permissions even under restrictive operator umasks.
        run("tar", "--same-permissions", "-xf", str(archive), "-C", str(context_root))
        if binary_assets is None:
            fetch_zip(output / ZIP_ASSET, value)
        else:
            require(sha256(output / ZIP_ASSET) == value["devshard_zip"]["sha256"],
                    "unified ZIP checksum mismatch")
        coverage = json.loads(COVERAGE.read_text(encoding="utf-8"))
        coverage["artifact_status"]["devshard-v6-zip"]["sha256"] = value["devshard_zip"]["sha256"]
        (output / COVERAGE_ASSET).write_text(json.dumps(coverage, sort_keys=True, indent=2) + "\n")
        artifacts: dict[str, dict] = {}
        subprocess.run(["docker", "buildx", "create", "--name", builder_name, "--driver", "docker-container",
                        "--driver-opt", "image=" + value["buildkit_image"]],
                       check=True, env=clean_env)
        try:
            for name in components:
                component = value["components"][name]
                source_key = "v6"
                component_root = context_root
                if "source" in component:
                    binding = component["source"]
                    source_key = name
                    component_root = temporary / source_key
                    legacy_archive = temporary / f"{source_key}.source.tar"
                    fetch_bound_source(component_root, binding)
                    run("git", "-C", str(component_root), "archive", "--format=tar",
                        f"--output={legacy_archive}", binding["commit"])
                    extracted = temporary / f"{source_key}-context"
                    extracted.mkdir()
                    run("tar", "--same-permissions", "-xf", str(legacy_archive), "-C", str(extracted))
                    component_root = extracted
                dockerfile = component_root / component["dockerfile"]
                pinned = temporary / f"{name}.Dockerfile"
                run("python3", str(ROOT / "scripts/pin-candidate-dockerfile.py"), "--source", str(dockerfile),
                    "--output", str(pinned), "--base-images-json", json.dumps(component["base_images"]))
                image_tar = output / f"{name}.oci.tar"
                docker_tar = runtime_output / f"{name}.docker.tar"
                image_version = component.get("build_args", {}).get("DEVSHARD_VERSION", "v6")
                args = ["docker", "buildx", "build", "--builder", builder_name, "--progress=plain", "--platform",
                        value["platform"], "--provenance=false", "--sbom=false", "--file", str(pinned),
                        "--tag", f"{name}:{image_version}", "--output", f"type=oci,dest={image_tar},name={name}:{image_version}",
                        "--output", f"type=docker,dest={docker_tar}"]
                if "target" in component:
                    args.extend(("--target", component["target"]))
                for key, setting in component.get("build_args", {}).items():
                    args.extend(("--build-arg", f"{key}={setting}"))
                args.append(str(component_root / component["context"]))
                subprocess.run(args, check=True, env=clean_env)
                artifacts[name] = verify_oci_archive(image_tar, name, value)
        finally:
            subprocess.run(["docker", "buildx", "rm", builder_name], check=False, env=clean_env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        bundle_manifest = {"schema_version": 1, "definition": value, "groups": groups,
                           "source_commit": value["source_commit"], "source_tree": value["source_tree"],
                           "artifacts": artifacts}
        (output / MANIFEST_ASSET).write_text(json.dumps(bundle_manifest, sort_keys=True, indent=2) + "\n")
        (output / CHECKSUMS_ASSET).write_text(checksums(output))
    verify(output, value, groups)


def smoke(output: Path, value: dict, groups: list[str]) -> None:
    manifest = verify(output, value, groups)
    runtime_output = output.with_name(output.name + "-runtime")
    expected = {f"{name}.docker.tar" for name in manifest["artifacts"]}
    require(runtime_output.is_dir() and {path.name for path in runtime_output.iterdir()} == expected,
            "runtime smoke archive set differs from verified bundle")
    with tempfile.TemporaryDirectory(prefix="devshard-artifacts-smoke-") as temporary_name, \
            tempfile.TemporaryDirectory(prefix="devshard-artifacts-smoke-docker-config-") as docker_config_name:
        temporary = Path(temporary_name)
        docker_config = Path(docker_config_name)
        (docker_config / "config.json").write_text("{}\n")
        environment = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "DOCKER_CONFIG": str(docker_config)}
        loaded = []
        try:
            for name, artifact in manifest["artifacts"].items():
                component = value["components"][name]
                version = component.get("build_args", {}).get("DEVSHARD_VERSION", "v6")
                tag = f"{name}:{version}"
                run("docker", "load", "--input", str(runtime_output / f"{name}.docker.tar"), env=environment)
                loaded.append(tag)
                identity = run("docker", "image", "inspect", "--format", "{{.Os}}/{{.Architecture}} {{.Id}}",
                               tag, env=environment)
                platform, config_digest = identity.split()
                require(platform == value["platform"] and config_digest == artifact["image_config_digest"],
                        f"Docker image/config identity mismatch: {name}")
                if name in {"devshard-gateway", "gateway-v4.2", "decentralized-api"}:
                    container = f"devshard-artifact-smoke-{os.getpid()}"
                    try:
                        run("docker", "create", "--name", container, "--network", "none", "--read-only",
                            "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--user", "65534:65534", tag,
                            env=environment)
                        binary = temporary / f"{name}-binary"
                        binary_path = ("/usr/bin/decentralized-api" if name == "decentralized-api"
                                       else "/usr/local/bin/devshardctl")
                        run("docker", "cp", f"{container}:{binary_path}", str(binary), env=environment)
                        build_info = run("go", "version", "-m", str(binary))
                        if name == "decentralized-api":
                            commit = value["source_commit"]
                            expected_metadata = [
                                "version.Name=decentralized-api", "version.AppName=decentralized-api",
                                f"version.Version=lab-{commit}", f"version.Commit={commit}"]
                            require(all(item in build_info for item in expected_metadata),
                                    "DAPI embedded lab version/commit metadata mismatch")
                        else:
                            expected_version = component["build_args"]["DEVSHARD_VERSION"]
                            require(f"-X main.Version={expected_version}" in build_info and
                                    f"-X devshard/types.buildStateRootProtocolVersion={expected_version}" in build_info,
                                    f"gateway embedded protocol/version mismatch: {name}")
                            run("docker", "run", "--rm", "--network", "none", "--read-only", "--cap-drop", "ALL",
                                "--security-opt", "no-new-privileges", "--user", "65534:65534", tag, "-h", env=environment)
                    finally:
                        subprocess.run(["docker", "rm", "-f", container], env=environment,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
                print(f"PASS {name} {platform} {config_digest}")
        finally:
            for tag in loaded:
                subprocess.run(["docker", "image", "rm", tag], env=environment,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def unified_release_presentation(value: dict, manifest: dict, release_tag: str) -> tuple[str, str]:
    """Render the operator-facing release catalogue from frozen metadata only."""
    binary = value["unified_binary_definition"]
    source = binary["source_repository"]
    commit = binary["source_commit"]
    source_pr = value["source_pr"]
    require(isinstance(source_pr, int) and source_pr > 0, "unified candidate is missing upstream PR")
    base = f"https://github.com/{REPOSITORY}/releases/download/{release_tag}"
    asset = lambda name: f"[{name}]({base}/{name})"
    run_id = os.environ.get("GITHUB_RUN_ID", "")
    require(bool(re.fullmatch(r"[1-9][0-9]*", run_id)), "missing build run identity")
    run_url = f"https://github.com/{REPOSITORY}/actions/runs/{run_id}"
    title = f"DevShard v6 lab candidate · {commit[:12]}"
    downloads = "\n".join((
        "| Asset | Purpose |",
        "|---|---|",
        f"| {asset('devshardd.zip')} | Linux amd64 DevShard executable (`devshardd`) for protocol v6. |",
        f"| {asset('approved-version.json')} | Candidate registry entry for this release ZIP; not on-chain approval. |",
        f"| {asset('artifacts.json')} | Full immutable image pull references, platforms and sources. |",
        f"| {asset('coverage.json')} | Scenario artifact-dependency mapping, not executed scenario results. |",
        f"| {asset('source.json')} | Frozen binary source and build inputs. |",
        f"| {asset('build-info.txt')} | Embedded DevShard build metadata. |",
        f"| {asset('SHA256SUMS')} | Checksums for the downloadable bundle files; not a signature. |",
    ))
    roles = {
        "devshard-gateway": "DevShard gateway",
        "gateway-v4.2": "v4.2 compatibility gateway (independently pinned)",
        "versiond": "Version service",
        "versiond-router": "Version service router",
        "proxy-router": "Protocol proxy router",
        "proxy-policy": "Protocol proxy policy",
        "decentralized-api": "Decentralized API",
        "edge-api": "Edge API",
    }
    images = ["| Component | Purpose | OCI archive |", "|---|---|---|"]
    for name in manifest["artifacts"]:
        package = f"https://github.com/{REPOSITORY}/pkgs/container/external-test-lab%2F{name}"
        images.append(f"| [{name}]({package}) | {roles[name]} | {asset(name + '.oci.tar')} |")
    legacy = value["components"]["gateway-v4.2"]["source"]
    body = (
        "This is an External Test Lab candidate, not an official Gonka release or network qualification result.\n\n"
        f"Built from [Gonka PR #{source_pr}](https://github.com/{source}/pull/{source_pr}) at "
        f"[snapshot {commit[:12]}](https://github.com/{source}/pull/{source_pr}/changes/{commit}) · "
        f"[source commit {commit[:12]}](https://github.com/{source}/commit/{commit})\n\n"
        f"Protocol `v6` on `{value['platform']}`. [Build run]({run_url}).\n\n"
        "## Downloads\n\n" + downloads + "\n\n"
        "## Container images\n\n"
        f"Shared registry tag: `{value['release_tag']}` on `{value['platform']}`. Package links are navigation; "
        f"use {asset('artifacts.json')} for immutable digest pull references. The v4.2 gateway is pinned to "
        f"[its independent source](https://github.com/{legacy['repository']}/commit/{legacy['commit']}).\n\n" +
        "\n".join(images) + "\n\n"
        "## Verification and compatibility\n\n"
        f"Verify downloaded files against {asset('SHA256SUMS')}; verify registry pulls against {asset('artifacts.json')}. "
        "The hosted build performed binary and image identity smoke checks. This candidate requires musl, "
        "`libgcc_s.so.1`, and a CPU compatible with upstream `BLST_PORTABLE=0`; artifact smoke does not qualify a deployment or network.\n"
    )
    return title, body


def publish(output: Path, value: dict, groups: list[str]) -> None:
    require(os.environ.get("GITHUB_REPOSITORY") == REPOSITORY and
            os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch" and
            os.environ.get("GITHUB_REF") == "refs/heads/main", "publication requires manual default-branch workflow")
    revision = os.environ.get("GITHUB_SHA", "")
    require(bool(re.fullmatch(r"[0-9a-f]{40}", revision)) and
            run("git", "-C", str(ROOT.parent), "rev-parse", "HEAD") == revision,
            "publisher checkout revision mismatch")
    manifest = verify(output, value, groups)
    require(groups == ["manual-matrix", "dapi-edge"],
            "full publication requires manual-matrix and dapi-edge groups")
    coverage = json.loads((output / COVERAGE_ASSET).read_text(encoding="utf-8"))
    validate_coverage(coverage, value, groups, manifest)
    unified = bool(value.get("unified_binary_definition"))
    release_tag = value["release_tag"] if unified else f"{value['release_tag']}-{'-'.join(groups)}"
    releases = json.loads(run("gh", "release", "list", "--repo", REPOSITORY, "--limit", "1000", "--json", "tagName"))
    require(all(item["tagName"] != release_tag for item in releases), "release already exists; never overwrite")
    refs = json.loads(run("gh", "api", f"repos/{REPOSITORY}/git/matching-refs/tags/{release_tag}"))
    require(not any(item["ref"] == f"refs/tags/{release_tag}" for item in refs), "release tag already exists")
    verify_reused_inputs(coverage, value)
    with tempfile.TemporaryDirectory(prefix="devshard-artifacts-publish-") as temporary_name:
        temporary = Path(temporary_name)
        home = temporary / "home"
        home.mkdir()
        authfile = temporary / "auth.json"
        authfile.write_text("{}\n")
        token, actor = os.environ.get("GH_TOKEN", ""), os.environ.get("GITHUB_ACTOR", "")
        require(token and actor, "missing trusted publisher registry credentials")
        component_paths = {name: output / f"{name}.oci.tar" for name in manifest["artifacts"]}
        publish_registry(manifest, component_paths, value, authfile, home, token, actor)
        notes = temporary / "notes.md"
        title, body = (unified_release_presentation(value, manifest, release_tag) if unified else
                       (release_tag, "Lab candidate artifacts, not an official Gonka release or qualification result\n"))
        notes.write_text(body)
        paths = sorted(output.iterdir()) if unified else [output / CHECKSUMS_ASSET, output / MANIFEST_ASSET,
                                                           output / COVERAGE_ASSET, output / ZIP_ASSET,
                                                           *(output / f"{name}.oci.tar" for name in manifest["artifacts"])]
        run("gh", "release", "create", release_tag, "--repo", REPOSITORY, "--target", revision, "--title", title,
            "--draft", "--prerelease", "--latest=false", "--notes-file", str(notes), *(str(path) for path in paths))
        downloaded = temporary / "download"
        run("gh", "release", "download", release_tag, "--repo", REPOSITORY, "--dir", str(downloaded))
        verify(downloaded, value, groups)
        local_names = {path.name for path in output.iterdir()}
        require({path.name for path in downloaded.iterdir()} == local_names,
                "uploaded release asset set differs from verified bundle")
        require(all(sha256(output / name) == sha256(downloaded / name) for name in local_names),
                "uploaded release bytes differ from verified bundle; draft retained")
        run("gh", "release", "edit", release_tag, "--repo", REPOSITORY, "--draft=false", "--prerelease", "--latest=false")
        readback = json.loads(run("gh", "release", "view", release_tag, "--repo", REPOSITORY,
                                  "--json", "isDraft,isPrerelease,url,name,body"))
        require(not readback["isDraft"] and readback["isPrerelease"], "release publication readback failed")
        if unified:
            require(readback["name"] == title and readback["body"] == body,
                    "published unified release presentation differs from generated catalogue")
        print(readback["url"])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "fetch", "build", "verify", "smoke", "verify-reuse", "publish"))
    parser.add_argument("--group", action="append", choices=("manual-matrix", "dapi-edge"), dest="groups")
    args = parser.parse_args()
    value = load_definition()
    groups = args.groups or ["manual-matrix"]
    if args.command == "prepare":
        print(json.dumps({"definition": value, "groups": groups, "components": selected_components(value, groups)}, indent=2))
        return
    dependencies(args.command)
    output = Path(os.environ.get("DEVSHARD_ARTIFACTS_DIR", str(ROOT / ".data/devshard-v6-artifacts"))).resolve()
    if args.command == "fetch":
        require(bool(os.environ.get("DEVSHARD_SOURCE")), "set DEVSHARD_SOURCE to a new checkout directory")
        fetch_source(Path(os.environ["DEVSHARD_SOURCE"]).resolve(), value)
    elif args.command == "build":
        require(bool(os.environ.get("DEVSHARD_SOURCE")), "set DEVSHARD_SOURCE to the frozen Gonka checkout")
        build(Path(os.environ["DEVSHARD_SOURCE"]).resolve(), output, value, groups)
    elif args.command == "verify":
        verify(output, value, groups)
    elif args.command == "smoke":
        smoke(output, value, groups)
    elif args.command == "verify-reuse":
        manifest = verify(output, value, groups)
        coverage = json.loads((output / COVERAGE_ASSET).read_text(encoding="utf-8"))
        validate_coverage(coverage, value, groups, manifest)
        verify_reused_inputs(coverage, value)
    else:
        publish(output, value, groups)


if __name__ == "__main__":
    main()
