#!/usr/bin/env python3
"""Capture and clone stopped, owned DevShard fixture state; never restore in place."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sqlite3
import stat
import subprocess
import tempfile


SPEC = importlib.util.spec_from_file_location("fixture", Path(__file__).with_name("devshard-502-fixture.py"))
fixture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixture)
require = fixture.require
digest = fixture.digest
write_json = fixture.write_json
WRITERS = {"versiond-0": ("host", "/opt/versiond/data"),
           "devshardctl": ("gateway-a", "/var/lib/devshardctl")}


def docker(*args):
    return subprocess.run(["docker", "--context", "default", *map(str, args)],
                          check=True, capture_output=True, text=True, timeout=120).stdout


def inventory(root):
    result = {}
    for path in sorted(root.rglob("*")):
        info = path.lstat()
        require(stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode),
                "backup contains a link or special file")
        if path.is_file():
            result[str(path.relative_to(root))] = {"size": info.st_size, "sha256": digest(path)}
    require(result, "empty backup")
    return result


def ledger(root):
    """Read a scratch copy so SQLite cannot change the checksum-bound WAL/SHM."""
    result = {}
    with tempfile.TemporaryDirectory(prefix="ds502-state-check-") as temporary:
        scratch = Path(temporary) / "data"
        shutil.copytree(root, scratch)
        databases = sorted(scratch.rglob("*.db"))
        require(databases, "backup has no SQLite databases")
        for path in databases:
            connection = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)
            try:
                require(connection.execute("PRAGMA integrity_check").fetchall() == [("ok",)],
                        "SQLite integrity check failed")
                tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                if "sessions" not in tables:
                    continue
                require({"diffs", "signatures", "snapshots"} <= tables, "incomplete session schema")
                sessions = connection.execute(
                    "SELECT escrow_id, version, creator_addr, initial_balance, latest_nonce, last_finalized, status "
                    "FROM sessions ORDER BY escrow_id").fetchall()
                journals = []
                for escrow, version, creator, balance, nonce, finalized, status in sessions:
                    rows = connection.execute(
                        "SELECT nonce, hex(txs_proto), hex(user_sig), hex(post_state_root), hex(state_hash) "
                        "FROM diffs WHERE escrow_id=? ORDER BY nonce", (escrow,)).fetchall()
                    require([row[0] for row in rows] == list(range(1, nonce + 1)), "missing or duplicate journal nonce")
                    require(all(row[2] and row[3] for row in rows), "unsigned or rootless journal diff")
                    signatures = connection.execute(
                        "SELECT nonce, slot_id, hex(sig) FROM signatures WHERE escrow_id=? ORDER BY nonce,slot_id",
                        (escrow,)).fetchall()
                    require(all(1 <= row[0] <= nonce and row[2] for row in signatures), "invalid signature record")
                    journals.append({"escrow": escrow, "version": version, "creator": creator,
                                     "initial_balance": balance, "nonce": nonce, "last_finalized": finalized,
                                     "status": status, "diffs": rows, "signatures": signatures})
                result[str(path.relative_to(scratch))] = journals
            finally:
                connection.close()
    require(result and any(result.values()), "backup has no retained sessions")
    # This proves byte continuity, not signature validity; official runtime replay
    # and post-recovery inference must independently prove acceptance.
    return json.loads(json.dumps(result))


def identity(container):
    return {"id": container["Id"], "image": container["Image"],
            "started": container["State"]["StartedAt"], "finished": container["State"]["FinishedAt"]}


def validate_writers(containers, project, root, allow_unclean_gateway=False):
    writers = {}
    chain = []
    for item in containers:
        labels = item["Config"].get("Labels") or {}
        service = labels.get("com.docker.compose.service")
        owned = labels.get("com.docker.compose.project") == project
        if owned and service in WRITERS:
            require(service not in writers, "duplicate fixture writer")
            require(labels.get("org.gonka.test-lab.scope") == "ds502-fixture" and
                    labels.get("org.gonka.test-lab.owner") == project, "unowned fixture writer")
            state = item["State"]
            require(state["Status"] == "exited" and not state["Running"] and
                    not state.get("OOMKilled") and (state["ExitCode"] == 0 or
                    (service == "devshardctl" and allow_unclean_gateway)), "writer not cleanly stopped")
            require(item["HostConfig"]["RestartPolicy"]["Name"] == "no", "writer may restart")
            expected_image = fixture.VERSIOND if service == "versiond-0" else fixture.GATEWAY
            require(item["Config"]["Image"] == expected_image, "writer image drift")
            destination = WRITERS[service][1]
            mounts = [mount for mount in item["Mounts"] if mount["Destination"] == destination]
            require(len(mounts) == 1 and mounts[0]["Type"] == "bind" and
                    Path(mounts[0]["Source"]).resolve().is_relative_to(root), "writer state mount escaped fixture")
            writers[service] = item
        if owned and service == "mock-chain":
            require(item["State"]["Running"], "mock chain stopped; in-memory continuity lost")
            chain.append(identity(item))
    require(set(writers) == set(WRITERS) and len(chain) == 1, "incomplete fixture")
    sources = [Path(mount["Source"]).resolve() for item in writers.values() for mount in item["Mounts"]
               if mount["Destination"] == WRITERS[item["Config"]["Labels"]["com.docker.compose.service"]][1]]
    for item in containers:
        if not item["State"]["Running"]:
            continue
        for mount in item["Mounts"]:
            if mount.get("RW") and mount["Type"] == "bind":
                source = Path(mount["Source"]).resolve()
                require(not any(source.is_relative_to(target) or target.is_relative_to(source) for target in sources),
                        "another container can write the state")
    return writers, chain[0]


def inspect_all():
    ids = docker("ps", "-aq").split()
    require(ids, "no containers")
    return json.loads(docker("inspect", *ids))


def new_directory(path, root):
    require(path.absolute() == path.resolve() and path.parent.is_dir() and
            path.is_relative_to(root) and path != root and not path.exists(), "output must be a fresh fixture directory")
    path.mkdir(mode=0o700)


def snapshot(root, output, allow_unclean_gateway=False):
    receipt = json.loads((root / "prepared.json").read_text())
    expected_project = "ds502-fixture-" + hashlib.sha256(str(root).encode()).hexdigest()[:12]
    require(receipt["source"] == fixture.SOURCE and receipt["project"] == expected_project,
            "fixture preparation identity mismatch")
    writers, chain = validate_writers(inspect_all(), receipt["project"], root, allow_unclean_gateway)
    new_directory(output, root)
    payload = output / "data"
    payload.mkdir(mode=0o700)
    for service, (name, location) in WRITERS.items():
        target = payload / name
        target.mkdir(mode=0o700)
        docker("cp", writers[service]["Id"] + ":" + location + "/.", target)
    after, chain_after = validate_writers(inspect_all(), receipt["project"], root, allow_unclean_gateway)
    require(chain == chain_after and {key: identity(value) for key, value in writers.items()} ==
            {key: identity(value) for key, value in after.items()}, "runtime changed during backup")
    files = inventory(payload)
    state = ledger(payload)
    require(files == inventory(payload), "backup changed during verification")
    manifest = {"schema": "gdc-ds502-state/1", "project": receipt["project"], "mock_chain": chain,
                "writers": {key: identity(value) for key, value in writers.items()},
                "writer_exit_codes": {key: value["State"]["ExitCode"] for key, value in writers.items()},
                "unclean_gateway_capture_authorized": allow_unclean_gateway,
                "files": files, "ledger": state, "signature_verification": "requires official runtime replay"}
    write_json(output / "manifest.json", manifest)
    return digest(output / "manifest.json")


def verify(snapshot_path, expected_hash):
    require(digest(snapshot_path / "manifest.json") == expected_hash, "snapshot manifest hash mismatch")
    manifest = json.loads((snapshot_path / "manifest.json").read_text())
    require(manifest["schema"] == "gdc-ds502-state/1", "unknown snapshot schema")
    require(inventory(snapshot_path / "data") == manifest["files"], "snapshot file checksum mismatch")
    require(ledger(snapshot_path / "data") == manifest["ledger"], "snapshot ledger mismatch")
    return manifest


def clone(snapshot_path, expected_hash, current_path, current_hash, output, root, allow_unclean_gateway=False):
    source = verify(snapshot_path, expected_hash)
    current = verify(current_path, current_hash)
    require(source["project"] == current["project"] and source["mock_chain"] == current["mock_chain"],
            "snapshot belongs to another fixture or restarted mock chain")
    require(source["ledger"] == current["ledger"], "stale snapshot would lose later signed work")
    new_directory(output, root)
    actual_hash = snapshot(root, output / "current", allow_unclean_gateway)
    actual = verify(output / "current", actual_hash)
    require(actual["files"] == current["files"] and actual["mock_chain"] == current["mock_chain"],
            "current snapshot is no longer current")
    shutil.copytree(snapshot_path / "data", output / "data")
    require(inventory(output / "data") == source["files"], "clone checksum mismatch")
    write_json(output / "clone.json", {"snapshot_sha256": expected_hash, "current_sha256": current_hash,
                                       "fresh_current_sha256": actual_hash,
                                       "files": source["files"],
                                       "project": source["project"], "runtime_acceptance": "NOT RUN"})


def render_clone(root, clone_path, expected_hash, compose_path, output):
    require(digest(clone_path / "clone.json") == expected_hash, "clone manifest hash mismatch")
    clone_manifest = json.loads((clone_path / "clone.json").read_text())
    require(inventory(clone_path / "data") == clone_manifest["files"], "clone was changed before activation")
    document = json.loads(compose_path.read_text())
    require(document["name"] == clone_manifest["project"] and
            document["networks"] == {"fixture": {"internal": True}}, "clone fixture composition mismatch")
    for service, (directory, location) in WRITERS.items():
        definition = document["services"][service]
        expected_image = fixture.VERSIOND if service == "versiond-0" else fixture.GATEWAY
        require(definition["image"] == expected_image, "clone runtime artifact drift")
        mounts = [mount for mount in definition["volumes"] if mount["target"] == location]
        require(len(mounts) == 1 and mounts[0]["type"] == "bind" and
                Path(mounts[0]["source"]).resolve().is_relative_to(root), "clone mount escaped fixture")
        mounts[0]["source"] = str(clone_path / "data" / directory)
    require(output.parent == root and not output.exists(), "compose output must be a fresh root file")
    write_json(output, document)


def continuity(before, after, require_new_work=False):
    require(before["project"] == after["project"] and before["mock_chain"] == after["mock_chain"],
            "fixture or chain continuity lost")
    require(set(before["ledger"]) == set(after["ledger"]), "session database set changed")
    observations = {}
    for database, records in before["ledger"].items():
        old = {record["escrow"]: record for record in records}
        new = {record["escrow"]: record for record in after["ledger"][database]}
        require(len(old) == len(records) and len(new) == len(after["ledger"][database]) and old.keys() == new.keys(),
                "escrow set changed")
        observations[database] = []
        for escrow, first in old.items():
            last = new[escrow]
            require(all(first[key] == last[key] for key in ("version", "creator", "initial_balance", "status")),
                    "session identity or balance origin changed")
            require(last["nonce"] >= first["nonce"] and last["last_finalized"] >= first["last_finalized"],
                    "nonce went backwards")
            if require_new_work:
                require(last["nonce"] > first["nonce"], "no new committed work")
            require(last["diffs"][:len(first["diffs"])] == first["diffs"], "signed diff prefix changed")
            require(all(row in last["signatures"] for row in first["signatures"]), "retained host signature changed")
            observations[database].append({"escrow": escrow, "before_nonce": first["nonce"],
                                           "after_nonce": last["nonce"], "preserved_signed_diffs": len(first["diffs"])})
    return observations


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("snapshot", "clone", "verify", "render-clone", "compare"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--snapshot", type=Path)
    parser.add_argument("--sha256")
    parser.add_argument("--current", type=Path)
    parser.add_argument("--current-sha256")
    parser.add_argument("--compose", type=Path)
    parser.add_argument("--require-new-work", action="store_true")
    parser.add_argument("--allow-unclean-gateway", action="store_true",
                        help="capture stopped gateway crash state for isolated diagnosis; never implies clean shutdown")
    args = parser.parse_args()
    os.umask(0o077)
    root = args.root.resolve(strict=True)
    require(root.name.startswith("ds502-fixture-"), "not a fixture root")
    for path in (args.snapshot, args.current):
        if path:
            require(path.absolute() == path.resolve() and path.is_relative_to(root), "input escaped fixture")
    if args.action == "snapshot":
        require(args.output is not None, "output required")
        print(json.dumps({"snapshot_sha256": snapshot(root, args.output, args.allow_unclean_gateway),
                          "runtime_recovery": "NOT RUN"}))
    elif args.action == "verify":
        require(args.snapshot is not None and args.sha256, "snapshot and hash required")
        verify(args.snapshot, args.sha256)
        print("PASS: backup bytes and SQLite ledger verified; runtime recovery NOT RUN")
    elif args.action == "clone":
        require(all((args.snapshot, args.sha256, args.current, args.current_sha256, args.output)), "clone inputs required")
        clone(args.snapshot, args.sha256, args.current, args.current_sha256, args.output, root, args.allow_unclean_gateway)
        print("PASS: isolated clone prepared; runtime recovery NOT RUN")
    elif args.action == "render-clone":
        require(all((args.snapshot, args.sha256, args.compose, args.output)), "clone render inputs required")
        require(args.compose.resolve().parent == root, "compose escaped fixture")
        render_clone(root, args.snapshot, args.sha256, args.compose, args.output)
        print("Clone composition prepared; runtime recovery NOT RUN")
    else:
        require(all((args.snapshot, args.sha256, args.current, args.current_sha256)), "comparison inputs required")
        print(json.dumps(continuity(verify(args.snapshot, args.sha256),
                                   verify(args.current, args.current_sha256), args.require_new_work), indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, sqlite3.Error, subprocess.SubprocessError) as error:
        raise SystemExit(f"BLOCKED: {error}") from None
