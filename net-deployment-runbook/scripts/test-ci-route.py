#!/usr/bin/env python3
"""Tests for dependency-aware CI routing."""

import importlib.util
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location("route", Path(__file__).with_name("ci-route.py"))
route = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(route)


class RoutingTests(unittest.TestCase):
    def test_workflow_routes_pushes_and_retains_rename_source(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/net-deployment-runbook.yml").read_text()
        route_job = workflow.split("  route:\n")[1].split("  release-checks:\n")[0]
        self.assertNotIn("    if:", route_job.split("    steps:")[0])
        self.assertIn("file.previous_filename", route_job)
        self.assertIn("CI_BASE: ${{ github.event.before }}", route_job)
        self.assertIn("    if: always()", workflow)
        self.assertNotIn("github.event.pull_request.draft", workflow)
        self.assertIn("host_lifecycle: ${{ steps.route.outputs.host_lifecycle }}", workflow)
        self.assertIn("  host-lifecycle:\n", workflow)
        self.assertIn("run: make -C net-deployment-runbook test-host-lifecycle", workflow)
        self.assertNotIn("p0a", workflow.lower())

    def test_selected_jobs_for_independent_changes(self):
        result = route.plan(["net-deployment-runbook/releases/a.json", "README.md"])
        self.assertEqual(["release-checks"], result["required"])
        self.assertEqual([], result["groups"])
        self.assertEqual(["release-checks", "shellcheck"], route.plan([
            "net-deployment-runbook/scripts/verify-devshard-archive.sh"])["required"])
        result = route.plan(["net-deployment-runbook/04-ops/site/src/app.js"])
        self.assertEqual(["bootstrap", "core", "site"], result["groups"])
        self.assertTrue(result["public_edge_integration"])
        self.assertFalse(result["host_upgrade_lifecycle"])
        self.assertEqual([], route.plan(["README.md", "reports/month.md"])["required"])

    def test_documentation_keeps_checks_without_host_upgrade(self):
        result = route.plan(["net-deployment-runbook/ROLE-JOIN.md"])
        self.assertEqual(route.GROUPS, result["groups"])
        self.assertFalse(result["host_upgrade_lifecycle"])
        self.assertFalse(result["shellcheck"])

    def test_release_helpers_and_their_tests_use_the_narrow_route(self):
        for helper in ("verify-devshard-archive.sh", "pin-candidate-dockerfile.py",
                       "patch-candidate-go-mod-download.py"):
            for name in (helper, "test-" + helper):
                with self.subTest(name=name):
                    result = route.plan(["net-deployment-runbook/scripts/" + name])
                    self.assertEqual([], result["groups"])
                    expected = {"release-checks"}
                    if name.endswith(".sh"):
                        expected.add("shellcheck")
                    self.assertEqual(expected, set(result["required"]))

    def test_full_fallback_and_manual_run(self):
        for paths in ([], ["net-deployment-runbook/Makefile"],
                      ["net-deployment-runbook/scripts/new.py"],
                      ["net-deployment-runbook/scripts/lib-lock.sh"],
                      ["bootstrap/network.json"], ["install_inferenced.sh"],
                      [".github/workflows/net-deployment-runbook.yml"]):
            with self.subTest(paths=paths):
                self.assertEqual(set(route.JOBS) - {"release-checks"}, set(route.plan(paths)["required"]))
        self.assertTrue(route.plan(["README.md"], force_full=True)["host_upgrade_lifecycle"])

    def test_gate_rejects_incomplete_jobs_and_failed_routing(self):
        spec = importlib.util.spec_from_file_location("gate", Path(__file__).with_name("ci-result.py"))
        gate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gate)
        for status in ("failure", "cancelled", "skipped", None):
            for name in route.JOBS:
                with self.subTest(status=status, name=name), self.assertRaises(ValueError):
                    gate.verify({"route": {"result": "success"}, name: {"result": status}}, [name])
            with self.assertRaises(ValueError):
                gate.verify({"route": {"result": status}}, [])
        with self.assertRaises(ValueError):
            gate.verify({"route": {"result": "success"}}, ["missing"])
        for paths in (["README.md"], ["net-deployment-runbook/releases/a.json"], []):
            selected = route.plan(paths)["required"]
            needs = {name: {"result": "success" if name in selected else "skipped"} for name in route.JOBS}
            needs["route"] = {"result": "success"}
            gate.verify(needs, selected)

    def test_git_rename_and_unavailable_base(self):
        import subprocess
        import tempfile
        command = ["python3", str(Path(__file__).with_name("ci-route.py").resolve())]
        with tempfile.TemporaryDirectory() as directory:
            def git(*args):
                return subprocess.check_output(["git", "-C", directory, *args], text=True).strip()
            git("init", "-q")
            git("config", "user.name", "CI fixture")
            git("config", "user.email", "ci@example.invalid")
            old = Path(directory) / "net-deployment-runbook/scripts/shared.py"
            old.parent.mkdir(parents=True)
            old.write_text("shared\n")
            git("add", ".")
            git("-c", "commit.gpgsign=false", "commit", "-qm", "base")
            base = git("rev-parse", "HEAD")
            new = Path(directory) / "net-deployment-runbook/releases/moved.json"
            new.parent.mkdir(parents=True)
            old.rename(new)
            git("add", ".")
            git("-c", "commit.gpgsign=false", "commit", "-qm", "rename")
            for ref in (base, "missing-base", "0" * 40):
                result = subprocess.run(command + ["--base", ref], cwd=directory, text=True, capture_output=True)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertIn("host_upgrade_lifecycle=true", result.stdout)
            invalid = Path(directory) / "invalid.json"
            invalid.write_text('{"not": "a list"}')
            self.assertNotEqual(0, subprocess.run(command + ["--changed-files", str(invalid)], capture_output=True).returncode)

    def test_mixed_independent_domains_take_union_not_full_suite(self):
        result = route.plan(["net-deployment-runbook/releases/a.json",
                             "net-deployment-runbook/04-ops/site/src/app.js"])
        self.assertEqual(["bootstrap", "core", "site"], result["groups"])
        self.assertFalse(result["host_upgrade_lifecycle"])


if __name__ == "__main__":
    unittest.main()
