#!/usr/bin/env python3
"""Contract tests, real running-container evidence remains a separate gate."""
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import unittest
from contextlib import redirect_stdout, redirect_stderr
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("runtime", Path(__file__).resolve().parents[1]
    / "02-node/inspect-devshard-runtime.py")
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)
CONTAINER = "a" * 64
BINARY = "b" * 64
ARCHIVE = "c" * 64
ROW = f"321\t/opt/versiond/bin/v5/devshardd\t999\t{BINARY}\n"


class RuntimeTests(unittest.TestCase):
    def execute(self, health=None, second=ROW, version="v5.0.2\n", first=ROW):
        if health is None:
            health = [{"name": "v5", "port": 5002, "status": "running"}]
        probes = iter((first, second))

        def command(*args):
            if args[:2] == ("docker", "inspect"):
                self.assertNotIn("Env", args[3])
                return f'"{CONTAINER}"\n"official@sha256:123"\ntrue\n'
            self.assertEqual(args[:3], ("docker", "exec", CONTAINER))
            if args[3] == "wget":
                return json.dumps(health)
            if args[3:] == ("sh", "-c", runtime.PROBE):
                return next(probes)
            self.assertEqual(args[-1], "/proc/321/exe")
            self.assertIn('timeout 5', args[5])
            if isinstance(version, Exception):
                raise version
            return version

        with patch.object(runtime, "command", command):
            return runtime.inspect("selected-container")

    def test_old_health_gets_real_binary_without_inventing_archive(self):
        slot = self.execute()["slots"][0]
        self.assertIsNone(slot["archive_sha256"])
        self.assertIsNone(slot["reported_binary_version"])
        self.assertEqual(slot["processes"][0]["binary_sha256"], BINARY)
        self.assertEqual(slot["processes"][0]["binary_version"], "v5.0.2")

    def test_new_health_keeps_archive_separate(self):
        slot = self.execute(health=[{"name": "v5", "port": 5002,
            "status": "running", "sha256": ARCHIVE, "binary_version": "v5.0.2"}])["slots"][0]
        self.assertEqual(slot["archive_sha256"], ARCHIVE)
        self.assertNotEqual(slot["archive_sha256"], slot["processes"][0]["binary_sha256"])

    def test_digest_addressed_layout_does_not_become_binary_digest(self):
        row = ROW.replace("v5/devshardd", f"v5/{ARCHIVE}/devshardd")
        slot = self.execute(first=row, second=row)["slots"][0]
        self.assertEqual(slot["processes"][0]["binary_sha256"], BINARY)
        self.assertIn(ARCHIVE, slot["processes"][0]["executable"])
        self.assertIsNone(slot["archive_sha256"])

    def test_non_digest_and_nested_install_paths_are_rejected(self):
        for prefix in ("not-a-digest", f"{ARCHIVE}/extra"):
            row = ROW.replace("v5/devshardd", f"v5/{prefix}/devshardd")
            with self.subTest(prefix=prefix), self.assertRaises(ValueError):
                self.execute(first=row, second=row)

    def test_missing_print_flag_never_becomes_slot_version(self):
        for value in ("v5\n", "", subprocess.CalledProcessError(2, "probe")):
            with self.subTest(value=value):
                self.assertIsNone(self.execute(version=value)["slots"][0]["processes"][0]["binary_version"])

    def test_restart_pid_reuse_and_binary_replacement_fail_closed(self):
        for second in ("", ROW.replace("321", "322"), ROW.replace("999", "1000"),
                       ROW.replace(BINARY, ARCHIVE)):
            with self.subTest(second=second), self.assertRaises(ValueError):
                self.execute(second=second)

    def test_missing_duplicate_and_disagreeing_process_fail_closed(self):
        for first, second, health in (("", "", None), (ROW * 2, ROW * 2, None),
            (ROW, ROW, [{"name": "v5", "status": "stopped"}]),
            (ROW, ROW, [{"name": "v5", "status": "running"}] * 2)):
            with self.subTest(first=first), self.assertRaises(ValueError):
                self.execute(first=first, second=second, health=health)

    def test_stopped_slot_has_no_fake_identity(self):
        slot = self.execute(health=[{"name": "v5", "status": "stopped"}],
                            first="", second="")["slots"][0]
        self.assertEqual(slot["processes"], [])

    def test_absent_v5_is_explicit_not_readiness_success(self):
        result = self.execute(health=[], first="", second="")
        self.assertIn("v5", result["absent_slots"])
        self.assertEqual(result["slots"], [])

    def test_cli_does_not_leak_failed_docker_output(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        failure = subprocess.CalledProcessError(1, "docker", output="private-fixture")
        with patch("sys.argv", ["inspect", "--container", "fixture"]), \
             patch.object(runtime, "inspect", side_effect=failure), \
             redirect_stdout(stdout), redirect_stderr(stderr):
            self.assertEqual(runtime.main(), 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertNotIn("private-fixture", stderr.getvalue())

    def test_cli_rejects_unsafe_container_before_docker(self):
        with patch("sys.argv", ["inspect", "--container", "--privileged"]), \
             patch.object(runtime, "command") as command, redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as result:
                runtime.main()
            self.assertEqual(result.exception.code, 2)
            command.assert_not_called()


if __name__ == "__main__":
    unittest.main()
