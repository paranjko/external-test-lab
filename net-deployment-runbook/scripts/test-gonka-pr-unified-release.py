#!/usr/bin/env python3
"""Offline contract tests for the reviewed v6 unified lab-release recipes."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "unified", Path(__file__).with_name("gonka-pr-unified-release.py"))
unified = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(unified)


class UnifiedReleaseTests(unittest.TestCase):
    def setUp(self):
        self.candidate = unified.definition()
        self.binary = unified.binary_definition(self.candidate)

    def test_candidate_is_exact_source_bound_and_not_a_legacy_tag(self):
        self.assertEqual(self.candidate["source_pr"], 2008)
        self.assertEqual(self.candidate["source_commit"], "d657ca0628a32d1e754e4c498d95cb1ca7b41221")
        self.assertEqual(self.candidate["source_tree"], "8c85dc7a21c9f8e16fcc6f2acbb18b7cd180e294")
        self.assertEqual(self.candidate["release_tag"], "lab-gonka-pr-2008-d657ca0628a3")
        self.assertEqual(self.binary["release_tag"], self.candidate["release_tag"])
        self.assertNotIn("lab-devshard-v6", self.candidate["release_tag"])

    def test_recipe_uses_candidate_source_but_preserves_explicit_v42_input(self):
        digest = hashlib.sha256(b"candidate zip").hexdigest()
        recipe = unified.artifact_definition(self.candidate, self.binary, digest)
        self.assertEqual(recipe["source_commit"], self.candidate["source_commit"])
        self.assertEqual(recipe["source_tree"], self.candidate["source_tree"])
        self.assertEqual(recipe["release_tag"], self.candidate["release_tag"])
        self.assertEqual(recipe["devshard_zip"], {
            "url": "https://github.com/paranjko/external-test-lab/releases/download/"
                   "lab-gonka-pr-2008-d657ca0628a3/devshardd.zip",
            "sha256": digest,
        })
        self.assertEqual(recipe["components"]["gateway-v4.2"]["source"]["commit"],
                         "b88062c9529389a61d4ba15b8b5603716a50909e")
        flags = recipe["components"]["decentralized-api"]["build_args"]["LDFLAGS"]
        self.assertIn(self.candidate["source_commit"], flags)

    def test_materialized_coverage_rebinds_candidate_and_generated_zip_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "coverage.json"
            digest = hashlib.sha256(b"candidate zip").hexdigest()
            unified.materialize_coverage(self.candidate, digest, output)
            coverage = json.loads(output.read_text())
            rendered = output.read_text()
        self.assertEqual(coverage["source"]["commit"], self.candidate["source_commit"])
        self.assertEqual(coverage["source"]["scenarios"], 24)
        self.assertEqual(coverage["source"]["expanded_cases"], 42)
        self.assertEqual(coverage["artifact_status"]["devshard-v6-zip"], {
            "status": "built", "sha256": digest, "protocol": "v6", "platform": "linux/amd64",
        })
        self.assertNotIn(self.candidate["legacy_current_source_commit"], rendered)

    def test_workflow_has_one_publisher_and_no_legacy_release_dispatch(self):
        workflow = (unified.ROOT.parent / ".github/workflows/gonka-pr-unified-release.yml").read_text()
        build, publish = workflow.split("  publish:\n", 1)
        self.assertEqual(workflow.count("contents: write"), 1)
        self.assertIn("gonka-pr-unified-release-build", build)
        self.assertNotIn("GH_TOKEN", build)
        self.assertIn("gonka-pr-unified-release-publish", publish)
        self.assertIn("packages: write", publish)
        self.assertNotIn("devshard-release-publish", workflow)
        self.assertNotIn("devshard-artifacts-publish", workflow)

    def test_generated_presentation_links_frozen_source_and_every_download(self):
        recipe = unified.artifact_definition(self.candidate, self.binary, hashlib.sha256(b"zip").hexdigest())
        manifest = {"artifacts": {name: {} for name in unified.artifacts.selected_components(recipe, unified.GROUPS)}}
        with patch.dict(os.environ, {"GITHUB_RUN_ID": "123"}, clear=False):
            title, body = unified.artifacts.unified_release_presentation(recipe, manifest, self.candidate["release_tag"])
        self.assertEqual(title, "DevShard v6 lab candidate · d657ca0628a3")
        self.assertIn("[Gonka PR #2008](https://github.com/gonka-ai/gonka/pull/2008)", body)
        self.assertIn("[source commit d657ca0628a3](https://github.com/gonka-ai/gonka/commit/"
                      "d657ca0628a32d1e754e4c498d95cb1ca7b41221)", body)
        for asset in ("devshardd.zip", "approved-version.json", "artifacts.json", "coverage.json", "source.json", "build-info.txt", "SHA256SUMS"):
            self.assertIn(f"](https://github.com/paranjko/external-test-lab/releases/download/{self.candidate['release_tag']}/{asset})", body)

    def test_presentation_uses_the_exact_six_character_binary_source_slug(self):
        candidates = (
            self.candidate,
            unified.definition(unified.ROOT / "releases/gonka-pr-1792-3c924cbf6fd9-unified.json"),
        )
        for candidate in candidates:
            with self.subTest(commit=candidate["source_commit"]):
                binary = unified.binary_definition(candidate)
                recipe = unified.artifact_definition(candidate, binary, hashlib.sha256(b"zip").hexdigest())
                manifest = {"artifacts": {name: {} for name in unified.artifacts.selected_components(recipe, unified.GROUPS)}}
                with patch.dict(os.environ, {"GITHUB_RUN_ID": "123"}, clear=False):
                    _, body = unified.artifacts.unified_release_presentation(recipe, manifest, candidate["release_tag"])
                purpose = next(line for line in body.splitlines() if "devshardd.zip" in line)
                self.assertEqual(
                    purpose,
                    f"| [devshardd.zip](https://github.com/paranjko/external-test-lab/releases/download/"
                    f"{candidate['release_tag']}/devshardd.zip) | Linux amd64 DevShard executable for protocol v6 "
                    f"`{candidate['source_commit'][:6]}`. |",
                )
                self.assertNotIn("(`devshardd`)", purpose)

    def test_previous_recipe_remains_verifiable_without_retargeting(self):
        previous = unified.definition(unified.ROOT / "releases/gonka-pr-1792-unified.json")
        self.assertEqual(previous["source_pr"], 1792)
        self.assertEqual(previous["release_tag"], "lab-gonka-pr-1792-d1b9df241306")

    def test_dispatch_can_select_the_new_immutable_1792_snapshot(self):
        with patch.dict(os.environ, {"GONKA_PR_UNIFIED_DEFINITION": "gonka-pr-1792-faab10864ba5-unified.json"}):
            candidate = unified.definition()
        self.assertEqual(candidate["source_pr"], 1792)
        self.assertEqual(candidate["source_commit"], "faab10864ba53274a3d07cbb100a698a0cdd782f")
        self.assertEqual(candidate["source_tree"], "4c44d2e4dfcae182c0312ebe1b0fe0255b120767")
        self.assertEqual(candidate["release_tag"], "lab-gonka-pr-1792-faab10864ba5")

    def test_recipe_revision_makes_a_same_source_recovery_candidate_distinct(self):
        with patch.dict(os.environ, {"GONKA_PR_UNIFIED_DEFINITION": "gonka-pr-1792-6f5c80d57142-r2-unified.json"}):
            candidate = unified.definition()
        self.assertEqual(candidate["source_commit"], "6f5c80d571420b071bd3546e1865d5acc21ec7a8")
        self.assertEqual(candidate["recipe_revision"], "r2")
        self.assertEqual(candidate["release_tag"], "lab-gonka-pr-1792-6f5c80d57142-r2")

    def test_dispatch_can_select_the_current_immutable_1792_snapshot(self):
        with patch.dict(os.environ, {"GONKA_PR_UNIFIED_DEFINITION": "gonka-pr-1792-6f5c80d57142-unified.json"}):
            candidate = unified.definition()
        self.assertEqual(candidate["source_pr"], 1792)
        self.assertEqual(candidate["source_commit"], "6f5c80d571420b071bd3546e1865d5acc21ec7a8")
        self.assertEqual(candidate["source_tree"], "3dc1103989ce3ae122c3936acd05599371025b9a")
        self.assertEqual(candidate["release_tag"], "lab-gonka-pr-1792-6f5c80d57142")

    def test_dispatch_can_select_the_latest_immutable_1792_snapshot(self):
        with patch.dict(os.environ, {"GONKA_PR_UNIFIED_DEFINITION": "gonka-pr-1792-95b95d2a03a1-unified.json"}):
            candidate = unified.definition()
        self.assertEqual(candidate["source_pr"], 1792)
        self.assertEqual(candidate["source_commit"], "95b95d2a03a136b8959fa5dd5e40c5d1f9921863")
        self.assertEqual(candidate["source_tree"], "cdebf6c0f9e44f95158cfaf326ca93c7e628c58a")
        self.assertEqual(candidate["release_tag"], "lab-gonka-pr-1792-95b95d2a03a1")

    def test_dispatch_can_select_the_peer_rpc_snapshot(self):
        with patch.dict(os.environ, {"GONKA_PR_UNIFIED_DEFINITION": "gonka-pr-1792-3c924cbf6fd9-unified.json"}):
            candidate = unified.definition()
        self.assertEqual(candidate["source_pr"], 1792)
        self.assertEqual(candidate["source_commit"], "3c924cbf6fd965d85463c1011d4261ad08882e40")
        self.assertEqual(candidate["source_tree"], "0a9ad5ad0d6ca2a9fb04d890ed3ea04fd69de7d6")
        self.assertEqual(candidate["release_tag"], "lab-gonka-pr-1792-3c924cbf6fd9")

    def test_dispatch_can_select_the_current_frozen_1792_snapshot(self):
        with patch.dict(os.environ, {"GONKA_PR_UNIFIED_DEFINITION": "gonka-pr-1792-67230e4dcc0a-unified.json"}):
            candidate = unified.definition()
        self.assertEqual(candidate["source_pr"], 1792)
        self.assertEqual(candidate["source_commit"], "67230e4dcc0afb70b9fe94f76663f2498cffb332")
        self.assertEqual(candidate["source_tree"], "23a89a386a96d254de0f67b1785420c11f0b2832")
        self.assertEqual(candidate["release_tag"], "lab-gonka-pr-1792-67230e4dcc0a")

    def test_dispatch_cannot_escape_reviewed_candidate_definitions(self):
        with patch.dict(os.environ, {"GONKA_PR_UNIFIED_DEFINITION": "../outside.json"}):
            with self.assertRaises(ValueError):
                unified.definition()

    def test_unreviewed_source_pr_and_mismatched_tag_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "candidate.json"
            for changes in ({"source_pr": 2009}, {"source_repository": "other/gonka"},
                            {"release_tag": "lab-gonka-pr-1792-d657ca0628a3"}):
                with self.subTest(changes=changes):
                    path.write_text(json.dumps({**self.candidate, **changes}))
                    with self.assertRaises(ValueError):
                        unified.definition(path)


if __name__ == "__main__":
    unittest.main()
