#!/usr/bin/env python3
"""Offline contract tests for the PR #1792 unified lab-release recipe."""

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
        self.assertEqual(self.candidate["source_pr"], 1792)
        self.assertEqual(self.candidate["source_commit"], "bce2388c4df1f1934c05da319a04970fb77df4c3")
        self.assertEqual(self.candidate["source_tree"], "88572681270adc4f1a6f96bfd4d953a055faf7da")
        self.assertEqual(self.candidate["release_tag"], "lab-gonka-pr-1792-bce2388c4df1")
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
                   "lab-gonka-pr-1792-bce2388c4df1/devshardd.zip",
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
        self.assertEqual(title, "DevShard v6 lab candidate · bce2388c4df1")
        self.assertIn("[Gonka PR #1792](https://github.com/gonka-ai/gonka/pull/1792)", body)
        self.assertIn("[source commit bce2388c4df1](https://github.com/gonka-ai/gonka/commit/"
                      "bce2388c4df1f1934c05da319a04970fb77df4c3)", body)
        for asset in ("devshardd.zip", "approved-version.json", "artifacts.json", "coverage.json", "source.json", "build-info.txt", "SHA256SUMS"):
            self.assertIn(f"](https://github.com/paranjko/external-test-lab/releases/download/{self.candidate['release_tag']}/{asset})", body)


if __name__ == "__main__":
    unittest.main()
