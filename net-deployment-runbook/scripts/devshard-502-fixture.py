#!/usr/bin/env python3
"""Prepare a private upstream testenv with exact official runtime artifacts."""

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import zipfile


SOURCE = "eddae498572a43408232b22f2da25e64d30b9669"
GATEWAY = "ghcr.io/gonka-ai/devshard-gateway@sha256:735240e2f8dfa77c27caf72d4442019c31b33546e047c92ff34bd8286857e4e2"
VERSIOND = "ghcr.io/gonka-ai/versiond@sha256:eb9cef6a3b0ba91c9b444339b1bebcfbe8d5db05db93d4363f295de9aec95c1e"
ARTIFACTS = {
    "5.0.2": ("fa9f30775abfc14c40ac8d8a9bae7159f6193cd820f3dfac06a60170cd8b48a1",
              "4cdffe680b700924e5f1c67a0e8a5113c8edb5896186214cf0d1d96089dfb832"),
    "5.0.1": ("e4dcde3990a3af62efcf6af5da8557b05ed3a98ede4a343aab020986a68a2012",
              "7ad1873b480bac39e4f6bb5be7549b51ba2b7292c42645e61f826c55d48a6314"),
}
OLD_BINARY = "b068db453dfaf704d3745c0d925005fe390b9cb36c9bb89422286eda0333e42b"
OLD_ARCHIVE = "ae2d1f90374b54efd4290b4df8b8c0ae339deb0d3b6e5b10936ea9f73155f564"
HELPERS = ("gencompose", "mockchain", "mockdapi", "mockopenai")
CHAIN = "gonka-test-ds502-isolated"
MODEL = "Qwen/Qwen3-0.6B"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_json(path, value):
    with Path(path).open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")


def run(args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def seed(initial_version="5.0.2"):
    require(initial_version in ("5.0.2", "5.0.0-cached"), "unsupported initial artifact")
    return {
        "chain_id": CHAIN, "block_height": 150,
        "epoch": {"index": 1, "poc_start_block_height": 1,
                  "params_block_height": 1, "next_poc_start_block_height": 100000,
                  "epoch_length": 100000},
        "params": {"max_nonce": 20000, "devshard_requests_enabled": True},
        "versiond": {"mode": "single", "version_name": "v5",
                     "binary_version": "v5.0.0" if initial_version == "5.0.0-cached" else "v5.0.2"},
        "hosts": [{"id": "versiond-0", "url": "http://versiond-0:8080"}],
        "escrow": {"slots": 1, "slot_url": "http://versiond-0:8080"},
        "escrows": [{"id": 1, "amount": 5000000000, "model_id": MODEL,
                     "token_price": 1, "fee_per_nonce": 1000}],
        "epoch_groups": [{"epoch_index": 1, "model_id": MODEL,
                          "validation_threshold_value": 50}],
    }


def bind(source, target, readonly=True):
    return {"type": "bind", "source": str(source), "target": target,
            "read_only": readonly, "bind": {"create_host_path": False}}


def composition(generated, root, project, initial_version="5.0.2"):
    require(initial_version in ("5.0.2", "5.0.0-cached"), "unsupported initial artifact")
    services = generated["services"]
    require(set(services) == {"mock-chain", "mock-dapi", "mock-openai", "versiond-0",
                              "versiond-router", "devshardctl"}, "unexpected upstream topology")
    del services["versiond-router"]
    for name, service in services.items():
        service.pop("build", None)
        service.pop("container_name", None)
        service["restart"] = "no"
        service["networks"] = {"fixture": None}
        service["labels"] = {"org.gonka.test-lab.scope": "ds502-fixture", "org.gonka.test-lab.owner": project}
        for port in service.get("ports", []):
            port.update(host_ip="127.0.0.1", published="0")
        if name.startswith("mock-"):
            service["image"] = VERSIOND
            helper = {"mock-chain": "mockchain", "mock-dapi": "mockdapi", "mock-openai": "mockopenai"}[name]
            service["entrypoint"] = ["/fixture-bin/" + helper]
            service["command"] = []
            service.setdefault("volumes", []).append(bind(root / "helpers", "/fixture-bin"))
    host = services["versiond-0"]
    host["image"] = VERSIOND
    env = host["environment"]
    require(env["CHAIN_ID"] == CHAIN, "fixture chain mismatch")
    for key in list(env):
        if key == "VERSIOND_FORCE" or key.startswith("VERSIOND_OVERRIDE_"):
            del env[key]
    env.update(DEVSHARD_STORAGE_MODE="sqlite", GONKA_HA="false", VERSIOND_HOST_SHUTDOWN_BUDGET="90s",
               DEVSHARD_SHUTDOWN_GRACE="60s", VERSIOND_DRAIN_KILL_GRACE="60s", VERSIOND_DRAIN_ANNOUNCE="0s")
    host["stop_grace_period"] = "90s"
    host["ports"] = [{"target": 8080, "published": "0", "host_ip": "127.0.0.1", "protocol": "tcp"}]
    host["volumes"] = [bind(root / "keyring", "/keyring", False),
                       bind(root / "data/host", "/opt/versiond/data", False),
                       bind(root / "data/bin", "/opt/versiond/bin", False)]
    services["mock-chain"]["volumes"] = [bind(root / "config.yaml", "/app/config.yaml"),
                                          bind(root / "helpers", "/fixture-bin")]
    services["mock-dapi"]["volumes"] = [bind(root / "binaries", "/testenv-binaries"),
                                         bind(root / "helpers", "/fixture-bin")]
    services["mock-dapi"]["environment"].update(
        MOCK_DAPI_VERSION_NAME="v5",
        MOCK_DAPI_VERSION_BINARY="http://mock-dapi:9100/testenv/binaries/devshardd-5.0.2.zip",
        MOCK_DAPI_VERSION_SHA256=ARTIFACTS["5.0.2"][0])
    if initial_version == "5.0.0-cached":
        services["mock-dapi"]["environment"].update(
            MOCK_DAPI_VERSION_BINARY="http://mock-dapi:9100/testenv/binaries/missing-devshardd-5.0.0.zip",
            MOCK_DAPI_VERSION_SHA256=OLD_ARCHIVE)
    gateway = services["devshardctl"]
    gateway["image"] = GATEWAY
    gateway.pop("entrypoint", None)
    gateway.pop("command", None)
    gateway["volumes"] = [bind(root / "data/gateway-a", "/var/lib/devshardctl", False)]
    gateway["depends_on"].pop("versiond-router")
    gateway["depends_on"]["versiond-0"] = {"condition": "service_started", "required": True}
    gateway["environment"].update(
        DEVSHARD_ROUTE_PREFIX="/devshard/v5", DEVSHARD_ESCROW_ROTATION_ENABLED="false",
        DEVSHARD_ESCROW_ROTATION_SETTLEMENT_ENABLED="false",
        DEVSHARD_ADMIN_API_KEY="fixture-a-admin-key-not-for-live-use",
        DEVSHARD_API_KEYS="fixture-a-client-key-not-for-live-use")
    for service in services.values():
        service["platform"] = "linux/amd64"
        for mount in service.get("volumes", []):
            require(mount["type"] == "bind" and Path(mount["source"]).resolve().is_relative_to(root),
                    "mount escaped the private fixture")
            mount.setdefault("bind", {})["create_host_path"] = False
    return {"name": project, "services": services, "networks": {"fixture": {"internal": True}}}


def operator_binding(root, document, name="a", service="devshardctl"):
    directory = root / ("operator-" + name)
    directory.mkdir(mode=0o700, exist_ok=True)
    env = document["services"][service]["environment"]
    body = "".join(f"{key}={env[key]}\n" for key in
                   ("DEVSHARD_PRIVATE_KEY", "DEVSHARD_ADMIN_API_KEY", "DEVSHARD_API_KEYS"))
    target = directory / "gateway.env"
    if target.exists():
        require(target.read_text() == body, "existing synthetic operator binding drift")
    else:
        with target.open("x", encoding="utf-8") as stream:
            stream.write(body)


def pair_documents(document, second, root, project):
    """Independent fresh writers share only the owned mock infrastructure."""
    require(document["name"] == project and document["networks"] == {"fixture": {"internal": True}},
            "owned internal fixture network required")
    documents = {"infra": copy.deepcopy(document)}
    original = documents["infra"]["services"].pop("devshardctl")
    second_key = second["services"]["devshardctl"]["environment"]["DEVSHARD_PRIVATE_KEY"]
    require(second_key != original["environment"]["DEVSHARD_PRIVATE_KEY"], "A/B identity collision")
    network = project + "_fixture"
    documents["infra"]["networks"]["fixture"].update(
        name=network, labels={"org.gonka.test-lab.scope": "ds502-fixture", "org.gonka.test-lab.owner": project})
    for name in ("a", "b"):
        gateway = copy.deepcopy(original)
        gateway.pop("depends_on", None)
        gateway["labels"]["org.gonka.test-lab.owner"] = project + "-" + name
        gateway["volumes"] = [bind(root / ("data/gateway-" + name), "/var/lib/devshardctl", False)]
        env = gateway["environment"]
        env.pop("DEVSHARD_ESCROW_ID", None)
        env["DEVSHARDS_JSON"] = "[]"
        env["DEVSHARD_ADMIN_API_KEY"] = f"fixture-{name}-admin-key-not-for-live-use"
        env["DEVSHARD_API_KEYS"] = f"fixture-{name}-client-key-not-for-live-use"
        if name == "b":
            env["DEVSHARD_PRIVATE_KEY"] = second_key
        documents[name] = {"name": project + "-" + name, "services": {"gateway": gateway},
                           "networks": {"fixture": {"external": True, "name": network}}}
    return documents


def preparation_inputs(args):
    require(args.archive_502, "official 5.0.2 archive required")
    require(args.initial_version != "5.0.0-cached" or args.old_500,
            "cached 5.0.0 initial state requires its exact executable")
    require(not args.two_gateways or args.initial_version == "5.0.2", "A/B qualification uses fresh 5.0.2 only")
    return [(version, source) for version, source in
            (("5.0.2", args.archive_502), ("5.0.1", args.archive_501)) if source is not None]


def install_old_cache(root):
    source = root / "binaries/devshardd-5.0.0-cached"
    require(digest(source) == OLD_BINARY, "old cache executable checksum mismatch")
    target = root / "data/bin/v5" / OLD_ARCHIVE
    require(not target.exists(), "old cache target already exists")
    target.mkdir(parents=True, mode=0o700)
    shutil.copyfile(source, target / "devshardd")
    (target / "devshardd").chmod(0o755)
    require(digest(target / "devshardd") == OLD_BINARY, "old cache copy checksum mismatch")
    # Reproduce the retained install metadata, not an invented release ZIP.
    write_json(target / "install.json", {"archive_sha256": OLD_ARCHIVE, "binary_sha256": OLD_BINARY})


def reuse_helpers(source, expected_hash, target):
    receipt_path = source / "prepared.json"
    require(digest(receipt_path) == expected_hash, "helper preparation receipt hash mismatch")
    receipt = json.loads(receipt_path.read_text())
    require(receipt["source"] == SOURCE and set(receipt["helpers"]) == set(HELPERS), "helper source contract mismatch")
    for name in HELPERS:
        helper = source / "helpers" / name
        require(helper.is_file() and not helper.is_symlink() and digest(helper) == receipt["helpers"][name],
                "prepared helper checksum mismatch")
    for name in HELPERS:
        helper = target / name
        shutil.copyfile(source / "helpers" / name, helper)
        helper.chmod(0o755)
        require(digest(helper) == receipt["helpers"][name], "helper copy checksum mismatch")
    return receipt["source_archive_sha256"]


def prepare(args):
    archives = preparation_inputs(args)
    root = args.root.absolute()
    require(root == root.resolve() and root.parent.is_dir() and not root.exists(),
            "fixture root must be a new nonsymlink directory in an existing private parent")
    require(root.name.startswith("ds502-fixture-"), "fixture directory must have ds502-fixture- prefix")
    root.mkdir(mode=0o700)
    project = "ds502-fixture-" + hashlib.sha256(str(root).encode()).hexdigest()[:12]
    for directory in ("source", "helpers", "binaries", "data/host", "data/bin", "data/gateway-a"):
        (root / directory).mkdir(parents=True, mode=0o700)
    verified = {}
    for version, source in archives:
        archive_hash, binary_hash = ARTIFACTS[version]
        target = root / "binaries" / f"devshardd-{version}.zip"
        shutil.copyfile(source, target)
        require(digest(target) == archive_hash, f"official {version} archive checksum mismatch")
        with zipfile.ZipFile(target) as archive:
            require(archive.namelist() == ["devshardd"], "unexpected release archive members")
            with archive.open("devshardd") as stream:
                actual = hashlib.file_digest(stream, "sha256").hexdigest()
        require(actual == binary_hash, f"official {version} executable checksum mismatch")
        verified[version] = {"archive_sha256": archive_hash, "executable_sha256": actual}
    if args.old_500:
        shutil.copyfile(args.old_500, root / "binaries/devshardd-5.0.0-cached")
        require(digest(root / "binaries/devshardd-5.0.0-cached") == OLD_BINARY, "old exact executable mismatch")
        verified["5.0.0"] = {"executable_sha256": OLD_BINARY, "archive_available": False}
    if args.initial_version == "5.0.0-cached":
        install_old_cache(root)
        verified["5.0.0"]["retained_cache_archive_sha256"] = OLD_ARCHIVE
    if args.helpers_from:
        source_hash = reuse_helpers(args.helpers_from, args.helpers_receipt_sha256, root / "helpers")
    else:
        with (root / "source.tar").open("xb") as stream:
            run(["git", "-C", args.source_git, "archive", SOURCE, "devshard", "common", "inference-chain"], stdout=stream)
        with tarfile.open(root / "source.tar") as archive:
            archive.extractall(root / "source", filter="data")
        with (root / "helper-build.log").open("xb") as stream:
            run(["go", "build", "-p", "2", "-trimpath", "-o", str(root / "helpers") + "/",
                 *[f"./testenv/cmd/{name}" for name in HELPERS]], cwd=root / "source/devshard",
                env={**os.environ, "CGO_ENABLED": "0", "GOFLAGS": "-mod=readonly"}, stdout=stream, stderr=stream)
        source_hash = digest(root / "source.tar")
    write_json(root / "config.yaml", seed(args.initial_version))
    with (root / "generate.log").open("xb") as stream:
        run([root / "helpers/gencompose", "-config", root / "config.yaml", "-out", root / "upstream.yaml"],
            stdout=stream, stderr=stream)
    generated = json.loads(run(["docker", "--context", "default", "compose", "-p", project,
                               "-f", root / "upstream.yaml", "config", "--format", "json"],
                              capture_output=True, text=True).stdout)
    document = composition(generated, root, project, args.initial_version)
    pair = None
    if args.two_gateways:
        identity_root = root / "identity-b"
        identity_root.mkdir(mode=0o700)
        (root / "data/gateway-b").mkdir(mode=0o700)
        write_json(identity_root / "config.yaml", seed())
        with (identity_root / "generate.log").open("xb") as stream:
            run([root / "helpers/gencompose", "-config", identity_root / "config.yaml",
                 "-out", identity_root / "upstream.yaml"], stdout=stream, stderr=stream)
        second = json.loads(run(["docker", "--context", "default", "compose", "-p", project + "-identity-b",
                                "-f", identity_root / "upstream.yaml", "config", "--format", "json"],
                               capture_output=True, text=True).stdout)
        pair = pair_documents(document, second, root, project)
        document = pair["infra"]
        for name in ("a", "b"):
            write_json(root / ("compose-" + name + ".json"), pair[name])
            operator_binding(root, pair[name], name, "gateway")
    write_json(root / "compose.json", document)
    if not pair:
        operator_binding(root, document)
    images = json.loads(run(["docker", "--context", "default", "image", "inspect", GATEWAY, VERSIOND],
                            capture_output=True, text=True).stdout)
    require(all(image["Architecture"] == "amd64" and image["Os"] == "linux" for image in images),
            "runtime platform mismatch")
    receipt = {"schema": "gdc-ds502-fixture/1", "project": project, "source": SOURCE,
               "source_archive_sha256": source_hash, "artifacts": verified,
               "helper_preparation_receipt_sha256": args.helpers_receipt_sha256,
               "initial_version": args.initial_version,
               "helpers": {name: digest(root / "helpers" / name) for name in HELPERS},
               "images": [{"id": image["Id"], "digests": image["RepoDigests"]} for image in images],
               "compose_sha256": digest(root / "compose.json"), "runtime_acceptance": "NOT RUN"}
    if pair:
        receipt.update(schema="gdc-ds502-fixture/2", two_gateways=True,
                       config_sha256=digest(root / "config.yaml"),
                       gateway_compose_sha256={name: digest(root / ("compose-" + name + ".json")) for name in ("a", "b")},
                       identity_b_seed_sha256=digest(identity_root / "config.yaml"))
    write_json(root / "prepared.json", receipt)
    print(json.dumps({"project": project, "prepared": str(root), "runtime_acceptance": "NOT RUN"}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-git", type=Path)
    parser.add_argument("--helpers-from", type=Path, help="reuse checksum-bound testenv helpers, never runtime state or identities")
    parser.add_argument("--helpers-receipt-sha256")
    parser.add_argument("--initial-version", choices=("5.0.2", "5.0.0-cached"), default="5.0.2")
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--archive-502", type=Path)
    parser.add_argument("--archive-501", type=Path)
    parser.add_argument("--old-500", type=Path)
    parser.add_argument("--two-gateways", action="store_true", help="prepare fresh independent A/B projects on one internal fixture network")
    parser.add_argument("--render-existing-to", help="new Compose filename; retain earlier renders and data")
    args = parser.parse_args()
    os.umask(0o077)
    try:
        if args.render_existing_to:
            root = args.root.resolve(strict=True)
            require(Path(args.render_existing_to).name == args.render_existing_to,
                    "render output must be a new filename inside the fixture")
            receipt = json.loads((root / "prepared.json").read_text())
            require(not receipt.get("two_gateways"), "A/B renders are immutable; retain them and prepare a new fixture")
            require(receipt["source"] == SOURCE and receipt["compose_sha256"] == digest(root / "compose.json"),
                    "original preparation receipt drift")
            generated = json.loads(run(["docker", "--context", "default", "compose", "-p", receipt["project"],
                                       "-f", root / "upstream.yaml", "config", "--format", "json"],
                                      capture_output=True, text=True).stdout)
            document = composition(generated, root, receipt["project"], receipt.get("initial_version", "5.0.2"))
            write_json(root / args.render_existing_to, document)
            operator_binding(root, document)
            print(json.dumps({"rendered": args.render_existing_to, "runtime_acceptance": "NOT RUN"}))
        else:
            require(bool(args.source_git) != bool(args.helpers_from), "select exactly one helper build or reuse source")
            require(not args.helpers_from or args.helpers_receipt_sha256, "helper receipt hash required")
            prepare(args)
    except (ValueError, OSError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        print(f"BLOCKED: fixture preparation failed ({type(error).__name__}); retain the private logs", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
