"""gcheck gateway-load without Go, Docker or the network: a local git repo stands in for gonka-ai/gonka."""

import collections
import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from gonka_check import cli
from gonka_check.gateway import cli as gateway_cli
from gonka_check.gateway import report, stress
from gonka_check.gateway.gotest import GO_TEST, TEST_FILE, TEST_NAME


def checkpoint(hosts, nonce, wall, host=None):
    host = wall / 2 if host is None else host
    return {"kind": "checkpoint", "hosts": hosts, "nonce": nonce, "gateway_ms": wall - host, "host_ms": host,
            "wall_ms": wall, "heap_mb": 10.0 + nonce / 100, "elapsed_s": nonce / 10, "live": nonce - nonce // 10,
            "sealed": nonce // 10}


def summary(hosts, nonces):
    return {"kind": "summary", "hosts": hosts, "nonces": nonces, "final_nonce": nonces + hosts + 1,
            "diffs": nonces + hosts + 1, "signatures": hosts, "loop_s": 9.0, "loop_host_s": 6.0, "loop_gateway_s": 3.0,
            "state_root_ms": 1.5, "finalize_s": 0.25, "finalize_host_s": 0.2, "settlement_ms": 0.1, "state_mb": 0.5,
            "inferences_mb": 0.5, "host_stats_kb": 0.2, "diff_history_mb": 0.03, "user_cpu_s": 12.0, "sys_cpu_s": 1.0,
            "max_rss_mb": 80.0}


def events_for(hosts, nonces=40, every=20):
    events = [{"kind": "start", "hosts": hosts, "nonces": nonces, "every": every, "cpus": 4, "go": "go1.25.9"}]
    events += [checkpoint(hosts, nonce, 1.0 + nonce / 20) for nonce in range(every, nonces + 1, every)]
    return events + [summary(hosts, nonces)]


class GatewayHarness(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env = {name: os.environ.get(name) for name in ("XDG_CONFIG_HOME", "XDG_DATA_HOME")}
        os.environ["XDG_CONFIG_HOME"] = os.path.join(self.tmp.name, "config")
        os.environ["XDG_DATA_HOME"] = os.path.join(self.tmp.name, "data")

    def tearDown(self):
        for name, value in self.env.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value

    def gcheck(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(list(args))
        self.out, self.err = out.getvalue(), err.getvalue()
        return code


class GoTestTemplate(unittest.TestCase):
    def test_template_is_a_stress_test_of_the_user_package(self):
        self.assertTrue(GO_TEST.startswith("//go:build stress\n"))
        self.assertIn("\npackage user\n", GO_TEST)
        self.assertIn("func %s(t *testing.T)" % TEST_NAME, GO_TEST)
        self.assertEqual("devshard/user/gcheck_gateway_load_test.go", TEST_FILE)

    def test_template_binds_the_prompt_like_a_v5_host(self):
        self.assertIn('"max_tokens":100,', GO_TEST)
        self.assertIn("InputLength: uint64(len(prompt))", GO_TEST)

    def test_template_emits_the_events_the_parser_reads(self):
        for kind in ("start", "checkpoint", "summary"):
            self.assertIn('gcheckEmit("%s"' % kind, GO_TEST)
        self.assertIn('"GCHECK %s\\n"', GO_TEST)
        self.assertIn('"live": live,', GO_TEST)
        self.assertIn('"sealed": session.StateMachine().SealedNonceCount()', GO_TEST)

    def test_template_keeps_records_live_for_the_whole_run(self):
        self.assertIn("InferenceSealGraceSeconds: 30 * 24 * 3600,", GO_TEST)


class Runner(unittest.TestCase):
    def test_go_version_parses_go_env_output(self):
        self.assertEqual((1, 25, 9), stress.go_version("go1.25.9"))
        self.assertEqual((1, 26, 0), stress.go_version("go1.26"))
        self.assertIsNone(stress.go_version("devel"))

    def test_local_go_is_used_when_new_enough(self):
        reply = subprocess.CompletedProcess([], 0, stdout="go1.25.10\n")
        with mock.patch.object(stress.shutil, "which", lambda name: "/usr/bin/" + name), \
                mock.patch.object(stress.subprocess, "run", return_value=reply):
            self.assertEqual(("go", "go1.25.10"), stress.pick_runner("auto"))

    def test_old_go_falls_back_to_docker_or_refuses(self):
        reply = subprocess.CompletedProcess([], 0, stdout="go1.24.3\n")
        with mock.patch.object(stress.shutil, "which", lambda name: "/usr/bin/" + name), \
                mock.patch.object(stress.subprocess, "run", return_value=reply):
            self.assertEqual(("docker", stress.GO_IMAGE), stress.pick_runner("auto"))
            with self.assertRaisesRegex(stress.StressError, "older than go1.25.9"):
                stress.pick_runner("go")

    def test_nothing_to_run_with_is_an_error(self):
        with mock.patch.object(stress.shutil, "which", lambda name: None):
            with self.assertRaisesRegex(stress.StressError, "needs go1.25.9 or newer, or docker"):
                stress.pick_runner("auto")

    def test_docker_run_uses_the_prebuilt_binary_under_the_memory_cap(self):
        with tempfile.TemporaryDirectory() as tmp:
            argv, cwd, env = stress.command("docker", "/src/gonka", tmp, {"GCHECK_HOSTS": "64"}, "run-g64", 4)
        self.assertIsNone(cwd)
        self.assertIsNone(env)
        self.assertEqual(["docker", "run", "--rm", "--name", "run-g64", "--log-driver", "none"], argv[:7])
        self.assertEqual(["--memory", "4096m", "--memory-swap", "4096m"], argv[9:13])
        self.assertIn("/src/gonka:/src", argv)
        self.assertEqual("/src/devshard/user", argv[argv.index("-w") + 1])
        self.assertIn("GCHECK_HOSTS=64", argv)
        self.assertIn("GOMEMLIMIT=3686MiB", argv)
        image = argv.index(stress.GO_IMAGE)
        self.assertEqual(["/cache/bin/" + stress.BINARY, "-test.run", "^%s$" % TEST_NAME], argv[image + 1:image + 4])
        self.assertNotIn("go", argv[image + 1:])

    def test_docker_build_compiles_the_test_once_without_a_cap(self):
        with tempfile.TemporaryDirectory() as tmp:
            argv, _cwd, _env = stress.build_command("docker", "/src/gonka", tmp, "run-build")
        self.assertNotIn("--memory", argv)
        image = argv.index(stress.GO_IMAGE)
        self.assertEqual(["go", "test", "-c", "-tags", "stress", "-o", "/cache/bin/" + stress.BINARY, "./user/"],
                         argv[image + 1:])
        self.assertIn("CGO_ENABLED=0", argv)

    def test_local_build_and_run_share_the_cached_binary(self):
        with tempfile.TemporaryDirectory() as tmp:
            build, build_cwd, _env = stress.build_command("go", "/src/gonka", tmp, "x")
            run, cwd, env = stress.command("go", "/src/gonka", tmp, {"GCHECK_NONCES": "19800"}, "x", 2)
        binary = os.path.join(tmp, "bin", stress.BINARY)
        self.assertEqual(["go", "test", "-c", "-tags", "stress", "-o", binary, "./user/"], build)
        self.assertEqual("/src/gonka/devshard", build_cwd)
        self.assertEqual([binary, "-test.run", "^%s$" % TEST_NAME], run[:3])
        self.assertEqual("/src/gonka/devshard/user", cwd)
        self.assertEqual("19800", env["GCHECK_NONCES"])
        self.assertEqual("1843MiB", env["GOMEMLIMIT"])

    def test_default_cap_is_three_quarters_of_the_machine(self):
        with mock.patch.object(stress, "machine_memory_gb", return_value=7.75):
            self.assertEqual(6.0, stress.default_memory_gb())
        with mock.patch.object(stress, "machine_memory_gb", return_value=None):
            self.assertIsNone(stress.default_memory_gb())


class Source(unittest.TestCase):
    def make_upstream(self, root):
        upstream = os.path.join(root, "upstream")
        for folder in ("devshard/user", "common", "inference-chain", "proxy"):
            os.makedirs(os.path.join(upstream, folder))
            with open(os.path.join(upstream, folder, "README"), "w", encoding="utf-8") as handle:
                handle.write(folder + "\n")
        run = {"cwd": upstream, "check": True, "capture_output": True}
        subprocess.run(["git", "init", "--quiet"], **run)
        subprocess.run(["git", "add", "."], **run)
        subprocess.run(["git", "-c", "user.email=t@example.invalid", "-c", "user.name=t", "commit", "--quiet", "-m",
                        "init"], **run)
        subprocess.run(["git", "tag", stress.TAG], **run)
        commit = subprocess.run(["git", "rev-parse", "HEAD"], text=True, **run).stdout.strip()
        return "file://" + upstream, commit

    def test_sparse_checkout_of_the_tag_with_the_test_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo, commit = self.make_upstream(tmp)
            path, got = stress.prepare_source(os.path.join(tmp, "cache"), repo=repo, pinned=commit)
            self.assertEqual(commit, got)
            self.assertTrue(os.path.isdir(os.path.join(path, "inference-chain")))
            self.assertFalse(os.path.exists(os.path.join(path, "proxy")))
            with open(os.path.join(path, TEST_FILE), encoding="utf-8") as handle:
                self.assertEqual(GO_TEST, handle.read())
            again, _ = stress.prepare_source(os.path.join(tmp, "cache"), repo=repo, pinned=commit)
            self.assertEqual(path, again)

    def test_a_moved_pinned_tag_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo, _commit = self.make_upstream(tmp)
            with self.assertRaisesRegex(stress.StressError, "points to"):
                stress.prepare_source(os.path.join(tmp, "cache"), repo=repo, pinned="0" * 40)


class Outcome(unittest.TestCase):
    def run_script(self, text, tmp):
        log_path = os.path.join(tmp, "go.log")
        seen = []
        code, events, interrupted = stress.run_one([sys.executable, "-c", text], None, None, log_path, seen.append)
        with open(log_path, encoding="utf-8") as handle:
            return code, events, interrupted, seen, handle.read()

    def test_events_are_read_from_mixed_output_and_logged(self):
        lines = ["=== RUN   %s" % TEST_NAME] + ["GCHECK " + json.dumps(event) for event in events_for(16)] + ["PASS"]
        with tempfile.TemporaryDirectory() as tmp:
            code, events, interrupted, seen, log = self.run_script("print(%r)" % "\n".join(lines), tmp)
        self.assertEqual((0, False), (code, interrupted))
        self.assertEqual(["start", "checkpoint", "checkpoint", "summary"], [event["kind"] for event in events])
        self.assertEqual(events, seen)
        self.assertIn("=== RUN", log)

    def test_long_output_keeps_the_events_and_a_short_tail(self):
        events = events_for(16)
        script = "\n".join([
            "import json",
            "events = %r" % [json.dumps(event) for event in events],
            "for i in range(3000):",
            "    print('noise %d' % i)",
            "    if i % 1000 == 0:",
            "        print('GCHECK ' + events.pop(0))",
            "print('x' * 5000)",
            "print('GCHECK ' + events.pop(0))",
            "print('PASS')"])
        with tempfile.TemporaryDirectory() as tmp:
            code, got, stop, _seen, log = self.run_script(script, tmp)
        self.assertEqual((0, False), (code, stop))
        self.assertEqual(4, len(got))
        lines = log.splitlines()
        self.assertEqual(4, sum(line.startswith("GCHECK ") for line in lines))
        self.assertNotIn("noise 0", lines)
        self.assertIn("noise 2999", lines)
        self.assertEqual(2000, sum(1 for line in lines if not line.startswith("GCHECK ")))
        self.assertTrue(any(line == "x" * 2000 + " ... [3000 characters cut]" for line in lines))
        self.assertEqual("PASS", lines[-1])

    def test_a_guard_stops_the_test_with_its_reason(self):
        script = "import time\nfor i in range(2000):\n    print('line', i, flush=True)\n    time.sleep(0.01)"
        with tempfile.TemporaryDirectory() as tmp:
            log_path = os.path.join(tmp, "go.log")
            code, events, stop = stress.run_one([sys.executable, "-c", script], None, None, log_path,
                                                guard=lambda: "disk below 5% free at /data", every_s=0)
            self.assertEqual("disk below 5% free at /data", stop)
            self.assertNotEqual(0, code)
            verdict = stress.judge(16, code, events, stop, log_path)
        self.assertEqual(("INCONCLUSIVE", "disk below 5% free at /data after 0 checkpoints"),
                         (verdict["verdict"], verdict["reason"]))

    def test_disk_guard_reads_free_space(self):
        Usage = collections.namedtuple("Usage", "total used free")
        with mock.patch.object(stress.shutil, "disk_usage", return_value=Usage(100, 97, 3)):
            self.assertEqual("disk below 5% free at /data", stress.disk_guard(["/data"]))
        with mock.patch.object(stress.shutil, "disk_usage", return_value=Usage(100, 90, 10)):
            self.assertIsNone(stress.disk_guard(["/data"]))
        with mock.patch.object(stress.shutil, "disk_usage", side_effect=OSError("gone")):
            self.assertIsNone(stress.disk_guard(["/data"]))

    def test_verdicts_follow_the_go_test_outcome(self):
        with tempfile.TemporaryDirectory() as tmp:
            log_path = os.path.join(tmp, "go.log")
            with open(log_path, "w", encoding="utf-8") as handle:
                handle.write("go: downloading x\nFAIL\tdevshard/user\n")
            events = events_for(32)
            self.assertEqual("PASS", stress.judge(32, 0, events, False, log_path)["verdict"])
            failed = stress.judge(32, 1, events[:2], False, log_path)
            self.assertEqual(("FAIL", "stress_g32"), (failed["verdict"], failed["check"]))
            self.assertIn("FAIL\tdevshard/user", failed["reason"])
            self.assertEqual("BLOCKED", stress.judge(32, 1, [], False, log_path)["verdict"])
            stopped = stress.judge(32, 130, events[:2], True, log_path)
            self.assertEqual("INCONCLUSIVE", stopped["verdict"])
            self.assertIn("1 checkpoints", stopped["reason"])
            killed = stress.judge(64, 137, events[:2], False, log_path)
            self.assertEqual("FAIL", killed["verdict"])
            self.assertIn("out of memory", killed["reason"])

    def test_minutes_left_extrapolates_the_growing_time_per_nonce(self):
        first, second = checkpoint(64, 1000, 10.0), checkpoint(64, 2000, 20.0)
        self.assertAlmostEqual((1000 * 20.0 + 0.01 * 1000 * 1000 / 2) / 60000,
                               gateway_cli.minutes_left(first, second, 3000))
        self.assertEqual(0.0, gateway_cli.minutes_left(first, second, 2000))
        self.assertAlmostEqual(2000 * 10.0 / 60000, gateway_cli.minutes_left(None, first, 3000))


class Report(unittest.TestCase):
    def runs(self):
        out = []
        for hosts in (16, 64):
            events = events_for(hosts)
            out.append({"hosts": hosts, "checkpoints": [event for event in events if event["kind"] == "checkpoint"],
                        "summary": events[-1], "verdict": {"verdict": "PASS"}})
        return out

    def test_markdown_has_one_row_per_group_size(self):
        meta = {"tag": stress.TAG, "commit": stress.TAG_COMMIT, "runner": "docker (x)", "cpus": 4,
                "started_at": "2026-10-01T00:00:00Z", "every": 20}
        verdicts = [{"check": "stress_g%d" % hosts, "verdict": "PASS", "reason": "ok"} for hosts in (16, 64)]
        text = report.markdown(meta, self.runs(), verdicts, "PASS")
        self.assertIn("| G=16 | 40 | 36 | 1.00 | 1.50 | 1.50 | 3.0 | 6.0 | 0.25 |", text)
        self.assertIn("| G=64 |", text)
        self.assertIn("Overall: **PASS**.", text)
        self.assertIn("![gateway time per nonce](gateway.svg)", text)

    def test_csv_and_chart_cover_every_checkpoint(self):
        runs = self.runs()
        rows = report.checkpoints_csv(runs).splitlines()
        self.assertEqual(",".join(report.CHECKPOINT_FIELDS), rows[0])
        self.assertEqual(5, len(rows))
        self.assertTrue(rows[2].endswith(",36,4"))
        older = [{"hosts": 16, "checkpoints": [checkpoint(16, 20, 2.0)]}]
        del older[0]["checkpoints"][0]["live"], older[0]["checkpoints"][0]["sealed"]
        self.assertTrue(report.checkpoints_csv(older).splitlines()[1].endswith(",,"))
        svg = report.chart(runs)
        self.assertEqual(2, svg.count("<polyline"))
        self.assertIn("G=64", svg)
        self.assertNotIn("<polyline", report.chart([{"hosts": 8, "checkpoints": []}]))


class Cli(GatewayHarness):
    def test_bad_group_sizes_are_refused(self):
        self.assertEqual(4, self.gcheck("gateway-load", "stress", "--groups", "0"))
        self.assertEqual(4, self.gcheck("gateway-load", "stress", "--groups", "16,200"))

    def test_plan_says_where_the_code_comes_from(self):
        with mock.patch.object(stress, "pick_runner", side_effect=stress.StressError("needs docker")):
            self.assertEqual(0, self.gcheck("gateway-load", "plan"))
        self.assertIn(stress.TAG_COMMIT[:12], self.out)
        self.assertIn("runner   none: needs docker", self.out)
        self.assertIn("nothing to any Gonka network", self.out)

    def test_stress_writes_the_report_and_exits_with_the_verdict(self):
        def fake_run(argv, cwd, env, log_path, on_event=None, guard=None):
            with open(log_path, "w", encoding="utf-8") as handle:
                handle.write("ok\n")
            if "-c" in argv:
                return 0, [], False
            hosts = int(next(item.split("=")[1] for item in argv if item.startswith("GCHECK_HOSTS=")))
            events = events_for(hosts)
            for event in events:
                on_event(event)
            return 0, events, False

        with mock.patch.object(stress, "pick_runner", return_value=("docker", stress.GO_IMAGE)), \
                mock.patch.object(stress, "prepare_source", return_value=("/src/gonka", stress.TAG_COMMIT)), \
                mock.patch.object(stress, "run_one", side_effect=fake_run), \
                mock.patch.object(stress, "remove_container") as remove:
            code = self.gcheck("gateway-load", "stress", "--groups", "64,16", "--nonces", "40", "--every", "20")
        self.assertEqual(0, code)
        self.assertEqual(["g16", "g64"], [call.args[0].rsplit("-", 1)[1] for call in remove.call_args_list])
        self.assertIn("PASS         stress_g16", self.out)
        self.assertIn("about 0 min left", self.err)
        run_dir = self.out.split("written  ")[1].split(":")[0]
        for name in ("report.md", "checkpoints.csv", "gateway.svg", "host.svg", "summary.json", "manifest.json"):
            self.assertTrue(os.path.isfile(os.path.join(run_dir, name)), name)
        with open(os.path.join(run_dir, "summary.json"), encoding="utf-8") as handle:
            self.assertEqual("PASS", json.load(handle)["overall"])

    def test_a_stopped_group_size_ends_the_run_and_keeps_the_report(self):
        def fake_run(argv, cwd, env, log_path, on_event=None, guard=None):
            with open(log_path, "w", encoding="utf-8") as handle:
                handle.write("ok\n")
            if "-c" in argv:
                return 0, [], False
            hosts = int(next(item.split("=")[1] for item in argv if item.startswith("GCHECK_HOSTS=")))
            events = events_for(hosts)
            if hosts == 32:
                return -15, events[:2], "stopped: [Errno 28] No space left on device"
            return 0, events, False

        with mock.patch.object(stress, "pick_runner", return_value=("docker", stress.GO_IMAGE)), \
                mock.patch.object(stress, "prepare_source", return_value=("/src/gonka", stress.TAG_COMMIT)), \
                mock.patch.object(stress, "run_one", side_effect=fake_run), \
                mock.patch.object(stress, "remove_container") as remove:
            code = self.gcheck("gateway-load", "stress", "--groups", "16,32,64", "--nonces", "40", "--every", "20")
        self.assertEqual(2, code)
        self.assertIn("INCONCLUSIVE stress_g32    stopped: [Errno 28] No space left on device after 1 checkpoints",
                      self.out)
        self.assertNotIn("stress_g64", self.out)
        self.assertEqual(2, remove.call_count)
        self.assertIn("written  ", self.out)

    def test_a_failed_build_is_blocked_before_any_run(self):
        calls = []

        def failed_build(argv, cwd, env, log_path, on_event=None):
            calls.append(argv)
            with open(log_path, "w", encoding="utf-8") as handle:
                handle.write("user/x.go:1: undefined: y\n")
            return 1, [], False

        with mock.patch.object(stress, "pick_runner", return_value=("docker", stress.GO_IMAGE)), \
                mock.patch.object(stress, "prepare_source", return_value=("/src/gonka", stress.TAG_COMMIT)), \
                mock.patch.object(stress, "run_one", side_effect=failed_build):
            self.assertEqual(3, self.gcheck("gateway-load", "stress", "--memory", "0"))
        self.assertEqual(1, len(calls))
        self.assertIn("ready    BLOCKED", self.out)
        self.assertIn("undefined: y", self.out)
        self.assertIn("memory   no cap", self.out)

    def test_a_missing_runner_is_blocked(self):
        with mock.patch.object(stress, "pick_runner", side_effect=stress.StressError("needs docker")):
            self.assertEqual(3, self.gcheck("gateway-load", "stress", "--dry-run"))
        self.assertIn("ready    BLOCKED", self.out)


if __name__ == "__main__":
    unittest.main()
