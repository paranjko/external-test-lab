#!/usr/bin/env python3
"""Offline contracts for the narrow DevShard release publisher."""

import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SPEC = importlib.util.spec_from_file_location("release", Path(__file__).with_name("devshard-release.py"))
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.value = release.definition()
        self.output = self.root / "assets"
        self.output.mkdir()
        self.binary = self.root / "devshardd"
        self.binary.write_bytes(b"ELF fixture only; never executed")
        self.metadata = (
            "/temporary/devshardd: go1.25.9\n"
            "\tbuild\t-tags=muslc\n"
            "\tbuild\tGOOS=linux\n\tbuild\tGOARCH=amd64\n"
            '\tbuild\t-ldflags="-X main.Version=v6 '
            f"-X main.BinaryVersion={self.value['binary_version']} "
            '-X devshard/types.buildStateRootProtocolVersion=v6"'
        )
        # Reject every unexpected external operation, including SSH and Docker.
        self.run_mock = patch.object(release, "run", side_effect=self.fake_run).start()
        self.addCleanup(patch.stopall)
        self.calls = []

    def fake_run(self, *args, **kwargs):
        self.calls.append(args)
        if args[:3] == ("go", "version", "-m"):
            return self.metadata
        if args[:2] == ("bash", str(release.ROOT / "scripts/verify-devshard-archive.sh")):
            return "PASS mocked ELF protocol inspection"
        raise AssertionError(f"unexpected external operation: {args}")

    def package(self):
        release.package(self.binary, self.output, self.value)

    def test_definition_rejects_floating_or_inconsistent_identity(self):
        mutations = {"source_commit": "devshard-0.2.x-v6", "source_tree": "bad", "protocol": "v5",
                     "release_tag": "latest", "binary_version": "dev-log", "platform": "linux/arm64",
                     "source_repository": "someone/gonka", "classification": "official"}
        for key, changed in mutations.items():
            with self.subTest(key=key):
                value = dict(self.value, **{key: changed})
                path = self.root / "definition.json"
                path.write_text(json.dumps(value))
                with self.assertRaises(ValueError):
                    release.definition(path)

    def test_release_metadata_rejects_test_tags_and_wrong_protocol(self):
        for old, new in (("muslc", "muslc,test"), ("GOARCH=amd64", "GOARCH=arm64"),
                         ("main.Version=v6", "main.Version=v5"),
                         ("ProtocolVersion=v6", "ProtocolVersion=v5"),
                         (self.value["binary_version"], "dev-log")):
            with self.subTest(new=new), self.assertRaises(ValueError):
                release.check_metadata(self.metadata.replace(old, new), self.value)

    def test_archive_and_registry_binding(self):
        self.package()
        release.verify(self.output, self.value)
        entry = json.loads((self.output / "approved-version.json").read_text())
        self.assertEqual(entry["name"], "v6")
        self.assertEqual(entry["sha256"], release.sha256(self.output / "devshardd.zip"))
        self.assertIn(f"/{self.value['release_tag']}/devshardd.zip", entry["binary"])
        self.assertNotIn("/temporary/", (self.output / "build-info.txt").read_text())
        with zipfile.ZipFile(self.output / "devshardd.zip") as archive:
            self.assertEqual(archive.namelist(), ["devshardd"])
            self.assertEqual(archive.infolist()[0].external_attr >> 16, stat.S_IFREG | 0o755)

    def test_tampered_assets_and_unexpected_files_rejected(self):
        self.package()
        for name in sorted(release.ASSETS):
            path = self.output / name
            original = path.read_bytes()
            path.write_bytes(original + b"tamper")
            with self.subTest(asset=name), self.assertRaises((ValueError, json.JSONDecodeError)):
                release.verify(self.output, self.value)
            path.write_bytes(original)
        (self.output / "extra").touch()
        with self.assertRaisesRegex(ValueError, "asset set"):
            release.verify(self.output, self.value)

    def test_wrong_linked_protocol_rejected_even_with_matching_checksums(self):
        self.package()
        self.metadata = self.metadata.replace("main.Version=v6", "main.Version=v5")
        with self.assertRaisesRegex(ValueError, "linked identity"):
            release.verify(self.output, self.value)

    def test_no_overwrite_and_symlink_rejected(self):
        self.package()
        with self.assertRaises(FileExistsError):
            release.package(self.binary, self.output, self.value)
        (self.output / "source.json").unlink()
        (self.output / "source.json").symlink_to(self.binary)
        with self.assertRaisesRegex(ValueError, "non-regular"):
            release.verify(self.output, self.value)

    def test_source_mismatch_stops_before_build(self):
        with patch.object(release, "run", return_value="0" * 40), self.assertRaisesRegex(ValueError, "HEAD mismatch"):
            release.build(self.root, self.output, self.value)

    def test_dependencies_fail_before_build_or_publication(self):
        for command in ("fetch", "build", "verify", "publish"):
            with patch.object(release.shutil, "which", return_value=None), self.assertRaisesRegex(ValueError, "dependencies"):
                release.dependencies(command)

    def test_fetch_is_public_exact_and_refuses_existing_destinations(self):
        source = self.root / "checkout"
        commands = []

        def git(*args):
            commands.append(args)
            self.assertEqual(args[:3], ("git", "-C", str(source)))
            if args[-1] == "HEAD":
                return self.value["source_commit"]
            if args[-1] == "HEAD^{tree}":
                return self.value["source_tree"]
            return ""

        with patch.object(release, "run", side_effect=git):
            release.fetch(source, self.value)
            with self.assertRaisesRegex(ValueError, "already exists"):
                release.fetch(source, self.value)
        self.assertIn(("git", "-C", str(source), "-c", "credential.helper=", "fetch", "--no-tags", "--depth=1",
                       "https://github.com/gonka-ai/gonka.git", self.value["source_commit"]), commands)
        self.assertEqual(len(commands), 5)

    def test_publish_context_fail_closed_without_external_calls(self):
        for context in ({}, {"GITHUB_REPOSITORY": release.REPOSITORY, "GITHUB_REF": "refs/heads/topic",
                             "GITHUB_EVENT_NAME": "workflow_dispatch"}):
            with patch.dict(os.environ, context, clear=True), self.assertRaises(ValueError):
                release.publish(self.output, self.value)
        self.assertEqual(self.calls, [])

    def test_publish_order_readback_and_no_overwrite(self):
        self.package()
        context = {"GITHUB_REPOSITORY": release.REPOSITORY, "GITHUB_REF": "refs/heads/main",
                   "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_SHA": "a" * 40}
        for existing, bad_readback in ((True, False), (False, True), (False, False)):
            commands = []

            def publisher(*args, **kwargs):
                commands.append(args)
                if args[0] == "git":
                    return context["GITHUB_SHA"]
                if args[:3] == ("gh", "release", "list"):
                    return json.dumps([{"tagName": self.value["release_tag"]}] if existing else [])
                if args[:2] == ("gh", "api"):
                    return "[]"
                if args[:3] == ("gh", "release", "download"):
                    destination = Path(args[-1])
                    destination.mkdir()
                    for path in self.output.iterdir():
                        (destination / path.name).write_bytes(path.read_bytes())
                    if bad_readback:
                        (destination / "devshardd.zip").write_bytes(b"changed")
                    return ""
                if args[:3] == ("gh", "release", "view"):
                    return '{"isDraft":false,"isPrerelease":true,"url":"https://example.test/release"}'
                if args[:3] in (("gh", "release", "create"), ("gh", "release", "edit")):
                    return ""
                return self.fake_run(*args, **kwargs)

            with patch.dict(os.environ, context, clear=True), patch.object(release, "run", side_effect=publisher):
                if existing or bad_readback:
                    with self.assertRaises(ValueError):
                        release.publish(self.output, self.value)
                else:
                    release.publish(self.output, self.value)
            actions = [cmd[2] for cmd in commands if cmd[:2] == ("gh", "release")]
            self.assertEqual(actions, ["list"] if existing else
                             ["list", "create", "download"] if bad_readback else
                             ["list", "create", "download", "edit", "view"])

    def test_workflow_has_isolated_privileges_and_named_targets(self):
        workflow = (release.ROOT.parent / ".github/workflows/devshard-release.yml").read_text()
        self.assertEqual(workflow.count("contents: write"), 1)
        self.assertIn("github.ref == 'refs/heads/main'", workflow)
        build, publish = workflow.split("  build:\n", 1)[1].split("  publish:\n")
        self.assertNotIn("GH_TOKEN", build)
        self.assertNotIn("devshard-release-build", publish)
        self.assertNotIn("pull_request", workflow)
        self.assertNotIn("repository: gonka-ai/gonka", workflow)
        self.assertIn("devshard-release-fetch", build)
        self.assertIn("${{ runner.temp }}/gonka-release-source", build)
        for line in workflow.splitlines():
            if "run:" in line and "apt-get" not in line:
                self.assertIn("make -C net-deployment-runbook", line)


if __name__ == "__main__":
    unittest.main()
