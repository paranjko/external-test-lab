#!/usr/bin/env python3
"""Offline backup integrity and no-lost-work contracts, not runtime recovery."""

import copy
import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("backup", Path(__file__).with_name("devshard-502-state.py"))
backup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backup)


class StateContracts(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ds502-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.project = "ds502-fixture-test"

    def make_snapshot(self, name, nonce=1, chain="chain-a", signature=b"signed"):
        folder = self.root / name
        data = folder / "data/host/v5"
        data.mkdir(parents=True)
        db = sqlite3.connect(data / "epoch_1.db")
        db.executescript("""
            CREATE TABLE sessions (escrow_id TEXT, version TEXT, creator_addr TEXT,
                initial_balance INTEGER, latest_nonce INTEGER, last_finalized INTEGER, status TEXT);
            CREATE TABLE diffs (escrow_id TEXT, nonce INTEGER, txs_proto BLOB,
                user_sig BLOB, post_state_root BLOB, state_hash BLOB);
            CREATE TABLE signatures (escrow_id TEXT, nonce INTEGER, slot_id INTEGER, sig BLOB);
            CREATE TABLE snapshots (escrow_id TEXT, nonce INTEGER, state_data BLOB);
        """)
        db.execute("INSERT INTO sessions VALUES ('1','v5','synthetic',5000000000,?,0,'active')", (nonce,))
        for index in range(1, nonce + 1):
            db.execute("INSERT INTO diffs VALUES ('1',?,?,?,?,?)", (index, b"tx", signature, b"root", b"hash"))
            db.execute("INSERT INTO signatures VALUES ('1',?,0,?)", (index, b"host-signature"))
        db.commit()
        db.close()
        (data / "payload.bin").write_bytes(b"retained payload")
        manifest = {"schema": "gdc-ds502-state/1", "project": self.project,
                    "mock_chain": {"id": chain}, "writers": {},
                    "files": backup.inventory(folder / "data"), "ledger": backup.ledger(folder / "data")}
        backup.write_json(folder / "manifest.json", manifest)
        return folder, backup.digest(folder / "manifest.json")

    def containers(self):
        items = []
        for service, (name, target) in backup.WRITERS.items():
            image = backup.fixture.VERSIOND if service == "versiond-0" else backup.fixture.GATEWAY
            items.append({"Id": service, "Image": "sha256:exact", "Config": {"Image": image, "Labels": {
                "com.docker.compose.project": self.project, "com.docker.compose.service": service,
                "org.gonka.test-lab.scope": "ds502-fixture", "org.gonka.test-lab.owner": self.project}},
                "State": {"Status": "exited", "Running": False, "ExitCode": 0, "StartedAt": "before", "FinishedAt": "after"},
                "HostConfig": {"RestartPolicy": {"Name": "no"}},
                "Mounts": [{"Type": "bind", "RW": True, "Source": str(self.root / "data" / name), "Destination": target}]})
        items.append({"Id": "chain", "Image": "sha256:mock", "Config": {"Labels": {
            "com.docker.compose.project": self.project, "com.docker.compose.service": "mock-chain"}},
            "State": {"Running": True, "StartedAt": "before", "FinishedAt": ""}, "Mounts": []})
        return items

    def test_verified_backup_does_not_change_original(self):
        folder, sha = self.make_snapshot("before")
        files = backup.inventory(folder / "data")
        result = backup.verify(folder, sha)
        self.assertEqual(result["ledger"]["host/v5/epoch_1.db"][0]["nonce"], 1)
        self.assertEqual(files, backup.inventory(folder / "data"))

    def test_wal_is_read_and_evidence_not_checkpointed(self):
        folder, sha = self.make_snapshot("wal")
        with sqlite3.connect(folder / "data/host/v5/epoch_1.db") as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("UPDATE sessions SET latest_nonce=2")
            db.execute("INSERT INTO diffs VALUES ('1',2,?,?,?,?)",
                       (b"second", b"signed", b"root2", b"hash2"))
            db.commit()
            files = backup.inventory(folder / "data")
            self.assertTrue(any(name.endswith("-wal") for name in files))
            self.assertEqual(backup.ledger(folder / "data")["host/v5/epoch_1.db"][0]["nonce"], 2)
            self.assertEqual(backup.inventory(folder / "data"), files)

    def test_corrupt_missing_and_extra_files_rejected(self):
        for kind in ("corrupt", "missing", "extra"):
            with self.subTest(kind=kind):
                folder, sha = self.make_snapshot(kind)
                payload = folder / "data/host/v5/payload.bin"
                if kind == "corrupt":
                    payload.write_bytes(b"corrupt")
                elif kind == "missing":
                    payload.unlink()
                else:
                    (folder / "data/unexpected").write_bytes(b"extra")
                with self.assertRaisesRegex(ValueError, "checksum"):
                    backup.verify(folder, sha)

    def test_manifest_tamper_and_link_rejected(self):
        folder, sha = self.make_snapshot("before")
        with self.assertRaisesRegex(ValueError, "manifest hash"):
            backup.verify(folder, "0" * 64)
        (folder / "data/link").symlink_to("/etc/passwd")
        with self.assertRaisesRegex(ValueError, "link"):
            backup.verify(folder, sha)

    def test_corrupt_sqlite_rejected_even_if_file_manifest_is_refreshed(self):
        folder, sha = self.make_snapshot("before")
        (folder / "data/host/v5/epoch_1.db").write_bytes(b"not sqlite")
        with self.assertRaises(sqlite3.DatabaseError):
            backup.ledger(folder / "data")

    def test_missing_nonce_and_unsigned_diff_rejected(self):
        for kind in ("gap", "unsigned"):
            folder, sha = self.make_snapshot(kind, nonce=2)
            with sqlite3.connect(folder / "data/host/v5/epoch_1.db") as db:
                if kind == "gap":
                    db.execute("DELETE FROM diffs WHERE nonce=1")
                else:
                    db.execute("UPDATE diffs SET user_sig=NULL WHERE nonce=1")
            with self.assertRaises(ValueError):
                backup.ledger(folder / "data")

    def test_live_crashed_restarting_unowned_or_escaped_writer_rejected(self):
        changes = [lambda c: c[0]["State"].update(Running=True, Status="running"),
                   lambda c: c[0]["State"].update(ExitCode=137),
                   lambda c: c[0]["HostConfig"]["RestartPolicy"].update(Name="always"),
                   lambda c: c[0]["Config"]["Labels"].update({"org.gonka.test-lab.owner": "other"}),
                   lambda c: c[0]["Mounts"][0].update(Source="/srv/dai/live"),
                   lambda c: c[2]["State"].update(Running=False)]
        backup.validate_writers(self.containers(), self.project, self.root)
        for change in changes:
            with self.subTest(change=change):
                containers = self.containers()
                change(containers)
                with self.assertRaises(ValueError):
                    backup.validate_writers(containers, self.project, self.root)

    def test_other_container_parent_mount_writer_rejected(self):
        containers = self.containers()
        other = copy.deepcopy(containers[2])
        other["Config"]["Labels"] = {}
        other["Mounts"] = [{"Type": "bind", "RW": True, "Source": str(self.root)}]
        containers.append(other)
        with self.assertRaisesRegex(ValueError, "another container"):
            backup.validate_writers(containers, self.project, self.root)

    def test_unclean_gateway_is_explicit_diagnostic_only_and_not_a_running_writer_bypass(self):
        containers = self.containers()
        containers[1]["State"]["ExitCode"] = 2
        with self.assertRaisesRegex(ValueError, "cleanly stopped"):
            backup.validate_writers(containers, self.project, self.root)
        backup.validate_writers(containers, self.project, self.root, allow_unclean_gateway=True)
        containers[1]["State"].update(Running=True, Status="running")
        with self.assertRaises(ValueError):
            backup.validate_writers(containers, self.project, self.root, allow_unclean_gateway=True)

    def test_current_clone_and_no_work_restore_are_separate_from_stale_restore(self):
        before, before_sha = self.make_snapshot("before")
        unchanged, unchanged_sha = self.make_snapshot("unchanged")
        original = backup.verify
        with patch.object(backup, "snapshot", return_value=unchanged_sha), \
                patch.object(backup, "verify", wraps=backup.verify) as verify:
            # The fresh readback is a separate snapshot operation, never an operator assertion.
            verify.side_effect = lambda path, sha: original(unchanged if path.name == "current" else path, sha)
            backup.clone(before, before_sha, unchanged, unchanged_sha, self.root / "restored", self.root)
        after, after_sha = self.make_snapshot("after", nonce=2)
        with self.assertRaisesRegex(ValueError, "later signed work"):
            backup.clone(before, before_sha, after, after_sha, self.root / "stale", self.root)
        self.assertFalse((self.root / "stale").exists())

    def test_restarted_chain_and_existing_target_refused(self):
        before, before_sha = self.make_snapshot("before")
        new, new_sha = self.make_snapshot("new", chain="new-chain")
        with self.assertRaisesRegex(ValueError, "restarted mock chain"):
            backup.clone(before, before_sha, new, new_sha, self.root / "clone", self.root)
        with self.assertRaisesRegex(ValueError, "fresh"):
            backup.clone(before, before_sha, before, before_sha, before, self.root)

    def test_fresh_capture_catches_old_current_receipt(self):
        before, before_sha = self.make_snapshot("before")
        later, later_sha = self.make_snapshot("later", nonce=2)
        original = backup.verify
        with patch.object(backup, "snapshot", return_value=later_sha), patch.object(backup, "verify") as verify:
            verify.side_effect = lambda path, sha: original(later if path.name == "current" else path, sha)
            with self.assertRaisesRegex(ValueError, "no longer current"):
                backup.clone(before, before_sha, before, before_sha, self.root / "stale-current", self.root)
        self.assertFalse((self.root / "stale-current/data").exists())

    def test_signed_bytes_change_at_same_nonce_is_not_no_work_restore(self):
        before, before_sha = self.make_snapshot("before")
        changed, changed_sha = self.make_snapshot("changed", signature=b"different-signature")
        with self.assertRaisesRegex(ValueError, "later signed work"):
            backup.clone(before, before_sha, changed, changed_sha, self.root / "invalid", self.root)

    def test_clone_render_only_changes_two_state_mounts(self):
        before, sha = self.make_snapshot("before")
        clone = self.root / "clone"
        backup.shutil.copytree(before / "data", clone / "data")
        backup.write_json(clone / "clone.json", {"files": backup.inventory(clone / "data"), "project": self.project})
        document = {"name": self.project, "networks": {"fixture": {"internal": True}}, "services": {}}
        for service, (directory, location) in backup.WRITERS.items():
            document["services"][service] = {
                "image": backup.fixture.VERSIOND if service == "versiond-0" else backup.fixture.GATEWAY,
                "volumes": [backup.fixture.bind(self.root / "data" / directory, location, False)],
                "environment": {"retain": "unchanged"}}
        source = self.root / "compose.json"
        backup.write_json(source, document)
        output = self.root / "compose-clone.json"
        backup.render_clone(self.root, clone, backup.digest(clone / "clone.json"), source, output)
        result = json.loads(output.read_text())
        for service, (directory, location) in backup.WRITERS.items():
            self.assertEqual(result["services"][service]["volumes"][0]["source"], str(clone / "data" / directory))
            result["services"][service]["volumes"] = document["services"][service]["volumes"]
        self.assertEqual(result, document)
        (clone / "data/tamper").write_text("changed")
        with self.assertRaisesRegex(ValueError, "changed before activation"):
            backup.render_clone(self.root, clone, backup.digest(clone / "clone.json"), source, self.root / "bad.json")

    def test_continuity_requires_retained_signed_prefix_and_new_committed_work(self):
        before, sha = self.make_snapshot("before")
        after, after_sha = self.make_snapshot("after", nonce=2)
        first, last = backup.verify(before, sha), backup.verify(after, after_sha)
        observation = backup.continuity(first, last, require_new_work=True)
        self.assertEqual(observation["host/v5/epoch_1.db"][0]["after_nonce"], 2)
        for field, value in (("nonce", 0), ("creator", "another creator"), ("diffs", []), ("signatures", [])):
            broken = copy.deepcopy(last)
            broken["ledger"]["host/v5/epoch_1.db"][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                backup.continuity(first, broken, require_new_work=True)
        with self.assertRaisesRegex(ValueError, "no new committed work"):
            backup.continuity(first, first, require_new_work=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
