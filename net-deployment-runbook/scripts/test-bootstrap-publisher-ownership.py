#!/usr/bin/env python3
"""Linux root-only regression: real directory ownership, no host deployment."""
import hashlib
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import sys
import tempfile
import unittest


class OwnershipTests(unittest.TestCase):
    def setUp(self):
        self.account = pwd.getpwnam("nobody")
        self.assertNotEqual(self.account.pw_uid, 0)
        self.tmp = tempfile.TemporaryDirectory(prefix="bootstrap-ownership-")
        self.addCleanup(self.tmp.cleanup)
        self.fixture = Path(self.tmp.name)
        self.fixture.chmod(0o755)
        self.script = self.fixture / "bootstrap-release.py"
        shutil.copyfile(Path(__file__).with_name("bootstrap-release.py"), self.script)
        self.script.chmod(0o644)
        self.root = self.fixture / "bootstrap"
        self.root.mkdir(mode=0o755)
        self.current = self.root / "current"

    def command(self, *args, publisher=False):
        identity = {}
        if publisher:
            identity = dict(user=self.account.pw_uid, group=self.account.pw_gid, extra_groups=[])
        return subprocess.run([sys.executable, str(self.script), *map(str, args)],
                              env={"PATH": "/usr/bin:/bin", "HOME": str(self.fixture)},
                              capture_output=True, text=True, timeout=15, **identity)

    def ok(self, *args, publisher=False):
        result = self.command(*args, publisher=publisher)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def upload(self):
        upload = Path(tempfile.mkdtemp(prefix=".upload-", dir=self.root))
        public = upload / "public"
        public.mkdir()
        data = b'{"type":"object"}\n'
        (public / "v1.bootstrap.schema.json").write_bytes(data)
        manifest = json.dumps({"revision": "a" * 40, "files": {
            "v1.bootstrap.schema.json": hashlib.sha256(data).hexdigest()}}, sort_keys=True).encode()
        (upload / "manifest.json").write_bytes(manifest)
        for path in [upload, *upload.rglob("*")]:
            os.chown(path, self.account.pw_uid, self.account.pw_gid)
            path.chmod(0o755 if path.is_dir() else 0o644)
        return upload, hashlib.sha256(manifest).hexdigest()

    def test_root_owned_legacy_directory_fails_then_setup_allows_activation_and_rollback(self):
        os.chown(self.root, self.account.pw_uid, self.account.pw_gid)
        self.current.mkdir(mode=0o755)
        nested = self.current / "network"
        nested.mkdir(mode=0o755)
        artifact = nested / "bootstrap.json"
        artifact.write_bytes(b"retained legacy bytes\n")
        before = (artifact.read_bytes(), artifact.stat().st_uid, artifact.stat().st_mode)
        upload, generation = self.upload()
        failed = self.command("activate", self.root, upload, generation, publisher=True)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("Permission denied", failed.stderr)
        self.assertFalse(self.current.is_symlink())
        self.assertEqual(artifact.read_bytes(), before[0])

        self.ok("permissions", self.root, self.account.pw_name)
        self.assertEqual(self.current.stat().st_uid, self.account.pw_uid)
        self.assertEqual(nested.stat().st_uid, 0)
        self.assertEqual((artifact.read_bytes(), artifact.stat().st_uid, artifact.stat().st_mode), before)
        upload, _ = self.upload()
        self.ok("activate", self.root, upload, generation, publisher=True)
        self.assertTrue(self.current.is_symlink())
        receipt = json.loads((self.root / f"receipt-{generation}.json").read_text())
        retained = self.root / receipt["previous"] / "network/bootstrap.json"
        self.assertEqual((retained.read_bytes(), retained.stat().st_uid, retained.stat().st_mode), before)
        # A repeated setup must not follow/chown the current symlink or target.
        target = self.current.resolve()
        os.chown(target, 0, 0)
        link_before = self.current.lstat()
        self.ok("permissions", self.root, self.account.pw_name)
        self.assertEqual(self.current.lstat().st_ino, link_before.st_ino)
        self.assertEqual(target.stat().st_uid, 0)
        self.ok("rollback", self.root, generation, publisher=True)
        self.assertEqual((self.current / "network/bootstrap.json").read_bytes(), before[0])

    def test_fresh_directory_and_read_only_legacy_owner(self):
        self.ok("permissions", self.root, self.account.pw_name)
        self.assertEqual(self.root.stat().st_uid, self.account.pw_uid)
        self.assertFalse(self.current.exists())
        self.current.mkdir(mode=0o555)
        self.ok("permissions", self.root, self.account.pw_name)
        self.assertEqual(self.current.stat().st_mode & 0o777, 0o755)
        upload, generation = self.upload()
        self.ok("activate", self.root, upload, generation, publisher=True)

    def test_symlinks_are_not_followed_and_unprivileged_setup_is_refused(self):
        outside = self.fixture / "outside"
        outside.mkdir(mode=0o700)
        self.current.symlink_to(outside)
        self.ok("permissions", self.root, self.account.pw_name)
        self.assertEqual(outside.stat().st_uid, 0)
        self.assertEqual(outside.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.current.lstat().st_uid, 0)
        result = self.command("permissions", self.root, self.account.pw_name, publisher=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires root", result.stderr)
        alias = self.fixture / "root-link"
        alias.symlink_to(self.root)
        result = self.command("permissions", alias, self.account.pw_name)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("real directory", result.stderr)


if __name__ == "__main__":
    if os.geteuid() != 0:
        sys.exit("ownership regression requires root; use a disposable container or CI runner")
    unittest.main()
