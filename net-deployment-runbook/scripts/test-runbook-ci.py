#!/usr/bin/env python3
"""Check executable CI coverage and fail-closed ShellCheck partitioning."""
import collections
import functools
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@functools.cache
def dry_run(*targets):
    return subprocess.check_output(
        ["make", "--no-print-directory", "-n", *targets], cwd=ROOT, text=True
    )


def scripts(output):
    return re.findall(r"scripts/(test-[\w.-]+\.(?:sh|py|js|mjs))\b", output)


class RunbookCI(unittest.TestCase):
    def test_release_checks_execute_once_in_every_relevant_route(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("route", ROOT / "scripts/ci-route.py")
        route = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(route)
        expected = {
            "test-devshard-release.py", "test-devshard-artifacts.py",
            "test-gonka-pr-unified-release.py", "test-verify-devshard-archive.sh",
            "test-pin-candidate-dockerfile.py", "test-patch-candidate-go-mod-download.py",
        }
        workflow = (ROOT.parent / ".github/workflows/net-deployment-runbook.yml").read_text()
        release_job = workflow.split("  release-checks:\n")[1].split("  shellcheck:\n")[0]
        targets = re.search(r"run: make -C net-deployment-runbook (.+)", release_job).group(1).split()
        release_scripts = scripts(dry_run(*targets))
        group_scripts = {group: scripts(dry_run("test-ci-" + group)) for group in route.GROUPS}
        for path in sorted(route.RELEASE_FILES | {"net-deployment-runbook/releases/fixture.json"}):
            for extra in ([], ["net-deployment-runbook/04-ops/site/src/app.js"],
                          ["net-deployment-runbook/scripts/shared.sh"]):
                with self.subTest(path=path, extra=extra):
                    selected = route.plan([path, *extra])
                    counts = collections.Counter()
                    if selected["release_checks"]:
                        counts.update(release_scripts)
                    if selected["runbook_tests"]:
                        for group in selected["groups"]:
                            counts.update(group_scripts[group])
                    self.assertEqual({name: 1 for name in expected},
                                     {name: counts[name] for name in expected})
        for target in ("test", "test-ci-core"):
            counts = collections.Counter(scripts(dry_run(target)))
            self.assertEqual({name: 1 for name in expected},
                             {name: counts[name] for name in expected})

    def test_operator_budget_checks_are_triggered_and_executed(self):
        workflow = (ROOT.parent / ".github/workflows/net-deployment-runbook.yml").read_text()
        self.assertEqual(2, workflow.count("      - 'broker-ops/**'"))
        self.assertIn("test_v6_budget_rotation.py", dry_run("test-ci-gateways"))

    def test_ci_covers_local_suite_without_duplicate_tests(self):
        makefile = (ROOT / "Makefile").read_text()
        groups = re.search(r"^RUNBOOK_CI_GROUPS := (.+)$", makefile, re.M).group(1).split()
        workflow = (ROOT.parent / ".github/workflows/net-deployment-runbook.yml").read_text()
        import importlib.util
        spec = importlib.util.spec_from_file_location("route", ROOT / "scripts/ci-route.py")
        route = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(route)
        self.assertEqual(groups, route.GROUPS)
        self.assertIn("group: ${{ fromJSON(needs.route.outputs.groups) }}", workflow)
        lifecycle = workflow.split("  host-upgrade-lifecycle:\n")[1].split("  ownership:\n")[0]
        self.assertNotIn("matrix:", lifecycle)
        self.assertIn("run: make -C net-deployment-runbook test-host-upgrade-lifecycle\n", lifecycle)
        self.assertNotIn("host_upgrade_layout", makefile)
        self.assertNotIn("GDC_TEST_UPGRADE_LAYOUT", makefile)
        local = set(scripts(dry_run("test"))) - {"test-runbook-ci.py"}
        counts = collections.Counter()
        for target in [*("test-ci-" + group for group in groups), "test-gdc-p0a", "test-host-upgrade-lifecycle"]:
            counts.update(scripts(dry_run(target)))
        self.assertFalse(local - counts.keys(), f"Missing from CI: {local - counts.keys()}")
        # Each independently runnable group verifies its command baseline.
        duplicates = {name: count for name, count in counts.items()
                      if count > 1 and name != "test-command-dependency-contract.sh"}
        self.assertEqual({}, duplicates)

    def shellcheck(self, shard, count, mode="--list", **kwargs):
        return subprocess.run(
            ["bash", str(ROOT / "scripts/run-shellcheck.sh"), "fixture-image",
             str(shard), str(count), mode], cwd=ROOT, text=True,
            capture_output=True, **kwargs
        )

    def test_shellcheck_shards_cover_every_entrypoint_once(self):
        inventory = subprocess.check_output(
            ["make", "--no-print-directory", "shellcheck-files"], cwd=ROOT, text=True
        ).splitlines()
        self.assertTrue(inventory)
        for count in (1, 2, 4):
            combined = []
            for shard in range(count):
                result = self.shellcheck(shard, count)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertTrue(result.stdout.splitlines())
                combined.extend(result.stdout.splitlines())
            self.assertCountEqual(inventory, combined)

    def test_shellcheck_rejects_invalid_and_empty_shards(self):
        for shard, count in ((0, 0), (-1, 2), (2, 2), ("x", 2), (0, 9999)):
            self.assertEqual(2, self.shellcheck(shard, count).returncode)

    def test_shellcheck_propagates_failure_and_follows_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            docker = Path(directory) / "docker"
            docker.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\nexit 23\n')
            docker.chmod(0o755)
            result = self.shellcheck(0, 2, "run", env={
                **os.environ, "PATH": directory + os.pathsep + os.environ["PATH"]
            })
            self.assertEqual(23, result.returncode)
            self.assertIn("--external-sources\n", result.stdout)
            self.assertIn("--severity=warning\n", result.stdout)


if __name__ == "__main__":
    unittest.main()
