#!/usr/bin/env python3
"""Actual official Caddy: generated OPS, compiled preview and egress fences."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = ROOT.parent
IMAGE = "caddy:2.11.4-alpine@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648"
QUERY = "(gdc_devshard_runtime_info * on(host) group_left() gdc_devshard_runtime_observed_at_seconds) and on(host) (gdc_devshard_runtime_scrape_success == 1) and on(host) (time() - gdc_devshard_runtime_observed_at_seconds >= 0) and on(host) (time() - gdc_devshard_runtime_observed_at_seconds <= 90)"
prefix = "gdc-runtime-status-%s" % os.getpid()
network = prefix + "-network"
client_image = prefix + "-client"
containers = []
parent = REPOSITORY / ".data" / "runtime-status-tests"
parent.mkdir(parents=True, exist_ok=True)
evidence = Path(tempfile.mkdtemp(prefix="run.", dir=parent))


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def start(kind, config, port, alias=None):
    name = prefix + "-" + kind
    args = ["docker", "run", "-d", "--name", name, "--network", network,
            "--read-only", "--tmpfs=/data:rw,nosuid,size=32m",
            "--tmpfs=/config:rw,nosuid,size=16m",
            "-v", "%s:/etc/caddy/Caddyfile:ro" % config,
            "-e", "PREVIEW_OBSERVATION_HOST=invalid.example.test",
            "-e", "PREVIEW_PROMETHEUS_ORIGIN=http://127.0.0.1:9099"]
    if alias:
        args += ["--network-alias", alias]
    # Record ownership before launch so failures still clean up exact targets.
    containers.append(name)
    run(*(args + [IMAGE, "caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]))
    return name, port


def request(origin, path, method="GET"):
    code = '''import json,sys,urllib.request,urllib.error
try:
    with urllib.request.urlopen(urllib.request.Request(sys.argv[1],method=sys.argv[2]),timeout=3) as response:
        print(json.dumps([response.status,response.read().decode()]))
except urllib.error.HTTPError as error:
    print(json.dumps([error.code,error.read().decode()]))
'''
    return json.loads(run("docker", "run", "--rm", "--network", "container:" + origin[0],
                         "--read-only", "--cap-drop=ALL", "--security-opt=no-new-privileges",
                         "--entrypoint=python3", client_image, "-c", code,
                         "http://127.0.0.1:%s%s" % (origin[1], path), method))


def ready(origin, path):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        try:
            if request(origin, path)[0] == 200:
                return
        except (OSError, urllib.error.URLError, subprocess.CalledProcessError):
            pass
        time.sleep(1)
    raise AssertionError("Caddy did not become ready: " + str(origin))


try:
    run("docker", "build", "--pull=false", "-f", str(ROOT / "test/Dockerfile"), "-t", client_image, str(ROOT))
    rendered = evidence / "rendered"
    inventory = evidence / "inventory.env"
    inventory.write_text((REPOSITORY / "ops/preview/status-renderer-inventory.env").read_text())
    run("bash", str(ROOT / "04-ops/render-ops.sh"), "--inventory",
        str(inventory), "--output-dir", str(rendered))
    compiled = evidence / "preview.Caddyfile"
    compiler = REPOSITORY / "ops/preview/render-status-backend.sh"
    run("bash", str(compiler), str(rendered / "Caddyfile"), str(rendered / "config.js"), "172", str(compiled))
    # A non-approved runtime expression must fail before a backend is emitted.
    unsafe = evidence / "unsafe.Caddyfile"
    unsafe.write_text((rendered / "Caddyfile").read_text().replace("gdc_devshard_runtime_info", "unsafe_metric"))
    rejected = subprocess.run(["bash", str(compiler), str(unsafe), str(rendered / "config.js"), "172",
                               str(evidence / "rejected.Caddyfile")], capture_output=True, text=True)
    assert rejected.returncode == 1 and "runtime query is not approved" in rejected.stderr
    assert not (evidence / "rejected.Caddyfile").exists()
    fixture = '\n:9099 {\n respond "{http.request.uri}" 200\n}\n'
    ops = evidence / "ops.Caddyfile"
    ops.write_text((rendered / "Caddyfile").read_text() + fixture)
    egress = evidence / "egress.Caddyfile"
    egress.write_text((REPOSITORY / "ops/preview/egress.Caddyfile").read_text() + fixture)
    run("docker", "network", "create", "--internal", network)
    direct = start("ops", ops, 8081)
    guard = start("egress", egress, 8080, "gdc-preview-egress")
    preview = start("preview", compiled, 8080)
    ready(direct, "/status/devshard-runtime")
    ready(preview, "/status/devshard-runtime")
    for origin in [direct, preview]:
        status, body = request(origin, "/status/devshard-runtime?query=up&time=0")
        assert status == 200
        uri = urllib.parse.urlsplit(body)
        assert uri.path == "/api/v1/query"
        assert urllib.parse.parse_qs(uri.query) == {"query": [QUERY]}, body
        for method in ["HEAD", "POST", "PUT", "DELETE", "PATCH"]:
            assert request(origin, "/status/devshard-runtime?query=up", method)[0] == 405
    allowed = "/prometheus/api/v1/query?" + urllib.parse.urlencode({"query": QUERY})
    assert request(guard, allowed)[0] == 200
    assert request(guard, "/prometheus/api/v1/query?query=up")[0] == 404
    for method in ["HEAD", "POST", "PUT", "DELETE", "PATCH"]:
        assert request(guard, allowed, method)[0] == 404
    (evidence / "report.json").write_text(json.dumps({"status": "PASS", "image": IMAGE,
        "scope": "actual Caddy routing, synthetic Prometheus URI response, no live process identity",
        "checks": ["generated OPS", "compiled preview", "exact query overwrite", "GET-only", "egress allowlist", "unsafe compiler rejection"]}, indent=2) + "\n")
    print("PASS actual pinned Caddy OPS/preview/egress GET-only fixed-query fences, evidence " + str(evidence))
finally:
    for name in containers:
        logs = subprocess.run(["docker", "logs", name], capture_output=True, text=True)
        (evidence / (name + ".log")).write_text(logs.stdout + logs.stderr)
        subprocess.run(["docker", "rm", "-f", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["docker", "network", "rm", network], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["docker", "image", "rm", client_image], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
