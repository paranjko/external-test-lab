#!/usr/bin/env python3
"""Offline fail-closed contract tests for v6 OCI artifact bundles."""

import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("artifacts", Path(__file__).with_name("devshard-artifacts.py"))
artifacts = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(artifacts)


def blob(data: bytes) -> tuple[str, bytes]:
    return "sha256:" + hashlib.sha256(data).hexdigest(), data


def make_oci(path: Path, unsafe: str | None = None) -> dict:
    config_digest, config = blob(json.dumps({"os": "linux", "architecture": "amd64"}).encode())
    layer_digest, layer = blob(b"layer")
    manifest = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                           "config": {"mediaType": "application/vnd.oci.image.config.v1+json",
                                      "digest": config_digest, "size": len(config)},
                           "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
                                       "digest": layer_digest, "size": len(layer)}]}, separators=(",", ":")).encode()
    manifest_digest, _ = blob(manifest)
    index = json.dumps({"schemaVersion": 2, "manifests": [{"mediaType": "application/vnd.oci.image.manifest.v1+json",
                       "digest": manifest_digest, "size": len(manifest)}]}).encode()
    records = {"oci-layout": b'{"imageLayoutVersion":"1.0.0"}', "index.json": index,
               f"blobs/sha256/{manifest_digest[7:]}": manifest,
               f"blobs/sha256/{config_digest[7:]}": config,
               f"blobs/sha256/{layer_digest[7:]}": layer}
    with tarfile.open(path, "w") as archive:
        for name, data in records.items():
            item = tarfile.TarInfo(name)
            item.size = len(data)
            item.mode = 0o644
            archive.addfile(item, io.BytesIO(data))
        if unsafe:
            item = tarfile.TarInfo(unsafe)
            item.size = 0
            archive.addfile(item, io.BytesIO(b""))
    return {"oci_manifest_digest": manifest_digest, "image_config_digest": config_digest,
            "platform": "linux/amd64", "archive_sha256": artifacts.sha256(path)}


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.definition = artifacts.load_definition()
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def bundle(self, groups=("manual-matrix",)):
        value = copy.deepcopy(self.definition)
        value["devshard_zip"]["sha256"] = hashlib.sha256(b"frozen zip fixture").hexdigest()
        components = artifacts.selected_components(value, list(groups))
        output = self.root / ("bundle-" + "-".join(groups))
        output.mkdir()
        (output / artifacts.ZIP_ASSET).write_bytes(b"frozen zip fixture")
        coverage = json.loads(artifacts.COVERAGE.read_text())
        coverage["artifact_status"]["devshard-v6-zip"]["sha256"] = value["devshard_zip"]["sha256"]
        (output / artifacts.COVERAGE_ASSET).write_text(json.dumps(coverage, sort_keys=True, indent=2) + "\n")
        identities = {}
        for name in components:
            identity = make_oci(output / f"{name}.oci.tar")
            binding = value["components"][name].get("source", value)
            identity.update(source_commit=binding.get("commit", binding.get("source_commit")),
                            source_tree=binding.get("tree", binding.get("source_tree")))
            identity.update(ghcr_tag=f"{value['ghcr_namespace']}/{name}:{value['release_tag']}",
                            ghcr_digest_reference=f"{value['ghcr_namespace']}/{name}@{identity['oci_manifest_digest']}")
            identities[name] = identity
        manifest = {"schema_version": 1, "definition": value, "groups": list(groups),
                    "source_commit": value["source_commit"], "source_tree": value["source_tree"],
                    "artifacts": identities}
        (output / artifacts.MANIFEST_ASSET).write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
        (output / artifacts.CHECKSUMS_ASSET).write_text(artifacts.checksums(output))
        return output, value, list(groups)

    def test_manifest_freezes_source_zip_base_images_groups_and_mapping(self):
        value = artifacts.load_definition()
        self.assertEqual(value["source_commit"], "e9d56e2a4e810788ec4be39725026cd892cf1080")
        self.assertEqual(value["source_tree"], "8df9b176838294dcc5d26ecd07a5059935569821")
        self.assertEqual(value["devshard_zip"]["sha256"],
                         "7732479a265a3bd6b76e06c738f5ae1d32ddf6e20f07afa444e06416feb0d876")
        self.assertEqual(artifacts.selected_components(value, ["manual-matrix"]),
                         ["devshard-gateway", "gateway-v4.2", "versiond", "versiond-router", "proxy-router", "proxy-policy"])
        self.assertEqual(artifacts.selected_components(value, ["dapi-edge"]), ["decentralized-api", "edge-api"])
        self.assertEqual(value["components"]["versiond"]["context"], "versioned")
        for router in ("versiond-router", "proxy-router"):
            self.assertEqual(value["components"][router]["context"], ".")
            self.assertNotIn("target", value["components"][router])
        self.assertEqual(value["components"]["devshard-gateway"]["target"], "devshardctl-runtime")
        dapi_args = value["components"]["decentralized-api"]["build_args"]
        self.assertEqual((dapi_args["GOOS"], dapi_args["GOARCH"]), ("linux", "amd64"))
        self.assertIn("version.Version=lab-e9d56e2a4e810788ec4be39725026cd892cf1080", dapi_args["LDFLAGS"])
        self.assertIn("version.Commit=e9d56e2a4e810788ec4be39725026cd892cf1080", dapi_args["LDFLAGS"])

    def test_source_bound_coverage_map_resolves_all_42_expanded_cases(self):
        coverage = json.loads((artifacts.ROOT / "releases/devshard-v6-coverage.json").read_text())
        rules, counts, inputs = (coverage["scenario_rules"], coverage["expanded_case_counts"],
                                 coverage["artifact_status"])
        self.assertEqual(set(rules), set(counts))
        self.assertEqual(len(rules), coverage["source"]["scenarios"])
        self.assertEqual(sum(counts.values()), coverage["source"]["expanded_cases"])
        all_ids = set(inputs)
        selectors = coverage["case_selectors"]
        self.assertTrue(set(coverage["case_defaults"]) <= all_ids)
        self.assertEqual(selectors["binary"]["v4.2"], ["devshard-v4.2-zip", "gateway-v4.2"])
        self.assertIn("devshard-v4.2-zip", rules["a mixed escrow keeps HTTP/2 and JSON apart"])
        self.assertIn("gateway-v4.2", rules["a mixed escrow keeps HTTP/2 and JSON apart"])
        self.assertNotIn("gateway-v4.2", coverage["issue_225"]["required"])
        self.assertEqual(coverage["issue_225"]["gateway_pair_options"],
                         [["gateway-v6", "gateway-v6"], ["gateway-v6", "gateway-v4.2"]])
        self.assertEqual(coverage["full_pr"]["required_groups"], ["manual-matrix", "dapi-edge"])
        self.assertEqual(coverage["full_pr"]["additional_components"],
                         ["decentralized-api", "edge-api"])
        self.assertTrue(set(coverage["full_pr"]["additional_components"]) <= all_ids)
        for title, bindings in rules.items():
            self.assertTrue(set(bindings) <= all_ids | {"gateway-legacy", "wrapping-legacy-and-v6"}, title)

        source = os.environ.get("DEVSHARD_SOURCE")
        if source:
            feature = Path(source) / coverage["source"]["feature_path"]
            self.assertEqual(hashlib.sha256(feature.read_bytes()).hexdigest(),
                             coverage["source"]["feature_sha256"])
            expanded = {}
            bindings_by_case = []
            title = None
            tags = []
            outline = False
            in_examples = False
            header = False
            columns = []
            for line in feature.read_text().splitlines():
                text = line.strip()
                if text.startswith("@"):
                    tags = [tag.removeprefix("@") for tag in text.split()]
                elif text.startswith("Scenario Outline:"):
                    title = text.split(":", 1)[1].strip()
                    outline, in_examples = True, False
                elif text.startswith("Scenario:"):
                    title = text.split(":", 1)[1].strip()
                    expanded[title] = 1
                    bindings_by_case.append((title, {}, tags))
                    outline, in_examples = False, False
                    tags = []
                elif text == "Examples:" and outline:
                    in_examples, header = True, True
                elif in_examples and text.startswith("|"):
                    values = [item.strip() for item in text.strip("|").split("|")]
                    if header:
                        columns, header = values, False
                    elif not all(set(item) <= {"-"} for item in values):
                        expanded[title] = expanded.get(title, 0) + 1
                        bindings_by_case.append((title, dict(zip(columns, values)), tags))
                elif in_examples and text and not text.startswith("|"):
                    in_examples = False
            self.assertEqual(expanded, counts)
            self.assertEqual(len(bindings_by_case), coverage["source"]["expanded_cases"])
            for title, values, tags in bindings_by_case:
                defaults = coverage.get("case_default_overrides", {}).get(title, coverage["case_defaults"])
                resolved = set(defaults + rules[title])
                if "gateway-legacy" in resolved:
                    resolved.remove("gateway-legacy")
                    field = "binary" if "binary" in values else "remote host" if "remote host" in values else "child"
                    binary = values.get(field)
                    self.assertIn(binary, selectors["binary"], f"unmapped legacy binary: {title} {values}")
                    resolved.update(selectors["binary"][binary])
                if "wrapping-legacy-and-v6" in resolved:
                    resolved.remove("wrapping-legacy-and-v6")
                    if "both-wrappings" in tags:
                        resolved.update(selectors["two_wrappings"])
                    else:
                        wrapping = values.get("wrapping", "")
                        if wrapping in selectors["crossed_wrapping"]:
                            resolved.update(selectors["crossed_wrapping"][wrapping])
                        else:
                            used = {version for version in ("v4", "v5") if version in wrapping}
                            self.assertTrue(used, f"unmapped wrapping scenario: {title} {values}")
                            cell = values.get("cell")
                            if cell in selectors["cell"]:
                                resolved.update(selectors["cell"][cell])
                            else:
                                self.fail(f"old wrapping case has no cell-specific image binding: {title} {values}")
                cell = values.get("cell")
                if cell in selectors["default_cell"] and "v6-wrapping" in tags:
                    resolved.update(selectors["default_cell"][cell])
                self.assertTrue(resolved, title)
                expanded = set()
                pending = list(resolved)
                while pending:
                    artifact_id = pending.pop()
                    self.assertIn(artifact_id, all_ids, f"unknown artifact ID: {title} {values}")
                    record = inputs[artifact_id]
                    if record.get("status") == "group":
                        self.assertTrue(record.get("components"), artifact_id)
                        pending.extend(record["components"])
                    else:
                        expanded.add(artifact_id)
                self.assertTrue(expanded, title)
                self.assertTrue(all(inputs[item].get("status") for item in expanded), title)
                if title == "v6 wrapping still serves an older devshard over JSON":
                    binary = values["binary"]
                    self.assertIn(selectors["binary"][binary][0], expanded)
                    self.assertNotIn("gateway-v6", expanded)
                if title == "v6 on the old wrapping uses HTTP/1.1 and does not multiplex":
                    if values.get("wrapping") == "v4" and values.get("cell") == "S":
                        self.assertEqual(expanded, {"devshard-v6-zip", "gateway-v6", "versiond-v4", "proxy-policy-v4"})
                    if values.get("wrapping") == "v4" and values.get("cell") == "H":
                        self.assertIn("versiond-router-v4", expanded)
                    if values.get("wrapping") == "v4 versiond behind v5 proxy-router":
                        self.assertEqual(expanded, {"devshard-v6-zip", "gateway-v6", "versiond-v4", "proxy-router-v5"})
        else:
            for title, count in counts.items():
                self.assertGreater(count, 0, title)
        self.assertEqual(coverage["status"], "complete")
        self.assertFalse(coverage["open_gaps"])

    def test_publisher_coverage_resolves_all_leaf_components_and_rejects_omission(self):
        output, value, groups = self.bundle(("manual-matrix", "dapi-edge"))
        manifest = artifacts.verify(output, value, groups)
        coverage = json.loads((output / artifacts.COVERAGE_ASSET).read_text())
        artifacts.validate_coverage(coverage, value, groups, manifest)
        omitted = copy.deepcopy(manifest)
        omitted["artifacts"].pop("gateway-v4.2")
        with self.assertRaisesRegex(ValueError, "omitted from computed bundle"):
            artifacts.validate_coverage(coverage, value, groups, omitted)
        wrong_source = copy.deepcopy(manifest)
        wrong_source["artifacts"]["gateway-v4.2"]["source_commit"] = "0" * 40
        with self.assertRaisesRegex(ValueError, "source binding mismatch"):
            artifacts.validate_coverage(coverage, value, groups, wrong_source)

    def test_reused_legacy_inputs_require_anonymous_pinned_image_and_zip_checks(self):
        coverage = json.loads(artifacts.COVERAGE.read_text())
        payload = b"legacy zip fixture"
        digest = hashlib.sha256(payload).hexdigest()
        for artifact_id in ("devshard-v4-zip", "devshard-v4.1-zip", "devshard-v4.2-zip", "devshard-v5-zip"):
            coverage["artifact_status"][artifact_id]["sha256"] = digest
        class Response:
            def __init__(self, data):
                self.data = data
            def __enter__(self):
                return self
            def __exit__(self, *_):
                return False
            def read(self, _size):
                chunk, self.data = self.data, b""
                return chunk
        def registry(reference, authfile, home):
            return {"oci_manifest_digest": reference.rsplit("@", 1)[1], "platform": "linux/amd64"}
        with patch.object(artifacts, "registry_identity", side_effect=registry), \
                patch.object(artifacts.urllib.request, "urlopen", side_effect=lambda *_args, **_kwargs: Response(payload)):
            artifacts.verify_reused_inputs(coverage, self.definition)
        invalid = copy.deepcopy(coverage)
        invalid["artifact_status"]["gateway-v4"]["image"] = "ghcr.io/gonka-ai/devshard-gateway:mutable"
        with patch.object(artifacts, "registry_identity", side_effect=registry), \
                patch.object(artifacts.urllib.request, "urlopen", side_effect=lambda *_args, **_kwargs: Response(payload)), \
                self.assertRaisesRegex(ValueError, "immutable registry reference"):
            artifacts.verify_reused_inputs(invalid, self.definition)

    def test_rejects_unsafe_paths_unpinned_bases_or_component_injection(self):
        original = artifacts.DEFINITION.read_text()
        changed = json.loads(original)
        changed["components"]["versiond"]["context"] = "../../outside"
        path = self.root / "bad.json"
        path.write_text(json.dumps(changed))
        with self.assertRaisesRegex(ValueError, "unsafe context"):
            artifacts.load_definition(path)
        changed = json.loads(original)
        changed["components"]["versiond"]["base_images"]["alpine:3.21"] = "latest"
        path.write_text(json.dumps(changed))
        with self.assertRaisesRegex(ValueError, "unpinned"):
            artifacts.load_definition(path)
        with self.assertRaisesRegex(ValueError, "unsupported artifact group"):
            artifacts.selected_components(self.definition, ["proxy-policy"])
        with self.assertRaisesRegex(ValueError, "manifest order"):
            artifacts.selected_components(self.definition, ["dapi-edge", "manual-matrix"])

    def test_pin_helper_rejects_unreviewed_from_and_pins_each_external_base(self):
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory) / "Dockerfile", Path(directory) / "pinned"
            source.write_text("FROM golang:1.25.9-alpine3.23 AS builder\nFROM alpine:3.23\n")
            pins = self.definition["components"]["devshard-gateway"]["base_images"]
            artifacts.run("python3", str(artifacts.ROOT / "scripts/pin-candidate-dockerfile.py"),
                          "--source", str(source), "--output", str(output), "--base-images-json", json.dumps(pins))
            self.assertIn("golang:1.25.9-alpine3.23@" + pins["golang:1.25.9-alpine3.23"], output.read_text())
            self.assertIn("alpine:3.23@" + pins["alpine:3.23"], output.read_text())
            source.write_text("FROM alpine:latest\n")
            with self.assertRaises(Exception):
                artifacts.run("python3", str(artifacts.ROOT / "scripts/pin-candidate-dockerfile.py"),
                              "--source", str(source), "--output", str(output), "--base-images-json", json.dumps(pins))

    def test_verifier_requires_exact_selected_complete_group_and_separate_digests(self):
        output, value, groups = self.bundle()
        manifest = artifacts.verify(output, value, groups)
        self.assertNotEqual(manifest["artifacts"]["devshard-gateway"]["archive_sha256"],
                            manifest["artifacts"]["devshard-gateway"]["oci_manifest_digest"][7:])
        (output / "proxy-policy.oci.tar").unlink()
        with self.assertRaisesRegex(ValueError, "file set"):
            artifacts.verify(output, value, groups)

    def test_tamper_symlink_and_wrong_group_are_rejected(self):
        output, value, groups = self.bundle()
        path = output / "versiond.oci.tar"
        path.write_bytes(path.read_bytes() + b"tamper")
        (output / artifacts.CHECKSUMS_ASSET).write_text(artifacts.checksums(output))
        with self.assertRaisesRegex(ValueError, "artifact identity mismatch|OCI manifest digest mismatch"):
            artifacts.verify(output, value, groups)
        output, value, groups = self.bundle(("dapi-edge",))
        (output / "edge-api.oci.tar").unlink()
        (output / "edge-api.oci.tar").symlink_to(output / "decentralized-api.oci.tar")
        with self.assertRaisesRegex(ValueError, "non-regular"):
            artifacts.verify(output, value, groups)

    def test_archive_traversal_and_symlinks_rejected(self):
        for unsafe in ("../escape",):
            path = self.root / "unsafe.tar"
            make_oci(path, unsafe)
            with self.subTest(unsafe=unsafe), self.assertRaisesRegex(ValueError, "unsafe OCI archive entry"):
                artifacts.verify_oci_archive(path, "test", self.definition)
        path = self.root / "symlink.tar"
        make_oci(path)
        with tarfile.open(path, "a") as archive:
            link = tarfile.TarInfo("bad-link")
            link.type = tarfile.SYMTYPE
            link.linkname = "../../outside"
            archive.addfile(link)
        with self.assertRaisesRegex(ValueError, "unsafe OCI archive entry"):
            artifacts.verify_oci_archive(path, "test", self.definition)

    def test_fetch_and_build_never_override_and_source_drift_stops_early(self):
        destination = self.root / "source"
        destination.mkdir()
        with self.assertRaisesRegex(ValueError, "already exists"):
            artifacts.fetch_source(destination, self.definition)
        with patch.object(artifacts, "run", side_effect=("0" * 40,)), self.assertRaisesRegex(ValueError, "HEAD mismatch"):
            artifacts.source_identity(destination, self.definition)

    def test_build_uses_every_manifest_context_target_pin_and_clean_docker_environment(self):
        value = copy.deepcopy(self.definition)
        value["devshard_zip"]["sha256"] = hashlib.sha256(b"published fixture").hexdigest()
        groups = ["manual-matrix", "dapi-edge"]
        source = self.root / "source"
        source.mkdir()
        output = self.root / "build-output"
        fixture = self.root / "fixture"
        fixture.mkdir()
        for name, component in value["components"].items():
            dockerfile = fixture / component["dockerfile"]
            dockerfile.parent.mkdir(parents=True, exist_ok=True)
            dockerfile.write_text("".join(f"FROM {base} AS stage{index}\n"
                                           for index, base in enumerate(component["base_images"])))
        router_entrypoint = fixture / "versiond-router/entrypoint.sh"
        router_entrypoint.write_text("#!/bin/sh\necho fixture\n")
        router_entrypoint.chmod(0o755)
        invocations = []
        clean_configs = []
        pinned_dockerfiles = {}
        router_source_mode = []
        real_subprocess_run = artifacts.subprocess.run

        def external(args, **kwargs):
            if args[0] != "docker":
                return real_subprocess_run(args, **kwargs)
            invocations.append((args, kwargs))
            if args[:3] == ["docker", "buildx", "build"]:
                clean_configs.append((set(kwargs["env"]), json.loads(
                    (Path(kwargs["env"]["DOCKER_CONFIG"]) / "config.json").read_text())))
                name = next(arg.split("name=", 1)[1].split(":", 1)[0] for arg in args if "name=" in arg)
                pinned_dockerfiles[name] = Path(args[args.index("--file") + 1]).read_text()
                if name == "versiond-router":
                    router_source_mode.append((Path(args[-1]) / "versiond-router/entrypoint.sh").stat().st_mode & 0o777)
            if args[:3] == ["docker", "buildx", "build"]:
                destination = Path(next(arg.split("dest=", 1)[1].split(",", 1)[0]
                                        for arg in args if arg.startswith("type=oci,dest=")))
                make_oci(destination)
                runtime_archive = Path(next(arg.split("dest=", 1)[1] for arg in args
                                            if arg.startswith("type=docker,dest=")))
                runtime_archive.write_bytes(b"docker archive fixture")
            return type("Result", (), {"stdout": "", "returncode": 0})()

        def command(*args, **kwargs):
            if args[:1] == ("git",) and "archive" in args:
                destination = Path(next(arg.split("=", 1)[1] for arg in args if arg.startswith("--output=")))
                with tarfile.open(destination, "w") as archive:
                    for path in fixture.rglob("*"):
                        if path.is_file():
                            archive.add(path, path.relative_to(fixture).as_posix())
                return ""
            return real_command(*args, **kwargs)

        real_command = artifacts.run

        def make_zip(destination, ignored_value):
            destination.write_bytes(b"published fixture")

        old_umask = os.umask(0o077)
        try:
            with patch.object(artifacts, "source_identity"), \
                    patch.object(artifacts, "fetch_bound_source", side_effect=lambda dest, binding: dest.mkdir()), \
                    patch.object(artifacts, "fetch_zip", side_effect=make_zip), \
                    patch.object(artifacts, "run", side_effect=command), patch.object(artifacts.subprocess, "run", side_effect=external):
                artifacts.build(source, output, value, groups)
        finally:
            os.umask(old_umask)

        builds = [(args, kwargs) for args, kwargs in invocations if args[:3] == ["docker", "buildx", "build"]]
        self.assertEqual(len(builds), len(value["components"]))
        self.assertEqual(router_source_mode, [0o755])
        create = next(args for args, _ in invocations if args[:3] == ["docker", "buildx", "create"])
        self.assertIn("image=" + value["buildkit_image"], create)
        for name, component in value["components"].items():
            args, kwargs = next((args, kwargs) for args, kwargs in builds if f"name={name}:" in " ".join(args))
            expected_context_suffix = "/source" if component["context"] == "." else f"/source/{component['context']}"
            if name == "gateway-v4.2":
                self.assertTrue(args[-1].endswith("gateway-v4.2-context"), args[-1])
                self.assertEqual(args[args.index("--target") + 1], "devshardctl-runtime")
                self.assertIn("DEVSHARD_VERSION=v4.2", args)
            else:
                self.assertTrue(args[-1].endswith(expected_context_suffix), args[-1])
            self.assertIn("--provenance=false", args)
            self.assertIn("--sbom=false", args)
            self.assertIn("--tag", args)
            self.assertTrue(any(arg.startswith("type=docker,dest=") for arg in args))
            self.assertEqual(Path(args[args.index("--file") + 1]).name, f"{name}.Dockerfile")
            for base, digest in component["base_images"].items():
                self.assertIn(f"{base}@{digest}", pinned_dockerfiles[name])
            for key, setting in component.get("build_args", {}).items():
                self.assertIn("--build-arg", args)
                self.assertIn(f"{key}={setting}", args)
            if "target" in component:
                self.assertEqual(args[args.index("--target") + 1], component["target"])
            else:
                self.assertNotIn("--target", args)
        self.assertEqual(clean_configs, [({"PATH", "DOCKER_CONFIG"}, {})] * len(value["components"]))
        self.assertEqual({path.name for path in output.iterdir()},
                         {"devshardd.zip", "artifacts.json", "coverage.json", "SHA256SUMS"} |
                         {f"{name}.oci.tar" for name in value["components"]})
        self.assertEqual({path.name for path in output.with_name(output.name + "-runtime").iterdir()},
                         {f"{name}.docker.tar" for name in value["components"]})
        artifacts.verify(output, value, groups)

    def test_ci_smoke_checks_platform_config_and_gateway_embedded_protocol(self):
        output, value, groups = self.bundle(("manual-matrix", "dapi-edge"))
        manifest = artifacts.verify(output, value, groups)
        runtime = output.with_name(output.name + "-runtime")
        runtime.mkdir()
        for name in manifest["artifacts"]:
            (runtime / f"{name}.docker.tar").write_bytes(b"runtime archive fixture")
        calls = []

        def command(*args, **kwargs):
            calls.append((args, kwargs))
            if args[:3] == ("docker", "image", "inspect"):
                name = args[-1].split(":", 1)[0]
                return value["platform"] + " " + manifest["artifacts"][name]["image_config_digest"]
            if args[:2] == ("docker", "cp"):
                Path(args[-1]).write_bytes(b"binary")
                return ""
            if args[:3] == ("go", "version", "-m"):
                if "decentralized-api" in args[-1]:
                    commit = value["source_commit"]
                    return ("-X github.com/cosmos/cosmos-sdk/version.Name=decentralized-api "
                            "-X github.com/cosmos/cosmos-sdk/version.AppName=decentralized-api "
                            f"-X github.com/cosmos/cosmos-sdk/version.Version=lab-{commit} "
                            f"-X github.com/cosmos/cosmos-sdk/version.Commit={commit}")
                version = "v4.2" if "gateway-v4.2" in args[-1] else "v6"
                return f"-X main.Version={version} -X devshard/types.buildStateRootProtocolVersion={version}"
            return ""

        with patch.object(artifacts, "run", side_effect=command), \
                patch.object(artifacts.subprocess, "run", return_value=type("Result", (), {"returncode": 0})()):
            artifacts.smoke(output, value, groups)
        self.assertEqual(sum(1 for args, _ in calls if args[:3] == ("docker", "run", "--rm")), 2)
        self.assertEqual(sum(1 for args, _ in calls if args[:3] == ("docker", "create", "--name")), 3)
        self.assertTrue(all(set(kwargs["env"]) == {"PATH", "DOCKER_CONFIG"}
                            for _, kwargs in calls if "env" in kwargs))

    def test_publisher_rejects_untrusted_context_before_external_calls(self):
        output, value, groups = self.bundle()
        with patch.dict(os.environ, {}, clear=True), patch.object(artifacts, "run") as external:
            with self.assertRaisesRegex(ValueError, "manual default-branch"):
                artifacts.publish(output, value, groups)
        external.assert_not_called()

    def test_publisher_refuses_incomplete_coverage_before_remote_mutation(self):
        output, value, groups = self.bundle(("manual-matrix", "dapi-edge"))
        revision = "a" * 40
        incomplete = self.root / "coverage-incomplete.json"
        coverage = json.loads((output / artifacts.COVERAGE_ASSET).read_text())
        coverage.update(status="incomplete", open_gaps=["fixture gap"])
        incomplete.write_text(json.dumps(coverage, sort_keys=True, indent=2) + "\n")
        (output / artifacts.COVERAGE_ASSET).write_bytes(incomplete.read_bytes())
        (output / artifacts.CHECKSUMS_ASSET).write_text(artifacts.checksums(output))
        calls = []

        def external(*args, **kwargs):
            calls.append(args)
            if args[:3] == ("git", "-C", str(artifacts.ROOT.parent)):
                return revision
            if args[:3] == ("gh", "release", "list"):
                return json.dumps([{"tagName": release_tag}])
            raise AssertionError(f"unexpected publisher action: {args}")

        environment = {"GITHUB_REPOSITORY": artifacts.REPOSITORY, "GITHUB_EVENT_NAME": "workflow_dispatch",
                       "GITHUB_REF": "refs/heads/main", "GITHUB_SHA": revision}
        with patch.dict(os.environ, environment, clear=True), patch.object(artifacts, "run", side_effect=external), \
                patch.object(artifacts, "COVERAGE", incomplete):
            with self.assertRaisesRegex(ValueError, "coverage is incomplete"):
                artifacts.publish(output, value, groups)
        self.assertEqual([call[:3] for call in calls], [
            ("git", "-C", str(artifacts.ROOT.parent))])

    def test_publisher_refuses_existing_release_tag_without_mutating_remote(self):
        output, value, groups = self.bundle(("manual-matrix", "dapi-edge"))
        revision = "a" * 40
        release_tag = f"{value['release_tag']}-manual-matrix-dapi-edge"
        calls = []

        def external(*args, **kwargs):
            calls.append(args)
            if args[:3] == ("git", "-C", str(artifacts.ROOT.parent)):
                return revision
            if args[:3] == ("gh", "release", "list"):
                return json.dumps([{"tagName": release_tag}])
            raise AssertionError(f"unexpected publisher action: {args}")

        environment = {"GITHUB_REPOSITORY": artifacts.REPOSITORY, "GITHUB_EVENT_NAME": "workflow_dispatch",
                       "GITHUB_REF": "refs/heads/main", "GITHUB_SHA": revision}
        with patch.dict(os.environ, environment, clear=True), patch.object(artifacts, "run", side_effect=external), \
                self.assertRaisesRegex(ValueError, "already exists"):
            artifacts.publish(output, value, groups)
        self.assertEqual([call[:3] for call in calls if call[:2] == ("gh", "release")],
                         [("gh", "release", "list")])

    def test_draft_release_upload_includes_machine_readable_coverage_asset(self):
        output, value, groups = self.bundle(("manual-matrix", "dapi-edge"))
        revision = "a" * 40
        calls = []

        def external(*args, **kwargs):
            calls.append(args)
            if args[:3] == ("git", "-C", str(artifacts.ROOT.parent)):
                return revision
            if args[:3] == ("gh", "release", "list"):
                return "[]"
            if args[:2] == ("gh", "api"):
                return "[]"
            if args[:3] == ("gh", "release", "download"):
                directory = Path(args[args.index("--dir") + 1])
                directory.mkdir()
                for asset in output.iterdir():
                    shutil.copy2(asset, directory / asset.name)
                return ""
            if args[:3] == ("gh", "release", "view"):
                return json.dumps({"isDraft": False, "isPrerelease": True,
                                   "url": "https://example.test/release"})
            if args[:3] in {("gh", "release", "create"), ("gh", "release", "edit")}:
                return ""
            raise AssertionError(f"unexpected mocked publication action: {args}")

        environment = {"GITHUB_REPOSITORY": artifacts.REPOSITORY, "GITHUB_EVENT_NAME": "workflow_dispatch",
                       "GITHUB_REF": "refs/heads/main", "GITHUB_SHA": revision,
                       "GH_TOKEN": "fixture-token", "GITHUB_ACTOR": "fixture-actor"}
        with patch.dict(os.environ, environment, clear=True), patch.object(artifacts, "run", side_effect=external), \
                patch.object(artifacts, "verify_reused_inputs"), patch.object(artifacts, "publish_registry"):
            artifacts.publish(output, value, groups)
        create = next(args for args in calls if args[:3] == ("gh", "release", "create"))
        self.assertIn(str(output / artifacts.COVERAGE_ASSET), create)
        uploaded = {Path(arg).name for arg in create if str(arg).startswith(str(output) + "/")}
        self.assertEqual(uploaded, {path.name for path in output.iterdir()})

    def test_registry_identity_uses_digest_without_tag_for_both_inspections(self):
        digest = "sha256:" + "a" * 64
        coverage = json.loads(artifacts.COVERAGE.read_text())
        gateway = coverage["artifact_status"]["gateway-v5"]["image"]
        cases = [
            (gateway, "ghcr.io/gonka-ai/devshard-gateway@" + gateway.split("@", 1)[1]),
            (f"postgres:16.9-bookworm@{digest}", f"postgres@{digest}"),
            (f"registry.example:5000/team/image:version@{digest}",
             f"registry.example:5000/team/image@{digest}"),
            (f"registry.example:5000/team/image@{digest}",
             f"registry.example:5000/team/image@{digest}"),
            ("ghcr.io/team/image:version", "ghcr.io/team/image:version"),
        ]
        raw = '{"schemaVersion":2}'
        config = '{"os":"linux","architecture":"amd64"}'
        authfile = self.root / "auth.json"
        for reference, expected in cases:
            with self.subTest(reference=reference), patch.object(artifacts.subprocess, "run", side_effect=[
                    artifacts.subprocess.CompletedProcess([], 0, raw, ""),
                    artifacts.subprocess.CompletedProcess([], 0, config, "")]) as external:
                identity = artifacts.registry_identity(reference, authfile, self.root)
                self.assertEqual(identity, {"oci_manifest_digest": blob(raw.encode())[0],
                                            "platform": "linux/amd64"})
                self.assertEqual([call.args[0] for call in external.call_args_list], [
                    ["skopeo", "inspect", flag, "--authfile", str(authfile), f"docker://{expected}"]
                    for flag in ("--raw", "--config")])
                for call in external.call_args_list:
                    self.assertEqual(set(call.kwargs["env"]), {"PATH", "HOME"})
                    self.assertEqual(call.kwargs["env"]["HOME"], str(self.root))

    def test_registry_identity_does_not_fall_back_after_lookup_failure(self):
        reference = "ghcr.io/team/image:version@sha256:" + "a" * 64
        for diagnostic, absent in (("manifest unknown", True), ("status code: 404", True),
                                   ("unauthorized", False), ("connection timed out", False)):
            with self.subTest(diagnostic=diagnostic), patch.object(artifacts.subprocess, "run",
                    return_value=artifacts.subprocess.CompletedProcess([], 1, "", diagnostic)) as external:
                if absent:
                    self.assertIsNone(artifacts.registry_identity(reference, self.root / "auth.json", self.root))
                else:
                    with self.assertRaisesRegex(ValueError, "identity lookup failed"):
                        artifacts.registry_identity(reference, self.root / "auth.json", self.root)
                self.assertEqual(external.call_count, 1)
                self.assertEqual(external.call_args.args[0][-1],
                                 "docker://ghcr.io/team/image@sha256:" + "a" * 64)

    def test_reused_image_digest_and_platform_mismatches_still_fail(self):
        coverage = json.loads(artifacts.COVERAGE.read_text())
        payload = b"legacy zip fixture"
        for record in coverage["artifact_status"].values():
            if "url" in record:
                record["sha256"] = hashlib.sha256(payload).hexdigest()
        for field, wrong in (("oci_manifest_digest", "sha256:" + "0" * 64), ("platform", "linux/arm64")):
            def registry(reference, authfile, home):
                identity = {"oci_manifest_digest": reference.rsplit("@", 1)[1], "platform": "linux/amd64"}
                identity[field] = wrong
                return identity
            with self.subTest(field=field), patch.object(artifacts, "registry_identity", side_effect=registry), \
                    patch.object(artifacts.urllib.request, "urlopen", side_effect=lambda *_a, **_k: io.BytesIO(payload)), \
                    self.assertRaisesRegex(ValueError, "digest/platform mismatch"):
                artifacts.verify_reused_inputs(coverage, self.definition)

    def test_registry_publisher_preflights_complete_set_and_detects_collision_before_copy(self):
        output, value, groups = self.bundle()
        manifest = artifacts.verify(output, value, groups)
        identities = iter([None for _ in range(len(manifest["artifacts"]) - 1)] + [
                           {"oci_manifest_digest": "sha256:" + "f" * 64,
                            "platform": value["platform"]}])
        calls = []

        def inspect(reference, authfile, home):
            calls.append(("inspect", reference))
            return next(identities)

        with patch.object(artifacts, "registry_identity", side_effect=inspect), \
                patch.object(artifacts.subprocess, "run", return_value=type("Result", (), {"returncode": 0})()), \
                self.assertRaisesRegex(ValueError, "collision"):
            artifacts.publish_registry(manifest, {name: output / f"{name}.oci.tar"
                                                   for name in manifest["artifacts"]}, value,
                                       self.root / "auth.json", self.root, "secret", "actor")
        self.assertFalse(any(call[0] == "copy" for call in calls))

    def test_registry_publisher_identical_existing_tags_are_idempotent_and_publicly_read(self):
        output, value, groups = self.bundle()
        manifest = artifacts.verify(output, value, groups)
        states = {}
        for name, item in manifest["artifacts"].items():
            states[item["ghcr_tag"]] = {"oci_manifest_digest": item["oci_manifest_digest"],
                                         "platform": value["platform"]}
            states[item["ghcr_digest_reference"]] = {"oci_manifest_digest": item["oci_manifest_digest"],
                                                       "platform": value["platform"]}
        calls = []

        def inspect(reference, authfile, home):
            calls.append((reference, authfile.read_text() if authfile.exists() else None))
            return states[reference]

        def external(*args, **kwargs):
            command = args[0]
            if command[1] == "login":
                Path(command[command.index("--authfile") + 1]).write_text("{}\n")
            return type("Result", (), {"returncode": 0})()

        with patch.object(artifacts, "registry_identity", side_effect=inspect), \
                patch.object(artifacts.subprocess, "run", side_effect=external) as calls_to_skopeo:
            artifacts.publish_registry(manifest, {name: output / f"{name}.oci.tar"
                                                   for name in manifest["artifacts"]}, value,
                                       self.root / "auth.json", self.root, "secret", "actor")
        self.assertEqual(calls_to_skopeo.call_count, 1)
        self.assertIn("--password-stdin", calls_to_skopeo.call_args.args[0])
        self.assertNotIn("secret", calls_to_skopeo.call_args.args[0])
        self.assertNotIn("secret", calls_to_skopeo.call_args.kwargs["env"].values())
        self.assertEqual(calls_to_skopeo.call_args.kwargs["input"], "secret\n")
        self.assertEqual(len(calls), 3 * len(manifest["artifacts"]))
        self.assertEqual(calls[-1][1], "{}\n")

    def test_registry_private_visibility_error_is_actionable_and_does_not_fall_back(self):
        output, value, groups = self.bundle()
        manifest = artifacts.verify(output, value, groups)
        states = {item["ghcr_tag"]: {"oci_manifest_digest": item["oci_manifest_digest"],
                                     "platform": value["platform"]}
                  for item in manifest["artifacts"].values()}

        def inspect(reference, authfile, home):
            if authfile.name == "anonymous-auth.json":
                raise ValueError("GHCR identity lookup failed (closed)")
            return states[reference]

        def login(*args, **kwargs):
            Path(args[0][args[0].index("--authfile") + 1]).write_text("{}\n")
            return type("Result", (), {"returncode": 0})()

        with patch.object(artifacts, "registry_identity", side_effect=inspect), \
                patch.object(artifacts.subprocess, "run", side_effect=login), \
                self.assertRaisesRegex(ValueError, "visibility may still be private.*same retained bundle.*do not rebuild"):
            artifacts.publish_registry(manifest, {name: output / f"{name}.oci.tar"
                                                   for name in manifest["artifacts"]}, value,
                                       self.root / "auth.json", self.root, "secret", "actor")

    def test_skopeo_is_publish_only_and_provisioned_in_trusted_job(self):
        dependency_manifest = (artifacts.ROOT / "dependencies/optional-commands.txt").read_text().splitlines()
        self.assertIn("skopeo", dependency_manifest)
        documentation = (artifacts.ROOT / "DEPENDENCIES.md").read_text()
        self.assertIn("skopeo", documentation)
        workflow = (artifacts.ROOT.parent / ".github/workflows/devshard-artifacts-release.yml").read_text()
        build, publish = workflow.split("  publish:\n", 1)
        self.assertNotIn("skopeo", build)
        self.assertIn("apt-get install -y skopeo", publish)
        self.assertIn("packages: write", publish)

    def test_workflow_has_separate_uncredentialed_build_and_trusted_publisher(self):
        workflow = (artifacts.ROOT.parent / ".github/workflows/devshard-artifacts-release.yml").read_text()
        build, publish = workflow.split("  publish:\n", 1)
        self.assertEqual(workflow.count("contents: write"), 1)
        self.assertIn("github.ref == 'refs/heads/main'", workflow)
        self.assertNotIn("GH_TOKEN", build)
        self.assertNotIn("devshard-artifacts-build", publish)
        self.assertIn("devshard-artifacts-fetch", build)
        self.assertIn("devshard-artifacts-publish", publish)
        self.assertIn("groups='manual-matrix dapi-edge'", build)
        self.assertIn("groups='manual-matrix dapi-edge'", publish)
        self.assertIn("apt-get install -y skopeo", publish)
        self.assertIn("packages: write", publish)
        self.assertNotIn("pull_request", workflow)
        for line in workflow.splitlines():
            if "run:" in line and "apt-get" not in line:
                self.assertIn("make -C net-deployment-runbook", line)


if __name__ == "__main__":
    unittest.main()
