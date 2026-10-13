#!/usr/bin/env python3
"""Check executable CI coverage and fail-closed ShellCheck partitioning."""
import collections
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def dry_run(*targets):
    return subprocess.check_output(
        ["make", "--no-print-directory", "-n", *targets], cwd=ROOT, text=True
    )


def scripts(output):
    return re.findall(r"scripts/(test-[\w.-]+\.(?:sh|py|js|mjs))\b", output)


class RunbookCI(unittest.TestCase):
    def test_ci_covers_local_suite_without_duplicate_tests(self):
        makefile = (ROOT / "Makefile").read_text()
        groups = re.search(r"^RUNBOOK_CI_GROUPS := (.+)$", makefile, re.M).group(1).split()
        workflow = (ROOT.parent / ".github/workflows/net-deployment-runbook.yml").read_text()
        matrix = re.search(r"group: \[([^\]]+)\]", workflow).group(1)
        self.assertEqual(groups, [part.strip() for part in matrix.split(",")])
        local = set(scripts(dry_run("test"))) - {"test-runbook-ci.py"}
        counts = collections.Counter()
        for target in [*("test-ci-" + group for group in groups), "test-gdc-p0a"]:
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
