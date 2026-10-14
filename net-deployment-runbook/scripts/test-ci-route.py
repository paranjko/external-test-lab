#!/usr/bin/env python3
"""Contract tests for dependency-aware CI routing."""

import importlib.util
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location("route", Path(__file__).with_name("ci-route.py"))
route = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(route)


class RoutingTests(unittest.TestCase):
    def test_aggregate_accepts_intentional_skips_for_each_route(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/net-deployment-runbook.yml").read_text()
        self.assertIn("if (full) return name !== 'release-contracts';", workflow)
        self.assertIn("if (releaseOnly) return name === 'release-contracts';", workflow)
        self.assertIn("return false;", workflow)

    def test_release_only_keeps_release_contracts_without_site_preview(self):
        self.assertEqual(route.classify(["net-deployment-runbook/releases/gonka-pr-1792-unified.json"]),
                         {"release_only": True, "site_only": False, "full": False})

    def test_site_only_keeps_site_preview_without_full_runbook_suite(self):
        self.assertEqual(route.classify(["net-deployment-runbook/04-ops/site/src/app.js"]),
                         {"release_only": False, "site_only": True, "full": False})

    def test_shared_and_mixed_changes_keep_full_aggregate_suite(self):
        self.assertTrue(route.classify(["net-deployment-runbook/Makefile"])["full"])
        self.assertTrue(route.classify([
            "net-deployment-runbook/releases/gonka-pr-1792-unified.json",
            "net-deployment-runbook/04-ops/site/src/app.js",
        ])["full"])

    def test_unknown_paths_fail_closed_to_full_suite(self):
        self.assertTrue(route.classify(["net-deployment-runbook/scripts/new-helper.py"])["full"])


if __name__ == "__main__":
    unittest.main()
