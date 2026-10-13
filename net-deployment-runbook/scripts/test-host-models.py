#!/usr/bin/env python3
"""Run the complete GDC command with real HTTP and disk persistence in a container."""
import copy
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class HostModels(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.environ.get("GDC_HOST_MODELS_FIXTURE") != "true":
            raise RuntimeError("run make test-host-models in its isolated container")
        cls.nodes = []
        cls.posts = 0
        cls.fail_post = False

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                assert self.path in ("/admin/v1/nodes", "/devshard/healthz", "/devshard/v4.1/stats/shards", "/devshard/v6/stats/shards", "/v1/epochs/latest", "/chain-api/productscience/inference/inference/params"), self.path
                if self.path == "/v1/epochs/latest" and self.server.server_port != 9000:
                    self.send_error(503, "public proxy unavailable")
                    return
                self.send_response(200)
                self.end_headers()
                value = cls.nodes if self.path == "/admin/v1/nodes" else [
                    {"name": name, "port": port, "status": "running"}
                    for name, port in (("v4.1", 5000), ("v6", 5004))]
                if self.path.endswith("/stats/shards"):
                    version = self.path.split('/')[2] if cls.versioned_proxy else "v6"
                    value = {"protocol_version": version, "cached_at": int(time.time()),
                             "cache_ttl_seconds": 60, "active_escrows": ["456"] if cls.primary_busy else [], "shards": []}
                if self.path == "/v1/epochs/latest":
                    value = cls.epoch
                if self.path == "/chain-api/productscience/inference/inference/params":
                    value = {"params": {"poc_params": {"models": [{"model_id": "Qwen/old", "dynamic_coefficient": {"target_share_bps": cls.old_share}}]}}}
                if self.path == "/devshard/healthz" and cls.reverse_inventory:
                    value = list(reversed(value))
                self.wfile.write(json.dumps(value).encode())

            def do_DELETE(self):
                prefix = "/admin/v1/nodes/"
                assert self.path.startswith(prefix), self.path
                # Match Echo's raw route-param behavior, including literal ':'.
                node_id = self.path[len(prefix):]
                found = any(n["node"]["id"] == node_id for n in cls.nodes)
                if cls.refuse_delete:
                    found = False
                    node_id = "not-a-worker"
                cls.nodes = [n for n in cls.nodes if n["node"]["id"] != node_id]
                self.send_response(200)
                self.end_headers()
                self.wfile.write(json.dumps(found).encode())

            def do_POST(self):
                assert self.path == "/admin/v1/nodes", self.path
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                cls.posts += 1
                if cls.fail_post:
                    self.send_error(500, "fixture persistence failure")
                    return
                target = next((n for n in cls.nodes if n["node"]["id"] == body["id"]), None)
                if target is None:
                    target = {"node": {"node_num": 3, "registration_seq": 2},
                              "state": {"lock_count": 0, "epoch_ml_nodes": {}, "preserved_models": {}}}
                    cls.nodes.append(target)
                target["node"].update(body)
                self.send_response(200)
                self.end_headers()
                self.wfile.write(json.dumps(body).encode())

            def log_message(self, *args):
                pass

        cls.server = http.server.HTTPServer(("127.0.0.1", 9200), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.health = http.server.HTTPServer(("127.0.0.1", 8000), Handler)
        cls.health_thread = threading.Thread(target=cls.health.serve_forever, daemon=True)
        cls.health_thread.start()
        cls.public_api = http.server.HTTPServer(("127.0.0.1", 9000), Handler)
        cls.public_thread = threading.Thread(target=cls.public_api.serve_forever, daemon=True)
        cls.public_thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
        cls.health.shutdown()
        cls.health.server_close()
        cls.health_thread.join()
        cls.public_api.shutdown()
        cls.public_api.server_close()
        cls.public_thread.join()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = {"PATH": str(self.bin) + ":/usr/local/bin:/usr/bin:/bin",
                    "HOME": str(self.root / "home"), "GDC_HOME": str(self.root / "operator"),
                    "FIXTURE_METADATA": str(self.root / "metadata.json")}
        (self.root / "home").mkdir()
        self.old = {"Qwen/old": {"args": ["--revision", "a" * 40]}}
        self.desired = dict(self.old, **{"Qwen/new": {"args": ["--revision", "b" * 40]}})
        self.models = self.root / "models.json"
        self.models.write_text(json.dumps(self.desired))
        self.plan = self.root / "plan.json"
        type(self).posts = 0
        type(self).fail_post = False
        docker = self.bin / "docker"
        docker.write_text('''#!/usr/bin/env python3
import json, os, sys, time
a=sys.argv[1:]
m=json.load(open(os.environ['FIXTURE_METADATA']))
if a == ['ps','-q','--filter','label=com.docker.compose.service=api']:
    print('fixture-api')
elif a == ['ps','-q','--filter','label=com.docker.compose.service=mlnode']:
    print('fixture-ml')
elif a == ['exec','fixture-ml','curl','-fsS','--max-time','10','http://127.0.0.1:5001/api/v1/pow/status']:
    print(json.dumps({'status':m.get('backend_status','IDLE'),'config':None,'stats':None}))
elif a == ['inspect','fixture-api']:
    print(json.dumps([{'Id':'fixture-container','Mounts':[{'Destination':'/root/node_config.json','Type':'bind','Source':m['path']}]}]))
elif a == ['exec','fixture-api','curl','-fsS','--max-time','10','http://node:26657/status']:
    print(json.dumps({'result':{'node_info':{'network':m['chain']}}}))
elif a == ['exec','fixture-api','sha256sum','/root/.dapi/cosmovisor/current/bin/decentralized-api']:
    print('c'*64+'  binary')
elif a[:7] == ['exec','fixture-container','curl','-fsS','--max-time','10','http://versiond:5000/stats/shards'] or a[:7] == ['exec','fixture-container','curl','-fsS','--max-time','10','http://versiond:5004/stats/shards']:
    old = ':5000/' in a[-1]
    print(json.dumps({'protocol_version': 'v4.1' if old else 'v6',
        'cached_at': int(time.time()) - m.get('stats_age',0), 'cache_ttl_seconds':60,
        'active_escrows':['123'] if old and m.get('busy_old_version') else [], 'shards':[]}))
else:
    raise SystemExit('unexpected Docker command: '+repr(a))
''')
        docker.chmod(0o755)
        ssh = self.bin / "ssh"
        ssh.write_text('''#!/usr/bin/env python3
import os, shlex, sys
a=sys.argv[1:]
assert a[:-1] == ['-T','-o','BatchMode=yes','-o','ConnectTimeout=10','fixture-host'], a
cmd=shlex.split(a[-1])
assert cmd[:4] == ['sudo','-n','python3','-c'] and cmd[-1] == '--remote', cmd
os.execvp('python3',cmd[2:])
''')
        ssh.chmod(0o755)

    def configure(self, layout):
        type(self).old_share = 0
        type(self).reverse_inventory = False
        type(self).versioned_proxy = layout == "deploy/fixture-host"
        type(self).epoch = {"phase": "Inference", "is_confirmation_poc_active": False,
                           "block_height": 100, "epoch_stages": {"next_poc_start": 200}}
        type(self).primary_busy = False
        type(self).refuse_delete = False
        self.path = Path("/srv/dai") / layout / "node-config.json"
        self.path.parent.mkdir(parents=True, exist_ok=True)
        node = {"id": "worker", "host": "inference", "inference_port": 5000,
                "poc_port": 8080, "max_concurrent": 64, "models": self.old}
        self.disk = [node, dict(node, id="untouched", host="other")]
        self.path.write_text(json.dumps(self.disk))
        self.before = self.path.read_bytes()
        self.inode = self.path.stat().st_ino
        type(self).nodes = [{"node": dict(copy.deepcopy(n), node_num=i + 1, registration_seq=1),
                             "state": {"lock_count": 0, "epoch_ml_nodes": {"Qwen/old": {}},
                                       "preserved_models": {}}} for i, n in enumerate(self.disk)]
        self.metadata = {"path": str(self.path), "chain": "fixture-chain-" + self.root.name}
        (self.root / "metadata.json").write_text(json.dumps(self.metadata))

    def run_gdc(self, action, *options, success=True):
        result = subprocess.run(["bash", str(ROOT / "gdc.sh"), "host", "models", action,
                                 "fixture-host", *map(str, options)], env=self.env,
                                text=True, capture_output=True, timeout=30)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def preview(self, success=True):
        return self.run_gdc("plan", "--node-id", "worker", "--models", self.models,
                            "--output", self.plan, success=success)

    def test_supported_layouts_apply_rollback(self):
        for layout in ("deploy", "node", "deploy/fixture-host"):
            with self.subTest(layout=layout):
                self.configure(layout)
                self.plan = self.root / (layout.replace("/", "-") + ".json")
                self.preview()
                self.assertEqual(self.path.read_bytes(), self.before)
                self.run_gdc("apply", "--plan", self.plan)
                data = json.loads(self.path.read_text())
                self.assertEqual(data[0]["models"], self.desired)
                self.assertEqual(data[1], self.disk[1])
                self.assertEqual(self.path.stat().st_ino, self.inode)
                # A process restart reconstructs the broker from persisted config.
                type(self).nodes[0]["node"].update(data[0])
                self.run_gdc("apply", "--plan", self.plan, success=False)
                self.run_gdc("rollback", "--plan", self.plan)
                self.assertEqual(self.path.read_bytes(), self.before)
                self.assertEqual(type(self).nodes[0]["node"]["models"], self.old)

    def test_drift_and_wrong_chain_refused_without_write(self):
        self.configure("deploy")
        self.preview()
        self.metadata["chain"] = "another-chain"
        (self.root / "metadata.json").write_text(json.dumps(self.metadata))
        self.run_gdc("apply", "--plan", self.plan, success=False)
        self.assertEqual(type(self).posts, 0)

    def test_assigned_model_cannot_be_removed(self):
        self.configure("deploy")
        self.models.write_text(json.dumps({"Qwen/new": self.desired["Qwen/new"]}))
        self.preview(success=False)
        self.assertEqual(type(self).posts, 0)

    def test_disk_drift_and_expiration_refuse_apply(self):
        self.configure("deploy")
        self.preview()
        self.path.write_bytes(self.before + b"\n")
        self.run_gdc("apply", "--plan", self.plan, success=False)
        self.path.write_bytes(self.before)
        plan = json.loads(self.plan.read_text())
        plan["created_at"] = 1
        self.plan.write_text(json.dumps(plan))
        self.run_gdc("apply", "--plan", self.plan, success=False)
        self.assertEqual(type(self).posts, 0)

    def test_rollback_refuses_new_assignment(self):
        self.configure("deploy")
        self.preview()
        self.run_gdc("apply", "--plan", self.plan)
        type(self).nodes[0]["state"]["epoch_ml_nodes"]["Qwen/new"] = {}
        self.run_gdc("rollback", "--plan", self.plan, success=False)
        self.assertEqual(type(self).posts, 1)

    def test_busy_and_unknown_schema_refuse_preview(self):
        self.configure("deploy")
        type(self).nodes[0]["state"]["lock_count"] = 1
        self.preview(success=False)
        type(self).nodes[0]["state"]["lock_count"] = 0
        type(self).nodes[0]["node"]["new_unknown_field"] = "keep"
        self.preview(success=False)
        self.assertEqual(type(self).posts, 0)

    def test_failed_post_retains_evidence_and_refuses_retry(self):
        self.configure("deploy")
        self.preview()
        type(self).fail_post = True
        self.run_gdc("apply", "--plan", self.plan, success=False)
        self.assertEqual(self.path.read_bytes(), self.before)
        self.run_gdc("apply", "--plan", self.plan, success=False)
        self.assertEqual(type(self).posts, 1)

    def transition_preview(self, success=True, retire=False):
        return self.run_gdc("plan", "--node-id", "worker:fixture", "--models", self.models,
                            "--replace-id", "new-worker", "--output", self.plan,
                            *(["--retire-preserved"] if retire else []), success=success)

    def transition_fixture(self, layout):
        self.configure(layout)
        self.disk[0]["id"] = "worker:fixture"
        type(self).nodes[0]["node"]["id"] = "worker:fixture"
        self.disk[0]["models"] = copy.deepcopy(self.desired)
        self.path.write_text(json.dumps(self.disk))
        self.before = self.path.read_bytes()
        type(self).nodes[0]["node"]["models"] = copy.deepcopy(self.desired)
        type(self).nodes[0]["state"].update(current_status="INFERENCE", poc_current_status="IDLE",
                                          admin_state={"enabled": True})
        self.models.write_text(json.dumps({"Qwen/new": self.desired["Qwen/new"]}))

    def test_worker_transition_supported_layouts(self):
        for layout in ("deploy", "node", "deploy/fixture-host"):
            with self.subTest(layout=layout):
                self.transition_fixture(layout)
                self.plan = self.root / (layout.replace("/", "-") + "-transition.json")
                self.transition_preview()
                type(self).reverse_inventory = True
                self.run_gdc("apply", "--plan", self.plan)
                disk = json.loads(self.path.read_text())
                self.assertEqual(disk[0]["id"], "new-worker")
                self.assertEqual(disk[0]["max_concurrent"], 1)
                self.assertEqual(disk[1], self.disk[1])
                self.assertEqual(self.path.stat().st_ino, self.inode)
                self.assertFalse(any(n["node"]["id"] == "worker:fixture" for n in type(self).nodes))
                self.run_gdc("apply", "--plan", self.plan, success=False)
                self.run_gdc("rollback", "--plan", self.plan, success=False)

    def test_transition_refuses_obligations_and_stale_stats(self):
        for mode in ("preserved", "lock", "poc", "old-version", "primary", "stale"):
            with self.subTest(mode=mode):
                self.transition_fixture("deploy")
                state = type(self).nodes[0]["state"]
                if mode == "preserved": state["preserved_models"] = {"Qwen/old": True}
                if mode == "lock": state["lock_count"] = 1
                if mode == "poc": state["poc_current_status"] = "GENERATING"
                if mode == "old-version": self.metadata["busy_old_version"] = True
                if mode == "primary": type(self).primary_busy = True
                if mode == "stale": self.metadata["stats_age"] = 100
                (self.root / "metadata.json").write_text(json.dumps(self.metadata))
                self.transition_preview(success=False)
                self.assertEqual(self.path.read_bytes(), self.before)
                self.assertEqual(type(self).posts, 0)

    def test_other_host_layout_refused_without_write(self):
        self.configure("deploy/another-host")
        self.preview(success=False)
        self.assertEqual(self.path.read_bytes(), self.before)
        self.assertEqual(type(self).posts, 0)

    def test_cached_validating_requires_independent_idle_proof(self):
        for layout in ("deploy", "node", "deploy/fixture-host"):
            with self.subTest(layout=layout):
                self.transition_fixture(layout)
                self.plan = self.root / (layout.replace("/", "-") + "-idle.json")
                posts_before = type(self).posts
                type(self).nodes[0]["state"]["poc_current_status"] = "VALIDATING"
                self.transition_preview()
                self.metadata["backend_status"] = "VALIDATING"
                (self.root / "metadata.json").write_text(json.dumps(self.metadata))
                self.run_gdc("apply", "--plan", self.plan, success=False)
                self.assertEqual(self.path.read_bytes(), self.before)
                self.metadata["backend_status"] = "IDLE"
                (self.root / "metadata.json").write_text(json.dumps(self.metadata))
                type(self).epoch["phase"] = "PoCGenerate"
                self.run_gdc("apply", "--plan", self.plan, success=False)
                type(self).epoch["phase"] = "Inference"
                type(self).epoch["is_confirmation_poc_active"] = True
                self.run_gdc("apply", "--plan", self.plan, success=False)
                type(self).epoch["is_confirmation_poc_active"] = False
                type(self).epoch["block_height"] = 190
                self.run_gdc("apply", "--plan", self.plan, success=False)
                self.assertEqual(type(self).posts, posts_before)
                type(self).epoch["block_height"] = 100
                self.run_gdc("apply", "--plan", self.plan)
                self.assertEqual(json.loads(self.path.read_text())[0]["id"], "new-worker")

    def test_transition_rechecks_and_retains_partial_failure(self):
        self.transition_fixture("deploy")
        self.transition_preview()
        self.metadata["busy_old_version"] = True
        (self.root / "metadata.json").write_text(json.dumps(self.metadata))
        self.run_gdc("apply", "--plan", self.plan, success=False)
        self.assertTrue(any(n["node"]["id"] == "worker:fixture" for n in type(self).nodes))
        self.metadata["busy_old_version"] = False
        (self.root / "metadata.json").write_text(json.dumps(self.metadata))
        type(self).fail_post = True
        self.run_gdc("apply", "--plan", self.plan, success=False)
        self.assertFalse(any(n["node"]["id"] == "worker:fixture" for n in type(self).nodes))
        self.assertEqual(self.path.read_bytes(), self.before)
        self.run_gdc("apply", "--plan", self.plan, success=False)
        self.assertEqual(type(self).posts, 1)

    def test_explicit_preserved_retirement_rechecks_zero_share_and_obligations(self):
        for layout in ("deploy", "node", "deploy/fixture-host"):
            with self.subTest(layout=layout):
                self.transition_fixture(layout)
                self.plan = self.root / (layout.replace("/", "-") + "-retire.json")
                state = type(self).nodes[0]["state"]
                state["preserved_models"] = {"Qwen/old": True}
                self.transition_preview(success=False)
                type(self).old_share = 1
                self.transition_preview(success=False, retire=True)
                type(self).old_share = 0
                self.transition_preview(retire=True)
                posts_before = type(self).posts
                type(self).old_share = 1
                self.run_gdc("apply", "--plan", self.plan, success=False)
                type(self).old_share = 0
                type(self).primary_busy = True
                self.run_gdc("apply", "--plan", self.plan, success=False)
                type(self).primary_busy = False
                state["lock_count"] = 1
                self.run_gdc("apply", "--plan", self.plan, success=False)
                state["lock_count"] = 0
                type(self).epoch["phase"] = "PoCGenerate"
                self.run_gdc("apply", "--plan", self.plan, success=False)
                type(self).epoch["phase"] = "Inference"
                self.assertEqual(type(self).posts, posts_before)
                self.assertEqual(self.path.read_bytes(), self.before)
                self.run_gdc("apply", "--plan", self.plan)
                self.assertEqual(json.loads(self.path.read_text())[0]["id"], "new-worker")

    def test_explicit_unchanged_retry_keeps_first_receipt(self):
        self.transition_fixture("deploy")
        self.transition_preview()
        type(self).refuse_delete = True
        self.run_gdc("apply", "--plan", self.plan, success=False)
        self.assertEqual(self.path.read_bytes(), self.before)
        type(self).refuse_delete = False
        self.run_gdc("apply", "--plan", self.plan, success=False)
        type(self).nodes[0]["node"]["registration_seq"] = 99
        self.run_gdc("apply", "--plan", self.plan, "--retry-unchanged", success=False)
        type(self).nodes[0]["node"]["registration_seq"] = 1
        self.run_gdc("apply", "--plan", self.plan, "--retry-unchanged")
        self.assertEqual(json.loads(self.path.read_text())[0]["id"], "new-worker")
        self.run_gdc("apply", "--plan", self.plan, "--retry-unchanged", success=False)


if __name__ == "__main__":
    unittest.main()
