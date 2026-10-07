#!/usr/bin/env python3
"""Read-only evidence for Versiond health versus its actual running children."""
import argparse
import json
import re
import subprocess
import sys
import time


PROBE = r'''
set -eu
for entry in /proc/[0-9]*/exe; do
  target=$(readlink "$entry" 2>/dev/null) || continue
  case "$target" in
    /opt/versiond/bin/v[345]/devshardd|/opt/versiond/bin/v[345]/*/devshardd) ;;
    *) continue ;;
  esac
  pid=${entry#/proc/}; pid=${pid%/exe}
  # Compare process birth and executable on both sides of the observation
  birth=$(sed 's/.*) //' "/proc/$pid/stat" | awk '{print $20}') || continue
  digest=$(sha256sum "$entry" | awk '{print $1}') || continue
  printf '%s\t%s\t%s\t%s\n' "$pid" "$target" "$birth" "$digest"
done
'''


def command(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=15).stdout


def inspect(container):
    # Never collect Config.Env, command arguments or keyring contents
    metadata = [json.loads(line) for line in command("docker", "inspect", "--format",
        '{{json .Id}}\n{{json .Config.Image}}\n{{json .State.Running}}', container).splitlines()]
    if len(metadata) != 3 or metadata[2] is not True:
        raise ValueError("Versiond container is not running")
    container = metadata[0]  # Probe the immutable ID, never a replacement name
    health = json.loads(command("docker", "exec", container, "wget", "-qO-", "-T", "5",
                                "http://127.0.0.1:8080/healthz"))
    if not isinstance(health, list):
        raise ValueError("Versiond health must be an array")
    entries = {}
    for entry in health:
        slot = entry.get("name") if isinstance(entry, dict) else None
        if slot not in ("v3", "v4", "v5") or slot in entries:
            raise ValueError("Unsupported or duplicate Versiond health slot")
        entries[slot] = {"slot": slot, "status": entry.get("status"),
                         "port": entry.get("port"),
                         "reported_binary_version": entry.get("binary_version"),
                         "archive_sha256": entry.get("sha256"), "processes": []}
    first = command("docker", "exec", container, "sh", "-c", PROBE)
    observed = []
    for line in first.splitlines():
        pid, path, birth, digest = line.split('\t')
        match = re.fullmatch(r"/opt/versiond/bin/(v[345])/(?:[0-9a-f]{64}/)?devshardd", path)
        if not (pid.isdecimal() and birth.isdecimal() and match
                and re.fullmatch(r"[0-9a-f]{64}", digest)):
            raise ValueError("Invalid process identity evidence")
        slot = match[1]
        if slot not in entries or entries[slot]["status"] != "running":
            raise ValueError("Running process disagrees with Versiond health")
        version = None
        try:
            value = command("docker", "exec", container, "sh", "-c",
                            'command -v timeout >/dev/null || exit 2; '
                            'exec timeout 5 "$1" --print-binary-version',
                            "sh", f"/proc/{pid}/exe").strip()
            if re.fullmatch(r"v?[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?", value):
                version = value
        except (subprocess.SubprocessError, OSError):
            pass  # Old releases may lack the flag, never substitute the slot
        entries[slot]["processes"].append({"pid": int(pid), "start_ticks": int(birth),
            "executable": path, "binary_sha256": digest, "binary_version": version})
        observed.append(line)
    second = command("docker", "exec", container, "sh", "-c", PROBE)
    if sorted(observed) != sorted(second.splitlines()):
        raise ValueError("Runtime changed during inspection, retry a fresh observation")
    for entry in entries.values():
        if entry["status"] == "running" and len(entry["processes"]) != 1:
            raise ValueError("Running slot must have exactly one observed child")
    return {"schema_version": 1, "container_id": metadata[0], "image": metadata[1],
            "slots": list(entries.values()),
            "absent_slots": sorted({"v3", "v4", "v5"} - entries.keys())}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--container", required=True)
    parser.add_argument("--prometheus-host")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", args.container):
        parser.error("invalid container identifier")
    if args.prometheus_host and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", args.prometheus_host):
        parser.error("invalid monitoring Host")
    try:
        result = inspect(args.container)
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError):
        # Do not echo Docker output that might contain operator material
        print("Runtime identity inspection failed, no complete snapshot emitted", file=sys.stderr)
        return 1
    if args.prometheus_host:
        print(prometheus(result, args.prometheus_host, time.time()), end="")
    else:
        print(json.dumps(result, sort_keys=True, indent=2))
    return 0


def prometheus(result, host, observed_at):
    """Allowlist observed child identity, never publish process paths or IDs."""
    lines = [f'gdc_devshard_runtime_scrape_success{{host="{host}"}} 1',
             f'gdc_devshard_runtime_observed_at_seconds{{host="{host}"}} {observed_at}']
    for slot in result["slots"]:
        if slot["status"] != "running":
            continue
        process = slot["processes"][0]
        slot_name, binary_hash = slot["slot"], process["binary_sha256"]
        version = process["binary_version"] or "unreported"
        archive = slot["archive_sha256"]
        archive = archive if isinstance(archive, str) and re.fullmatch(r"[0-9a-f]{64}", archive) else "unreported"
        lines.append(f'gdc_devshard_runtime_info{{host="{host}",slot="{slot_name}",version="{version}",'
                     f'binary_sha256="{binary_hash}",archive_sha256="{archive}",source="process"}} 1')
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    sys.exit(main())
