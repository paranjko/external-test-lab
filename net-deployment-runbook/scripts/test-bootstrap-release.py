#!/usr/bin/env python3
"""Real files, loopback serving and local transport fixtures; no live SSH."""
import contextlib
import functools
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import unittest
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch
from urllib.error import URLError

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "net-deployment-runbook/scripts/bootstrap-release.py"
spec = importlib.util.spec_from_file_location("release", SCRIPT)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
REVISION = "a" * 40


class Handler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="bootstrap-tests-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.prepared = self.root / "prepared"
        with contextlib.redirect_stdout(io.StringIO()):
            release.prepare(REPO, self.prepared, REVISION)
        self.manifest, self.generation = release.check(self.prepared)
        self.edge = self.root / "edge/bootstrap"
        self.edge.mkdir(parents=True)
        (self.edge / "current").mkdir()
        (self.edge / "current/old.txt").write_text("previous deployment")

    def upload(self):
        dest = self.edge / (".upload-" + os.urandom(6).hex())
        shutil.copytree(self.prepared, dest)
        return dest

    def activate(self):
        with contextlib.redirect_stdout(io.StringIO()):
            release.activate(self.edge, self.upload(), self.generation)

    def server(self, directory, handler=Handler):
        server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(handler, directory=str(directory)))
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_port}"

    def repository_copy(self):
        repo = self.root / "repository"
        for name in ("schema", "bootstrap"):
            shutil.copytree(REPO / name, repo / name)
        (repo / "net-deployment-runbook/scripts").mkdir(parents=True)
        shutil.copy2(SCRIPT.with_name("network-bootstrap.py"), repo / "net-deployment-runbook/scripts")
        return repo

    def test_prepares_all_exact_bytes_and_no_examples(self):
        self.assertEqual(len(self.manifest["files"]), 19)
        for path in (REPO / "schema").glob("*.schema.json"):
            self.assertEqual((self.prepared / "public" / path.name).read_bytes(), path.read_bytes())
        for path in (REPO / "bootstrap").glob("*.json"):
            for suffix in ("json", "env"):
                self.assertEqual((self.prepared / "public" / path.stem / ("bootstrap." + suffix)).read_bytes(),
                                 path.with_suffix("." + suffix).read_bytes())
        self.assertFalse(any("example" in name for name in self.manifest["files"]))
        with self.assertRaisesRegex(ValueError, "already exists"):
            release.prepare(REPO, self.prepared, REVISION)

    def test_new_network_and_schema_need_no_inventory_edit(self):
        repo = self.repository_copy()
        doc = json.loads((repo / "bootstrap/gonka-mainnet.json").read_text())
        doc["chain_id"] = "another-network"
        (repo / "bootstrap/another-network.json").write_text(json.dumps(doc))
        shutil.copy2(repo / "bootstrap/gonka-mainnet.env", repo / "bootstrap/another-network.env")
        schema = {"$schema": "https://json-schema.org/draft/2020-12/schema",
                  "$id": "https://gonka-dev.net/new.schema.json", "type": "string"}
        (repo / "schema/new.schema.json").write_text(json.dumps(schema))
        release.prepare(repo, self.root / "next", REVISION)
        manifest, _ = release.check(self.root / "next")
        self.assertEqual(len(manifest["files"]), 22)
        self.assertIn("another-network/bootstrap.env", manifest["files"])

    def test_stale_env_wrong_identity_duplicate_json_and_symlink_fail_before_output(self):
        repo = self.repository_copy()
        cases = [
            ("bootstrap/gonka-mainnet.env", b"stale"),
            ("bootstrap/gonka-mainnet.json", b'{"chain_id":"x","chain_id":"y"}'),
            ("schema/v1.bootstrap.schema.json", b'{"$id":"https://wrong.invalid","type":"object"}'),
        ]
        for name, invalid in cases:
            path = repo / name
            original = path.read_bytes()
            path.write_bytes(invalid)
            with self.assertRaises(ValueError):
                release.prepare(repo, self.root / "invalid", REVISION)
            self.assertFalse((self.root / "invalid").exists())
            path.write_bytes(original)
        source = repo / "bootstrap/gonka-mainnet.json"
        source.unlink()
        source.symlink_to(REPO / "bootstrap/gonka-mainnet.json")
        with self.assertRaisesRegex(ValueError, "symlink"):
            release.prepare(repo, self.root / "invalid", REVISION)
        self.assertEqual((self.edge / "current/old.txt").read_text(), "previous deployment")

    def test_activation_preserves_legacy_data_is_idempotent_and_rolls_back(self):
        self.activate()
        current = self.edge / "current"
        self.assertTrue(current.is_symlink())
        self.assertEqual(current.readlink().as_posix(), f"releases/{self.generation}/public")
        receipt = json.loads((self.edge / f"receipt-{self.generation}.json").read_text())
        self.assertEqual((self.edge / receipt["previous"] / "old.txt").read_text(), "previous deployment")
        before = current.lstat().st_ino
        self.activate()
        self.assertEqual(before, current.lstat().st_ino)
        release.rollback(self.edge, self.generation)
        self.assertEqual((current / "old.txt").read_text(), "previous deployment")
        self.assertTrue((self.edge / "releases" / self.generation).is_dir())
        with self.assertRaisesRegex(ValueError, "current changed"):
            release.rollback(self.edge, self.generation)

    def test_bad_digest_extra_file_symlink_and_expected_manifest_leave_current_untouched(self):
        for mutation in ("bytes", "extra", "symlink", "manifest"):
            upload = self.upload()
            if mutation == "bytes":
                (upload / "public/v1.bootstrap.schema.json").write_text("{}")
            elif mutation == "extra":
                (upload / "public/secret.txt").write_text("must not publish")
            elif mutation == "symlink":
                (upload / "public/unexpected").symlink_to("/tmp")
            with self.assertRaises(ValueError):
                release.activate(self.edge, upload, "b" * 64 if mutation == "manifest" else self.generation)
            self.assertFalse((self.edge / "current").is_symlink())
            self.assertEqual((self.edge / "current/old.txt").read_text(), "previous deployment")

    def test_existing_managed_release_switch_and_guarded_rollback(self):
        self.activate()
        second = self.root / "second"
        release.prepare(REPO, second, "b" * 40)
        _, generation2 = release.check(second)
        upload = self.edge / ".upload-second"
        shutil.copytree(second, upload)
        release.activate(self.edge, upload, generation2)
        with self.assertRaisesRegex(ValueError, "current changed"):
            release.rollback(self.edge, self.generation)
        release.rollback(self.edge, generation2)
        self.assertEqual((self.edge / "current").readlink().as_posix(), f"releases/{self.generation}/public")

    def test_real_public_readback_rejects_stale_missing_and_redirected_artifacts(self):
        served = self.root / "served"
        shutil.copytree(self.prepared / "public", served)
        origin = self.server(served)
        release.verify(self.prepared, origin, attempts=1)
        target = served / "gonka-mainnet/bootstrap.env"
        target.write_text("stale")
        with self.assertRaisesRegex(ValueError, r"public readback failed: gonka-mainnet/bootstrap.env; reason=content_mismatch; attempts=1"):
            release.verify(self.prepared, origin, attempts=1)
        target.unlink()
        with self.assertRaisesRegex(ValueError, r"reason=http_status=404; attempts=1"):
            release.verify(self.prepared, origin, attempts=1)
        # A directory causes SimpleHTTPServer to redirect to the trailing slash.
        target.mkdir()
        with self.assertRaisesRegex(ValueError, r"reason=redirect_refused; attempts=1"):
            release.verify(self.prepared, origin, attempts=1)

    def test_readback_reports_http_attempts_and_recovers_without_weakening_bytes_check(self):
        class RecoveringHandler(Handler):
            failures = 0

            def do_GET(self):
                if type(self).failures < 2:
                    type(self).failures += 1
                    self.send_error(503, "private upstream response must not enter diagnostics")
                    return
                super().do_GET()

        origin = self.server(self.prepared / "public", RecoveringHandler)
        errors = io.StringIO()
        with contextlib.redirect_stderr(errors), patch.object(release.time, "sleep") as sleep:
            release.verify(self.prepared, origin)
        self.assertEqual(sleep.call_count, 2)
        self.assertIn("attempt=1/3 reason=http_status=503", errors.getvalue())
        self.assertIn("attempt=2/3 reason=http_status=503", errors.getvalue())
        self.assertNotIn("private upstream", errors.getvalue())

    def test_transport_diagnostics_are_bounded_and_do_not_expose_exception_messages(self):
        private = "https://private:secret@proxy.invalid/private-token"
        cases = (
            (URLError(socket.gaierror(-2, private)), "dns_error"),
            (URLError(ssl.SSLCertVerificationError(1, private)), "tls_certificate_error"),
            (ssl.SSLError(1, private), "tls_error"),
            (TimeoutError(private), "timeout"),
            (URLError(ConnectionRefusedError(111, private)), "connection_refused"),
            (ConnectionResetError(104, private), "connection_reset"),
            (URLError(private), "transport_error type=str"),
        )
        for failure, reason in cases:
            with self.subTest(reason=reason):
                errors = io.StringIO()
                with patch.object(release, "build_opener") as factory, \
                     patch.object(release.time, "sleep") as sleep, \
                     contextlib.redirect_stderr(errors):
                    factory.return_value.open.side_effect = failure
                    with self.assertRaises(ValueError) as caught:
                        release.verify(self.prepared, "https://fixture.invalid")
                self.assertEqual(factory.return_value.open.call_count, 3)
                self.assertEqual(sleep.call_count, 2)
                self.assertIn(f"reason={reason}; attempts=3", str(caught.exception))
                self.assertIn(f"attempt=3/3 reason={reason}", errors.getvalue())
                self.assertNotIn(private, errors.getvalue() + str(caught.exception))

    def test_route_preparation_changes_only_schema_matchers_and_is_idempotent(self):
        path = self.root / "Caddyfile"
        path.write_text("handle /v1.bootstrap.schema.json {\n root * /edge/bootstrap/current\n}\n# retain other services\n")
        target = self.root / "candidate"
        release.routes(path, target)
        self.assertEqual(target.read_text(), path.read_text().replace("/v1.bootstrap.schema.json", "/*.schema.json"))
        release.routes(target, path)
        self.assertEqual(target.read_bytes(), path.read_bytes())
        path.write_text("unrecognized deployment")
        with self.assertRaisesRegex(ValueError, "route missing"):
            release.routes(path, target)

    def test_publisher_runs_actual_activation_with_transport_failures_and_rollback(self):
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        # Execute only the supplied, constrained command against our temporary tree.
        # Unknown SSH targets and rsync destinations fail; there is no real transport.
        mocks = {
            "ssh": """#!/usr/bin/env python3
import os, subprocess, sys
if "ops@fixture.invalid" not in sys.argv or os.environ.get("FAIL_TRANSPORT") == "ssh": sys.exit(91)
sys.exit(subprocess.call(sys.argv[-1], shell=True))
""",
            "rsync": """#!/usr/bin/env python3
import os, pathlib, shutil, sys
if os.environ.get("FAIL_TRANSPORT") == "rsync": sys.exit(92)
target = sys.argv[-1]
if not target.startswith("ops@fixture.invalid:"): sys.exit(93)
dest = pathlib.Path(target.split(":",1)[1])
shutil.copytree(sys.argv[-2], dest, dirs_exist_ok=True)
""",
        }
        for name, data in mocks.items():
            (bin_dir / name).write_text(data)
            (bin_dir / name).chmod(0o755)
        key = self.root / "synthetic-key"
        key.touch()
        origin = self.server(self.edge / "current")
        environment = {k: v for k, v in os.environ.items() if not k.startswith(("GDC_", "DEPLOY_", "BOOTSTRAP_"))}
        environment.update(PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
                           HOME=str(self.root), DEPLOY_PRIVATE_KEY_FILE=str(key), DEPLOY_KNOWN_HOSTS_FILE=str(key),
                           BOOTSTRAP_PUBLISH_ROOT=str(self.edge), BOOTSTRAP_PUBLIC_ORIGIN=origin)
        command = ["bash", str(SCRIPT.with_name("publish-bootstrap-release.sh")),
                   str(self.prepared), "fixture.invalid", "ops"]
        for fail in ("ssh", "rsync"):
            result = subprocess.run(command, env={**environment, "FAIL_TRANSPORT": fail}, capture_output=True, text=True, timeout=15)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((self.edge / "current/old.txt").read_text(), "previous deployment")
        # Failed public readback restores the prior tree.
        empty = self.root / "empty"
        empty.mkdir()
        result = subprocess.run(command, env={**environment, "BOOTSTRAP_PUBLIC_ORIGIN": self.server(empty)},
                                capture_output=True, text=True, timeout=20)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("restored previous", result.stdout)
        self.assertEqual((self.edge / "current/old.txt").read_text(), "previous deployment")
        result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("public bytes match all 19", result.stdout)
        # A transient readback error on a repeat must not roll back a previous successful run.
        result = subprocess.run(command, env={**environment, "BOOTSTRAP_PUBLIC_ORIGIN": self.server(empty)},
                                capture_output=True, text=True, timeout=20)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already active", result.stdout)
        self.assertEqual((self.edge / "current").readlink().as_posix(), f"releases/{self.generation}/public")

    def test_lineage_schema_requires_identity_and_trust_together(self):
        import jsonschema
        schema = json.loads((REPO / "schema/join-lineage-preflight.v1.schema.json").read_text())
        # Target the actual subschema and retain its local reference definitions.
        part = {**schema["$defs"]["bootstrap"], "$defs": schema["$defs"]}
        errors = list(jsonschema.Draft202012Validator(part).iter_errors({}))
        self.assertEqual(len(errors), 5)
        for field in ("mode", "chain_id", "genesis_sha256", "trust", "snapshot"):
            self.assertTrue(any(error.validator == "required" and repr(field) in error.message for error in errors))


if __name__ == "__main__":
    unittest.main()
