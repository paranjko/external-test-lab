"""gcheck gateway-load stand without Docker: config files, docker argv, and the load loop against a fake gateway."""

import contextlib
import io
import json
import os
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

from gonka_check import cli
from gonka_check.gateway import cli as gateway_cli
from gonka_check.gateway import keys, report, stand, stress


class FakeGateway:
    """Status, metrics, chat and finalize of a devshardctl; each chat costs `per_request` nonces."""

    def __init__(self, cap=None, per_request=1, status=200, signatures=16, broken=False):
        self.nonce, self.cap, self.per_request, self.status = 0, cap, per_request, status
        self.signatures, self.broken = signatures, broken
        self.cpu, self.lock, self.chats = 0.0, threading.Lock(), 0
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        self.base = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, args=(0.05,), daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_exc):
        self.server.shutdown()
        self.server.server_close()

    def reply(self, method, path):
        with self.lock:
            if method == "GET" and path == "/v1/status":
                return 200, {"nonce": self.nonce, "phase": "active"}
            if method == "GET" and path == "/metrics":
                return 200, ("process_cpu_seconds_total %.2f\nprocess_resident_memory_bytes %d\n"
                             'devshard_gateway_requests_total{outcome="success"} %d\n' % (
                                 self.cpu, 64 * 2 ** 20 + self.nonce * 1024, self.chats))
            if method == "POST" and path == "/v1/chat/completions":
                if self.cap is not None and self.nonce >= self.cap:
                    return 502, {"error": "no devshard runtimes available (skipped: high_nonce=1)"}
                if self.status != 200:
                    return self.status, {"error": "failing"}
                self.nonce += self.per_request
                self.cpu += 0.002
                self.chats += 1
                return 200, {"choices": [{"message": {"content": "stub"}}]}
            if method == "POST" and path == "/v1/finalize":
                signatures = [{"slot_id": i, "signature": "x"} for i in range(self.signatures)]
                stats = [{"slot_id": i, "missed": 0, "invalid": 0, "cost": 1} for i in range(16)]
                return 200, {"nonce": self.nonce + 17, "host_stats": stats, "signatures": signatures}
        return 404, {"error": "unknown"}

    def _handler(self):
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def _serve(self, method):
                length = int(self.headers.get("Content-Length") or 0)
                if length:
                    self.rfile.read(length)
                status, body = fake.reply(method, self.path)
                data = body.encode() if isinstance(body, str) else json.dumps(body).encode()
                self.send_response(status)
                if fake.broken and self.path == "/v1/chat/completions":
                    self.send_header("Content-Length", str(len(data) + 100))
                    self.end_headers()
                    self.wfile.write(data[:5])
                    self.close_connection = True
                    return
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                self._serve("GET")

            def do_POST(self):
                self._serve("POST")

        return Handler


def summary_of(groups=16, nonce=100, ok=80, final=None, **extra):
    load = stand.Load("http://127.0.0.1:1", 1, nonce, "t")
    load.codes, load.reason = {200: ok}, "nonce %d reached" % nonce
    samples = [{"t_s": 0.0, "nonce": 0, "cpu_s": 0.0, "rss_mb": 70.0, "rx_mb": 0, "tx_mb": 0, "storage_mb": 1,
                "hosts_mem_mb": 300.0},
               {"t_s": 5.0, "nonce": nonce, "cpu_s": 0.5, "rss_mb": 80.0, "rx_mb": 1, "tx_mb": 2, "storage_mb": 2,
                "hosts_mem_mb": 350.0}]
    if final is None:
        final = {"code": 200, "seconds": 0.5, "signatures": groups, "quorum": stand.quorum(groups),
                 "host_stats": groups, "bytes": 4200, "nonce": nonce + groups + 1}
    return samples, stand.summarize(groups, 7, 8, load, samples, final, **extra)


class Config(unittest.TestCase):
    def setUp(self):
        self.names = stand.Names("20261001T000000Z-gateway-stand-ab12", 8, 3, 8)

    def test_slots_go_round_robin_over_the_hosts(self):
        data = stand.seed(8, 3, self.names)
        addresses = [keys.host(j)[1] for j in (0, 1, 2, 0, 1, 2, 0, 1)]
        self.assertEqual(addresses, data["escrows"][0]["slots"])
        self.assertEqual(["http://%s:8080" % self.names.host(j) for j in range(3)],
                         [item["inference_url"] for item in data["participants"]])
        self.assertEqual(3, len(data["hosts"]))
        self.assertEqual(keys.USER_ADDRESS, data["escrows"][0]["creator"])
        self.assertTrue(data["params"]["devshard_requests_enabled"])

    def test_escrow_and_hosts_use_the_devnet_values(self):
        escrow = stand.seed(8, 3, self.names)["escrows"][0]
        for key, value in stand.ESCROW.items():
            self.assertEqual(value, escrow[key], key)
        env = stand.host_env(1, 8, 3, self.names)
        self.assertEqual(str(30 * 24 * 3600), env["DEVSHARD_INFERENCE_SEAL_GRACE_SECONDS"])
        self.assertEqual("1000", env["DEVSHARD_FEE_PER_NONCE"])
        self.assertEqual(str(stand.AMOUNT), env["DEVSHARD_ESCROW_AMOUNT"])

    def test_each_host_lists_every_slot_key_and_peer(self):
        env = stand.host_env(2, 8, 3, self.names)
        self.assertEqual("2", env["DEVSHARD_HOST_INDEX"])
        self.assertEqual(8, len(env["DEVSHARD_HOST_PRIVATE_KEYS"].split(",")))
        self.assertEqual(keys.host(2)[0], env["DEVSHARD_HOST_PRIVATE_KEYS"].split(",")[2])
        self.assertEqual(8, len(env["DEVSHARD_PEER_URLS"].split(",")))
        self.assertEqual(keys.private_key(keys.USER_NUMBER), env["DEVSHARD_USER_PRIVATE_KEY"])

    def test_gateway_reads_the_mock_chain_of_its_stand(self):
        env = stand.gateway_env(self.names)
        self.assertEqual("%s:9090" % self.names.chain, env["DEVSHARD_CHAIN_GRPC"])
        self.assertEqual("http://%s:9191" % self.names.chain, env["DEVSHARD_PUBLIC_API"])
        self.assertEqual("false", env["DEVSHARD_ESCROW_ROTATION_ENABLED"])

    def test_up_commands_start_chain_hosts_and_a_loopback_gateway(self):
        argv = stand.up_commands(self.names, stress.TAG_COMMIT, "/cfg", "/data-dir", 3)
        self.assertEqual(["network", "create", self.names.network], argv[0])
        self.assertIn("/cfg/seed.yaml:/app/seed.yaml:ro", argv[1])
        self.assertEqual(stand.image("chain", stress.TAG_COMMIT), argv[1][-1])
        self.assertEqual(3, sum(1 for item in argv if stand.image("host", stress.TAG_COMMIT) in item))
        gateway = argv[-1]
        self.assertIn("127.0.0.1::8080", gateway)
        self.assertIn("/data-dir:/data", gateway)
        self.assertIn("--user", gateway)
        self.assertTrue(all(name.startswith(stand.PREFIX) for name in (self.names.network, self.names.gateway)))

    def test_quorum_is_two_thirds_plus_one(self):
        self.assertEqual([11, 22, 43], [stand.quorum(groups) for groups in (16, 32, 64)])

    def test_each_stand_has_its_own_names(self):
        self.assertEqual("gcheck-gw-ab12-g8-h3-c8", self.names.network)
        self.assertEqual("gcheck-gw-ab12-g8-h3-c8-host-2", self.names.host(2))

    def test_delay_goes_on_every_stub_host_through_netem(self):
        argv = stand.delay_commands(self.names, 3, 25)
        self.assertEqual(3, len(argv))
        self.assertEqual(["run", "--rm", "--network", "container:" + self.names.host(1), "--cap-add", "NET_ADMIN",
                          stand.NETEM_IMAGE, "tc", "qdisc", "add", "dev", "eth0", "root", "netem", "delay", "25ms"],
                         argv[1])

    def test_the_netem_helper_is_built_only_when_asked(self):
        missing = mock.Mock(returncode=1)
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(stand, "docker", return_value=missing), \
                mock.patch.object(stand.subprocess, "run", return_value=mock.Mock(returncode=0)) as run:
            built = stand.build_images("/src", stress.TAG_COMMIT, os.path.join(tmp, "build.log"), netem=True)
            self.assertEqual(stand.NETEM_IMAGE, built[0])
            self.assertEqual(["docker", "build", "-t", stand.NETEM_IMAGE, "-"], run.call_args_list[0][0][0])
            self.assertEqual(4, run.call_count)
            run.reset_mock()
            stand.build_images("/src", stress.TAG_COMMIT, os.path.join(tmp, "build.log"))
            self.assertEqual(3, run.call_count)


class Lists(unittest.TestCase):
    def test_hosts_take_numbers_and_g(self):
        self.assertEqual([7], gateway_cli.hosts_of("7"))
        self.assertEqual([3, 7, "G"], gateway_cli.hosts_of("7, g,3"))
        self.assertEqual(["G"], gateway_cli.hosts_of("G"))
        for bad in ("", "0", "65", "x"):
            with self.assertRaises(ValueError):
                gateway_cli.hosts_of(bad)

    def test_stands_cover_every_combination_without_more_hosts_than_slots(self):
        self.assertEqual([(16, 7, 1), (16, 7, 8), (16, 16, 1), (16, 16, 8), (64, 7, 1), (64, 7, 8), (64, 64, 1),
                          (64, 64, 8)], gateway_cli.stands_of([16, 64], [7, "G"], [1, 8]))
        self.assertEqual([(5, 5, 8)], gateway_cli.stands_of([5], [7, "G"], [8]))
        self.assertEqual([(128, 64, 8)], gateway_cli.stands_of([128], ["G"], [8]))


class Parsing(unittest.TestCase):
    def setUp(self):
        self.names = stand.Names("20261001T000000Z-gateway-stand-ab12", 8, 2, 8)

    def test_metrics_with_and_without_labels(self):
        text = 'process_cpu_seconds_total 1.25\nx{a="b"} 7\nprocess_resident_memory_bytes 7.6e+07\n'
        self.assertEqual(1.25, stand.metric(text, "process_cpu_seconds_total"))
        self.assertEqual(7.6e7, stand.metric(text, "process_resident_memory_bytes"))
        self.assertEqual(7.0, stand.metric(text, "x"))
        self.assertIsNone(stand.metric(text, "absent"))

    def test_docker_sizes(self):
        self.assertEqual(1500, stand.to_bytes("1.5kB"))
        self.assertEqual(2 * 2 ** 20, stand.to_bytes("2MiB"))
        self.assertEqual(3e9, stand.to_bytes("3GB"))
        self.assertEqual(12, stand.to_bytes("12B"))
        self.assertIsNone(stand.to_bytes("n/a"))

    def test_stats_read_gateway_traffic_and_host_memory(self):
        reply = mock.Mock(stdout="%s\t117MiB / 7.6GiB\t1.2MB / 3.4kB\n%s\t100MiB / 7.6GiB\t5MB / 5MB\n"
                                 "%s\t50MiB / 7.6GiB\t5MB / 5MB\n" % (
                                     self.names.gateway, self.names.host(0), self.names.host(1)))
        with mock.patch.object(stand, "docker", return_value=reply) as docker:
            usage = stand.stats(self.names, 2)
        self.assertEqual({"rx_mb": 1.2, "tx_mb": 0.0034, "hosts_mem_mb": 150.0}, usage)
        self.assertEqual([self.names.gateway, self.names.host(0), self.names.host(1)], docker.call_args[0][0][-3:])

    def test_exited_names_stopped_containers_and_memory(self):
        reply = mock.Mock(stdout="/%s exited 137 true\n/%s running 0 false\n/%s exited 2 false\n" % (
            self.names.gateway, self.names.chain, self.names.host(0)))
        with mock.patch.object(stand, "docker", return_value=reply):
            self.assertEqual(["%s exited 137 (out of memory)" % self.names.gateway,
                              "%s exited 2" % self.names.host(0)], stand.exited(self.names, 1))

    def test_memory_guard_reads_meminfo(self):
        with tempfile.NamedTemporaryFile("w", suffix=".meminfo", delete=False) as handle:
            handle.write("MemTotal:  8000000 kB\nMemFree:  100000 kB\nMemAvailable:  300000 kB\n")
        self.addCleanup(os.unlink, handle.name)
        with mock.patch.object(stand, "MEMINFO", handle.name):
            self.assertAlmostEqual(0.0375, stand.memory_left())
            self.assertEqual("machine memory below 5%", stand.memory_guard())
            self.assertIsNone(stand.memory_guard(floor=0.03))
        with mock.patch.object(stand, "MEMINFO", handle.name + ".absent"):
            self.assertIsNone(stand.memory_guard())


class Loop(unittest.TestCase):
    def run_load(self, fake, target, concurrency=4, **options):
        load = stand.Load(fake.base, concurrency, target, "t")
        load.run(every_s=0.05, max_s=20, **options)
        return load

    def test_load_stops_when_the_escrow_nonce_reaches_the_target(self):
        with FakeGateway(per_request=2) as fake, tempfile.TemporaryDirectory() as tmp:
            load = self.run_load(fake, 60)
            final = stand.finalize(fake.base, 16, os.path.join(tmp, "finalize.json"))
            with open(os.path.join(tmp, "finalize.json"), encoding="utf-8") as handle:
                self.assertEqual(16, len(json.load(handle)["host_stats"]))
        self.assertEqual("nonce", load.reason.split()[0])
        self.assertGreaterEqual(fake.nonce, 60)
        self.assertEqual((16, 11, 16), (final["signatures"], final["quorum"], final["host_stats"]))
        summary = stand.summarize(16, 3, 4, load, [{"t_s": 0.0, "nonce": 0, "cpu_s": 0.0, "rss_mb": 64.0},
                                                    {"t_s": 2.0, "nonce": fake.nonce, "cpu_s": fake.cpu,
                                                     "rss_mb": 65.0, "tx_mb": 1.0, "rx_mb": 0.5, "storage_mb": 3.0}],
                                  final)
        self.assertEqual(2.0, summary["nonces_per_request"])
        self.assertEqual("PASS", stand.judge(summary, 60)["verdict"])

    def test_the_gateway_nonce_cap_ends_the_run_as_expected(self):
        with FakeGateway(cap=40) as fake:
            load = self.run_load(fake, 19800)
        self.assertEqual("routing stopped at the nonce cap", load.reason)
        summary = stand.summarize(64, 7, 4, load, [{"t_s": 0, "nonce": 40, "cpu_s": 0}],
                                  {"code": 200, "seconds": 1.0, "signatures": 43, "quorum": 43})
        self.assertEqual("PASS", stand.judge(summary, 19800)["verdict"])

    def test_a_failure_streak_stops_the_run_as_a_fail(self):
        with FakeGateway(status=500) as fake:
            load = self.run_load(fake, 100)
        self.assertTrue(load.reason.startswith("50 failed requests in a row"))
        summary = stand.summarize(32, 7, 4, load, [], {"code": 200, "seconds": 1, "signatures": 32, "quorum": 22})
        self.assertEqual("FAIL", stand.judge(summary, 100)["verdict"])

    def test_a_cut_reply_counts_as_a_failed_request(self):
        with FakeGateway(broken=True) as fake:
            code, _body = stand.http("POST", fake.base + "/v1/chat/completions", {})
            load = self.run_load(fake, 10 ** 6, concurrency=2)
        self.assertEqual(0, code)
        self.assertTrue(load.reason.startswith("50 failed requests in a row, last 0"), load.reason)

    def test_a_nonce_that_stops_moving_ends_the_run(self):
        with FakeGateway(per_request=0) as fake:
            load = self.run_load(fake, 100, stall_s=0.3)
        self.assertEqual("no nonce progress for 0 s", load.reason)
        summary = stand.summarize(16, 7, 4, load, [{"t_s": 0, "nonce": 0, "cpu_s": 0}], None)
        self.assertEqual("INCONCLUSIVE", stand.judge(summary, 100)["verdict"])

    def test_the_memory_guard_stops_the_run(self):
        with FakeGateway() as fake:
            load = self.run_load(fake, 10 ** 6, guard=lambda: "machine memory below 5%")
        self.assertEqual("machine memory below 5%", load.reason)


class Verdict(unittest.TestCase):
    def test_pass_names_signatures_and_quorum(self):
        _samples, summary = summary_of(groups=32)
        verdict = stand.judge(summary, 100)
        self.assertEqual("PASS", verdict["verdict"])
        self.assertIn("32 signatures, quorum 22", verdict["reason"])

    def test_signatures_below_quorum_fail(self):
        final = {"code": 200, "seconds": 1, "signatures": 10, "quorum": 11, "host_stats": 16, "bytes": 1}
        _samples, summary = summary_of(final=final)
        self.assertEqual(("FAIL", "finalize returned 10 signatures, quorum 11"),
                         tuple(stand.judge(summary, 100)[key] for key in ("verdict", "reason")))

    def test_a_failed_finalize_carries_its_error(self):
        _samples, summary = summary_of(final={"code": 500, "seconds": 1, "error": "insufficient signatures"})
        self.assertEqual("finalize answered 500 insufficient signatures", stand.judge(summary, 100)["reason"])

    def test_a_stand_that_did_not_start_is_blocked(self):
        summary = stand.summarize(16, 7, 8, None, [], None, error="gateway not ready after 120s")
        self.assertEqual(("BLOCKED", "gateway not ready after 120s"),
                         tuple(stand.judge(summary, 100)[key] for key in ("verdict", "reason")))

    def test_a_stopped_gateway_fails_and_a_stopped_host_is_inconclusive(self):
        _samples, summary = summary_of(stopped=["gcheck-gw-ab12-g16-h7-c8-gateway exited 137 (out of memory)"])
        self.assertEqual("FAIL", stand.judge(summary, 100)["verdict"])
        self.assertIn("out of memory", stand.judge(summary, 100)["reason"])
        _samples, summary = summary_of(stopped=["gcheck-gw-ab12-g16-h7-c8-host-3 exited 137 (out of memory)"])
        self.assertEqual("INCONCLUSIVE", stand.judge(summary, 100)["verdict"])

    def test_interrupt_is_inconclusive(self):
        _samples, summary = summary_of(stop="interrupted")
        self.assertEqual("INCONCLUSIVE", stand.judge(summary, 100)["verdict"])


class Report(unittest.TestCase):
    def test_rates_count_only_the_nonces_between_samples(self):
        load = stand.Load("http://127.0.0.1:1", 1, 300, "t")
        samples = [{"t_s": 2.0, "nonce": 100, "cpu_s": 1.0}, {"t_s": 12.0, "nonce": 300, "cpu_s": 2.0}]
        summary = stand.summarize(8, 3, 1, load, samples, None)
        self.assertEqual((20.0, 5.0), (summary["nonces_per_s"], summary["cpu_ms_per_nonce"]))
        summary = stand.summarize(8, 3, 1, load, samples[:1], None)
        self.assertEqual((None, None), (summary["nonces_per_s"], summary["cpu_ms_per_nonce"]))

    def test_tables_series_and_samples(self):
        samples, summary = summary_of()
        run = {"groups": 16, "samples": samples, "summary": summary, "verdict": stand.judge(summary, 100)}
        self.assertEqual(5.0, summary["cpu_ms_per_nonce"])
        self.assertEqual(20.0, summary["tx_kb_per_nonce"])
        self.assertEqual(350.0, summary["hosts_peak_mb"])
        series = report.stand_series([run])
        self.assertEqual([{"nonce": 100, "rss_mb": 80.0, "cpu_ms": 5.0}], series[0]["checkpoints"])
        meta = {"tag": stress.TAG, "commit": stress.TAG_COMMIT, "nonces": 100}
        text = report.stand_markdown(meta, [run], [run["verdict"]], "PASS")
        self.assertIn("| stand_g16_h7_c8 | PASS |", text)
        self.assertIn("| G=16 H=7 x8 | 80 | 100 | 1.25 | 20.00 | – | – | PASS |", text)
        self.assertIn("| G=16 H=7 x8 | 5.00 | 80 | 350 | 2.0 | 20.00 | 10.00 |", text)
        self.assertIn("| G=16 H=7 x8 | 117 | 0.50 | 16 | 11 | 16 | 4.2 |", text)
        self.assertIn("Network delay added to every stub host: 0 ms.", text)
        self.assertEqual(3, len(report.samples_csv([run]).splitlines()))

    def test_a_blocked_run_still_renders(self):
        summary = stand.summarize(32, 7, 8, None, [], None, error="docker run: no space left")
        run = {"groups": 32, "samples": [], "summary": summary, "verdict": stand.judge(summary, 100)}
        meta = {"tag": stress.TAG, "commit": stress.TAG_COMMIT, "nonces": 100}
        text = report.stand_markdown(meta, [run], [run["verdict"]], "BLOCKED")
        self.assertIn("| stand_g32_h7_c8 | BLOCKED | docker run: no space left |", text)
        self.assertIn("| G=32 H=7 x8 | – | – | – | – | – | – |", text)


class Cli(unittest.TestCase):
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

    @contextlib.contextmanager
    def docker_free(self, start):
        self.downs = []
        with mock.patch.object(stress.shutil, "which", return_value="/usr/bin/docker"), \
                mock.patch.object(stress, "prepare_source", return_value=("/src/gonka", stress.TAG_COMMIT)), \
                mock.patch.object(stand, "build_images", return_value=[]), \
                mock.patch.object(stand, "start", side_effect=start), \
                mock.patch.object(stand, "down", side_effect=lambda names, hosts: self.downs.append(hosts)), \
                mock.patch.object(stand, "logs", return_value="log line\n"), \
                mock.patch.object(stand, "exited", return_value=[]), \
                mock.patch.object(stand, "memory_guard", return_value=None), \
                mock.patch.object(stand, "stats", return_value={"rx_mb": 1.0, "tx_mb": 2.0, "hosts_mem_mb": 9.0}):
            yield

    def run_dir(self):
        return self.out.split("written  ")[1].split(":")[0]

    def test_bad_lists_are_refused(self):
        self.assertEqual(4, self.gcheck("gateway-load", "stand", "--hosts", "65"))
        self.assertEqual(4, self.gcheck("gateway-load", "stand", "--concurrency", "0,8"))
        self.assertEqual(4, self.gcheck("gateway-load", "stand", "--delay-ms", "-5"))

    def test_stand_runs_every_group_size_and_cleans_up(self):
        with FakeGateway(per_request=1) as fake, self.docker_free(lambda *args: fake.base):
            code = self.gcheck("gateway-load", "stand", "--groups", "16,8", "--hosts", "3", "--concurrency", "2",
                               "--nonces", "20", "--every", "0.05")
        self.assertEqual(0, code, self.out + self.err)
        self.assertIn("PASS         stand_g8_h3_c2", self.out)
        self.assertIn("PASS         stand_g16_h3_c2", self.out)
        self.assertEqual([3, 3], self.downs)
        for name in ("report.md", "samples.csv", "stand-cpu.svg", "stand-rss.svg", "summary.json",
                     "g8-h3-c2/seed.yaml", "g8-h3-c2/host-2.env", "g8-h3-c2/gateway.env", "g16-h3-c2/gateway.log",
                     "g16-h3-c2/finalize.json"):
            self.assertTrue(os.path.isfile(os.path.join(self.run_dir(), name)), name)
        with open(os.path.join(self.run_dir(), "g8-h3-c2", "seed.yaml"), encoding="utf-8") as handle:
            self.assertEqual(8, len(json.load(handle)["escrows"][0]["slots"]))

    def test_every_host_count_and_concurrency_gets_its_stand(self):
        started = []
        with FakeGateway(per_request=1) as fake:
            def start(names, commit, config_dir, data_dir, hosts, delay_ms):
                started.append((names.base.split("-", 3)[3], hosts, delay_ms))
                return fake.base

            with self.docker_free(start):
                code = self.gcheck("gateway-load", "stand", "--groups", "8", "--hosts", "3,G", "--concurrency",
                                   "1,2", "--nonces", "10", "--every", "0.05", "--delay-ms", "20")
        self.assertEqual(0, code, self.out + self.err)
        self.assertEqual([("g8-h3-c1", 3, 20), ("g8-h3-c2", 3, 20), ("g8-h8-c1", 8, 20), ("g8-h8-c2", 8, 20)],
                         started)
        self.assertEqual([3, 3, 8, 8], self.downs)
        self.assertIn("PASS         stand_g8_h8_c2", self.out)
        with open(os.path.join(self.run_dir(), "report.md"), encoding="utf-8") as handle:
            self.assertIn("Network delay added to every stub host: 20 ms.", handle.read())

    def test_dry_run_sends_one_request_on_the_first_stand(self):
        started = []
        with FakeGateway(per_request=1) as fake:
            def start(names, *_args):
                started.append(names.base.split("-", 3)[3])
                return fake.base

            with self.docker_free(start):
                code = self.gcheck("gateway-load", "stand", "--dry-run", "--groups", "16,8", "--hosts", "3,G")
        self.assertEqual(0, code, self.out + self.err)
        self.assertEqual(["g8-h3-c1"], started)
        self.assertEqual(1, fake.chats)
        self.assertIn("ready    READY", self.out)

    def test_a_stand_that_cannot_start_keeps_the_finished_group_sizes(self):
        with FakeGateway(per_request=1) as fake:
            def start(names, *_args):
                if "-g32-" in names.base:
                    raise stand.StandError("gateway not ready after 120s")
                return fake.base

            with self.docker_free(start):
                code = self.gcheck("gateway-load", "stand", "--groups", "16,32,64", "--hosts", "3",
                                   "--concurrency", "2", "--nonces", "20", "--every", "0.05")
        self.assertEqual(3, code, self.out + self.err)
        self.assertIn("PASS         stand_g16_h3_c2", self.out)
        self.assertIn("BLOCKED      stand_g32_h3_c2    gateway not ready after 120s", self.out)
        self.assertNotIn("stand_g64", self.out)
        self.assertEqual([3, 3], self.downs)
        with open(os.path.join(self.run_dir(), "report.md"), encoding="utf-8") as handle:
            text = handle.read()
        self.assertIn("| stand_g16_h3_c2 | PASS |", text)
        self.assertIn("| stand_g32_h3_c2 | BLOCKED |", text)


if __name__ == "__main__":
    unittest.main()
