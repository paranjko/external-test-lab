#!/usr/bin/env python3
"""Receipt-bound model support updates, without changing containers or signers."""
import argparse
import copy
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
import urllib.parse
import urllib.request


FIELDS = {"host", "inference_segment", "inference_port", "poc_segment", "poc_port",
          "models", "id", "max_concurrent", "hardware"}
RUNTIME_FIELDS = {"node_num", "registration_seq"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def save(path, value):
    with path.open("x", encoding="utf-8") as out:
        json.dump(value, out, indent=2, sort_keys=True)
        out.write("\n")
        out.flush()
        os.fsync(out.fileno())


def command(*args):
    return subprocess.check_output(args, text=True, timeout=30).strip()


def api(method="GET", body=None, suffix=""):
    request = urllib.request.Request(
        "http://127.0.0.1:9200/admin/v1/nodes" + suffix, method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def models_valid(models):
    require(isinstance(models, dict) and models, "models must be a nonempty object")
    for name, config in models.items():
        require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", name), "invalid model ID")
        require(isinstance(config, dict) and set(config) == {"args"},
                "each model must contain only args; source overrides are not supported")
        require(isinstance(config["args"], list) and all(
            isinstance(arg, str) and arg and "\x00" not in arg for arg in config["args"]),
            "model args must be strings")


def discover(host):
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", host), "invalid SSH alias")
    ids = command("docker", "ps", "-q", "--filter", "label=com.docker.compose.service=api").splitlines()
    require(len(ids) == 1, "expected exactly one running DAPI container")
    info = json.loads(command("docker", "inspect", ids[0]))[0]
    mounts = [m for m in info["Mounts"] if m["Destination"] == "/root/node_config.json"
              and m["Type"] == "bind"]
    require(len(mounts) == 1, "expected one node_config.json bind mount")
    path = Path(mounts[0]["Source"])
    require(str(path) in ("/srv/dai/deploy/node-config.json", "/srv/dai/node/node-config.json",
                         f"/srv/dai/deploy/{host}/node-config.json"),
            "unsupported node configuration layout")
    require(path.is_file() and not path.is_symlink(), "unsafe node configuration file")
    status = json.loads(command("docker", "exec", ids[0], "curl", "-fsS", "--max-time", "10",
                                "http://node:26657/status"))
    chain = status["result"]["node_info"]["network"]
    runtime = command("docker", "exec", ids[0], "sha256sum",
                      "/root/.dapi/cosmovisor/current/bin/decentralized-api").split()[0]
    require(re.fullmatch(r"[0-9a-f]{64}", runtime), "invalid DAPI binary digest")
    return path, {"container": info["Id"], "chain_id": chain, "config_path": str(path),
                  "dapi_sha256": runtime}


def observe(path, node_id):
    raw = path.read_bytes()
    disk = json.loads(raw)
    require(isinstance(disk, list), "node config must be an array")
    found = [i for i, n in enumerate(disk) if n.get("id") == node_id]
    live = [n for n in api() if n.get("node", {}).get("id") == node_id]
    require(len(found) == len(live) == 1, "node ID must exist exactly once on disk and in DAPI")
    node = live[0]["node"]
    require(not set(node) - FIELDS - RUNTIME_FIELDS, "unknown DAPI node fields; refusing lossy update")
    require(not set(disk[found[0]]) - FIELDS, "unknown stored node fields; refusing lossy update")
    # Omitted optional JSON fields are equivalent to their DAPI zero values.
    stored = dict(node)
    stored.update(disk[found[0]])
    require(stored == node, "stored node configuration differs from DAPI; reconcile before updating")
    return raw, disk, found[0], live[0]


def active_guard(current, desired):
    state = current.get("state", {})
    require(state.get("lock_count", 0) == 0, "node has active inference locks")
    assigned = set(state.get("epoch_ml_nodes") or {}) | set(state.get("preserved_models") or {})
    for name in assigned:
        require(desired.get(name) == current["node"]["models"].get(name),
                "cannot remove or change an assigned/preserved model; transition allocations first")


def transition_guard(identity, current, retire_preserved=False):
    state = current["state"]
    require(state.get("lock_count") == 0, "transition requires no inference locks")
    preserved = state.get("preserved_models") or {}
    if preserved:
        require(retire_preserved, "transition requires no preserved obligations unless explicitly retiring zero-share capacity")
        with urllib.request.urlopen("http://127.0.0.1:8000/chain-api/productscience/inference/inference/params", timeout=10) as response:
            params = json.load(response)["params"]
        configs = params["poc_params"]["models"]
        for model, retained in preserved.items():
            matches = [entry for entry in configs if entry.get("model_id") == model]
            require(retained is True and model in current["node"]["models"] and len(matches) == 1 and
                    matches[0].get("dynamic_coefficient", {}).get("target_share_bps") == 0,
                    "preserved capacity must have an explicit zero target share before retirement")
    require(state.get("current_status") == "INFERENCE", "wait for idle inference phase before transition")
    if state.get("poc_current_status") != "IDLE" or preserved:
        # InferenceUpAll can leave VALIDATING cached on an already-serving
        # worker. Do not clear it blindly: independently prove the chain window
        # and the single local backend are idle, at both preview and apply.
        require(state.get("poc_current_status") in ("IDLE", "VALIDATING") and
                current["node"].get("host") == "inference" and
                current["node"].get("inference_port") == 5000,
                "wait for idle inference phase before transition")
        with urllib.request.urlopen("http://127.0.0.1:9000/v1/epochs/latest", timeout=10) as response:
            epoch = json.load(response)
        require(epoch.get("phase") == "Inference" and
                epoch.get("is_confirmation_poc_active") is False and
                int(epoch["epoch_stages"]["next_poc_start"]) - int(epoch["block_height"]) >= 30,
                "no verified idle chain window for cached PoC status")
        containers = command("docker", "ps", "-q", "--filter",
                             "label=com.docker.compose.service=mlnode").splitlines()
        require(len(containers) == 1, "expected one local ML backend for idle verification")
        backend = json.loads(command("docker", "exec", containers[0], "curl", "-fsS",
                                     "--max-time", "10", "http://127.0.0.1:5001/api/v1/pow/status"))
        require(backend == {"status": "IDLE", "config": None, "stats": None},
                "ML backend has active or unknown PoC work")
    require(state.get("admin_state", {}).get("enabled") is True,
            "transition requires an enabled worker")
    with urllib.request.urlopen("http://127.0.0.1:8000/devshard/healthz", timeout=10) as response:
        versions = json.load(response)
    require(isinstance(versions, list) and versions, "missing DevShard runtime inventory")
    for version in versions:
        require(version.get("status") == "running" and
                re.fullmatch(r"v[0-9][A-Za-z0-9._-]*", version.get("name", "")),
                "all inventoried DevShard runtimes must be running")
        port = version.get("port")
        require(type(port) is int and 1 <= port <= 65535, "invalid runtime port")
        # Some proxy layouts require a version; others pin these paths to
        # primary. Accept only exact identity, otherwise query the runtime.
        url = f"http://127.0.0.1:8000/devshard/{version['name']}/stats/shards"
        with urllib.request.urlopen(url, timeout=10) as response:
            proxy_stats = json.load(response)
        if proxy_stats.get("protocol_version") == version["name"]:
            # New primary builds bind their private port to loopback only.
            # Accept proxy stats only for the exact reported protocol identity.
            stats = proxy_stats
        else:
            stats = json.loads(command("docker", "exec", identity["container"], "curl", "-fsS",
                                       "--max-time", "10", f"http://versiond:{port}/stats/shards"))
        require(stats.get("protocol_version") == version["name"], "runtime stats version mismatch")
        age = time.time() - stats.get("cached_at", 0)
        require(0 <= age <= 65 and stats.get("cache_ttl_seconds", 999) <= 60,
                "runtime escrow snapshot is stale")
        require(stats.get("active_escrows") == [] and stats.get("shards") == [],
                "active DevShard escrow/session prevents transition")
    return sorted(versions, key=lambda version: version["name"])


def transition_apply(path, identity, plan, attempt, retry_of=None):
    raw, disk, index, current = observe(path, plan["node_id"])
    require(current["node"] == plan["before"] and hashlib.sha256(raw).hexdigest() == plan["disk_sha256"],
            "configuration changed after transition preview")
    require(transition_guard(identity, current, plan.get("retire_preserved", False)) == plan["runtime_inventory"], "DevShard runtime inventory changed")
    replacement = plan["replace_id"]
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]*", replacement) and replacement != plan["node_id"],
            "invalid replacement worker ID")
    require(all(current["node"]["models"].get(name) == config for name, config in plan["models"].items()),
            "transition must use unchanged, already declared model arguments")
    require(all(n["id"] != replacement for n in disk) and
            all(n["node"]["id"] != replacement for n in api()), "replacement worker already exists")
    target = {k: v for k, v in current["node"].items() if k in FIELDS}
    target.update(id=replacement, models=plan["models"], max_concurrent=1)
    next_disk = copy.deepcopy(disk)
    next_disk[index] = target
    next_bytes = (json.dumps(next_disk, indent=2) + "\n").encode()
    attempt.mkdir(mode=0o700)
    if retry_of:
        save(attempt / "retry-of.json", {"receipt": str(retry_of), "reason": "unchanged original worker and disk verified"})
    save(attempt / "plan.json", plan)
    save_bytes(attempt / "before.bin", raw)
    save_bytes(attempt / "after.bin", next_bytes)
    save(attempt / "transition-intent.json", {"time": time.time()})
    try:
        # Retire only the broker record, not any directory, cache, key or chain
        # state. The new ID avoids carrying the old epoch's model assignment.
        # Echo's route param retains percent escapes; ':' is legal in a path
        # segment and must stay literal for existing model:participant IDs.
        require(api("DELETE", suffix="/" + urllib.parse.quote(plan["node_id"], safe=":")) is True,
                "old worker removal not confirmed")
        require(all(n["node"]["id"] != plan["node_id"] for n in api()), "old worker still registered")
        api("POST", target)
        write_config(path, next_bytes)
        _, _, _, after = observe(path, replacement)
        require({k: v for k, v in after["node"].items() if k in FIELDS} == target,
                "replacement readback mismatch")
        require(path.read_bytes() == next_bytes, "replacement disk mismatch")
    except Exception as exc:
        save(attempt / "transition-uncertain.json", {"error": str(exc)})
        raise ValueError(f"transition outcome uncertain; inspect {attempt}; do not retry") from exc
    result = {"status": "transitioned", "receipt": str(attempt), "identity": identity,
              "retired_worker": plan["node_id"], "worker": replacement,
              "models": list(plan["models"]), "serving_verified": False}
    save(attempt / "transition-result.json", result)
    return result


def write_config(path, data):
    # Preserve the inode used by the existing Docker bind mount.
    with path.open("r+b") as out:
        out.write(data)
        out.truncate()
        out.flush()
        os.fsync(out.fileno())


def save_bytes(path, data):
    with path.open("xb") as out:
        out.write(data)
        out.flush()
        os.fsync(out.fileno())


def remote(request):
    os.umask(0o077)
    action = request["action"]
    require(action in ("plan", "apply", "rollback"), "invalid action")
    path, identity = discover(request["host"])
    with (path.parent / ".gdc-models.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if action == "plan":
            models_valid(request["models"])
            raw, disk, index, current = observe(path, request["node_id"])
            replacement = request.get("replace_id")
            if replacement:
                require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]*", replacement) and
                        replacement != request["node_id"] and
                        re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]*", request["node_id"]),
                        "replacement requires different valid worker IDs")
                require(len(request["models"]) == 1 and not
                        (set(request["models"]) & set(current["state"].get("epoch_ml_nodes", {}))),
                        "transition requires exactly one different model")
                require(all(current["node"]["models"].get(name) == config
                            for name, config in request["models"].items()),
                        "declare and verify the target model support before transitioning")
                versions = transition_guard(identity, current, request.get("retire_preserved", False))
            else:
                active_guard(current, request["models"])
            result = {"schema_version": 1, "kind": "gdc-host-models", "host": request["host"],
                    "created_at": int(time.time()), "identity": identity,
                    "node_id": request["node_id"], "before": current["node"],
                    "disk_sha256": hashlib.sha256(raw).hexdigest(), "models": request["models"]}
            if replacement:
                result.update(replace_id=replacement, runtime_inventory=versions)
                if request.get("retire_preserved"):
                    result["retire_preserved"] = True
            return result
        plan = request["plan"]
        require(plan["schema_version"] == 1 and plan["kind"] == "gdc-host-models", "invalid plan")
        require(plan["host"] == request["host"] and plan["identity"] == identity,
                "plan host, chain or deployment changed")
        key = digest(plan)
        ledger = path.parent / ".gdc-model-updates"
        ledger.mkdir(mode=0o700, exist_ok=True)
        require(not ledger.is_symlink(), "unsafe receipt directory")
        attempt = ledger / key
        if plan.get("replace_id"):
            require(action == "apply", "worker transitions require a separately reviewed reverse transition; no blind rollback")
            require(0 <= time.time() - plan["created_at"] <= 600, "plan expired")
            retry_of = None
            if request.get("retry_unchanged"):
                prior = json.loads((attempt / "transition-uncertain.json").read_text())
                require(prior.get("error") in ("old worker still registered", "old worker removal not confirmed"),
                        "only a confirmed unchanged-worker failure can be retried")
                require(json.loads((attempt / "plan.json").read_text()) == plan, "prior plan mismatch")
                retry_of, attempt = attempt, ledger / (key + ".retry-1")
            require(not attempt.exists(), "transition attempt already exists; inspect receipt")
            models_valid(plan["models"])
            require(len(plan["models"]) == 1, "transition requires one model")
            return transition_apply(path, identity, plan, attempt, retry_of)
        require(not request.get("retry_unchanged"), "retry-unchanged requires a worker transition")
        if action == "apply":
            require(0 <= time.time() - plan["created_at"] <= 600, "plan expired; create a fresh preview")
            require(not attempt.exists(), "attempt already exists; inspect its receipt before retrying")
            raw, disk, index, current = observe(path, plan["node_id"])
            require(current["node"] == plan["before"] and hashlib.sha256(raw).hexdigest() == plan["disk_sha256"],
                    "configuration changed after preview")
            desired = plan["models"]
            models_valid(desired)
            active_guard(current, desired)
            if current["node"]["models"] == desired:
                return {"status": "no_op", "identity": identity}
            attempt.mkdir(mode=0o700)
            save(attempt / "plan.json", plan)
            save_bytes(attempt / "before.bin", raw)
            target = {k: v for k, v in current["node"].items() if k in FIELDS}
            target["models"] = desired
            next_disk = copy.deepcopy(disk)
            next_disk[index]["models"] = desired
            next_bytes = (json.dumps(next_disk, indent=2) + "\n").encode()
            save_bytes(attempt / "after.bin", next_bytes)
        else:
            require(attempt.is_dir() and not attempt.is_symlink(), "no matching apply receipt")
            require(json.loads((attempt / "plan.json").read_text()) == plan, "receipt mismatch")
            require(not (attempt / "rollback-intent.json").exists(), "rollback already attempted; inspect receipt")
            raw, disk, index, current = observe(path, plan["node_id"])
            expected = dict(plan["before"], models=plan["models"])
            require(current["node"] == expected and raw == (attempt / "after.bin").read_bytes(),
                    "state differs from applied plan; refusing blind rollback")
            desired = plan["before"]["models"]
            active_guard(current, desired)
            target = {k: v for k, v in plan["before"].items() if k in FIELDS}
            next_bytes = (attempt / "before.bin").read_bytes()
        save(attempt / (action + "-intent.json"), {"action": action, "time": time.time()})
        # Persist both payloads before the first mutation. On any ambiguous
        # failure retain them and stop; never retry or overwrite newer state.
        try:
            api("POST", target)
            write_config(path, next_bytes)
            _, _, _, after = observe(path, plan["node_id"])
            require(after["node"] == dict(current["node"], models=desired), "DAPI readback mismatch")
            require(path.read_bytes() == next_bytes, "disk readback mismatch")
        except Exception as exc:
            save(attempt / (action + "-uncertain.json"), {"error": str(exc)})
            raise ValueError(f"update outcome uncertain; inspect {attempt}; no automatic retry") from exc
        result = {"status": "configured", "action": action, "receipt": str(attempt),
                  "identity": identity, "models": list(desired),
                  "serving_verified": False}
        save(attempt / (action + "-result.json"), result)
        return result


def main():
    if sys.argv[1:] == ["--remote"]:
        print(json.dumps(remote(json.load(sys.stdin))))
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("plan", "apply", "rollback"))
    parser.add_argument("host")
    parser.add_argument("--node-id")
    parser.add_argument("--models", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--plan", type=Path)
    parser.add_argument("--replace-id", help="explicitly retire the old idle worker and register a single-model replacement")
    parser.add_argument("--retire-preserved", action="store_true", help="explicitly retire zero-target-share preserved capacity only with independently idle local backend and empty escrow runtimes")
    parser.add_argument("--retry-unchanged", action="store_true", help="one linked retry after a verified no-op worker removal")
    args = parser.parse_args()
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", args.host), "invalid SSH alias")
    request = {"action": args.action, "host": args.host}
    require(not args.retire_preserved or (args.action == "plan" and args.replace_id),
            "retire-preserved requires an explicit transition plan")
    if args.retire_preserved:
        request["retire_preserved"] = True
    require(not args.retry_unchanged or args.action == "apply", "retry-unchanged requires apply")
    if args.retry_unchanged:
        request["retry_unchanged"] = True
    if args.action == "plan":
        require(args.node_id and args.models and args.output and not args.plan,
                "plan requires --node-id, --models and a new --output")
        require(not args.output.exists() and not args.output.is_symlink(), "output already exists")
        request.update(node_id=args.node_id, models=json.loads(args.models.read_text()))
        if args.replace_id:
            request["replace_id"] = args.replace_id
    else:
        require(args.plan and not (args.node_id or args.models or args.output or args.replace_id), "apply/rollback requires only --plan")
        request["plan"] = json.loads(args.plan.read_text())
        require(request["plan"].get("host") == args.host, "plan belongs to another Host")
    source = Path(__file__).read_text()
    remote_command = "sudo -n python3 -c " + shlex.quote(source) + " --remote"
    result = subprocess.run(["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                             args.host, remote_command], input=json.dumps(request),
                            text=True, capture_output=True, timeout=120)
    require(result.returncode == 0, result.stderr.strip() or "remote operation failed")
    value = json.loads(result.stdout)
    if args.action == "plan":
        os.umask(0o077)
        save(args.output, value)
    print(json.dumps(value, indent=2, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        print(f"host models: {error}", file=sys.stderr)
        sys.exit(1)
