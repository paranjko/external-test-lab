#!/usr/bin/env python3
"""Exercise OPS observer assets from both source and remote-staged layouts.

Run only in a disposable root container with a fresh /srv/dai tmpfs. Each
layout gets a clean install target and performs both site and monitoring
installs so the second component cannot hide a missing staged helper.
"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
if os.geteuid() != 0 or os.environ.get("GDC_TEST_DISPOSABLE_ROOT") != "true" or not Path("/.dockerenv").exists():
    raise SystemExit("Run inside a disposable root container with GDC_TEST_DISPOSABLE_ROOT=true")

DESTINATION = Path("/srv/dai/ops")
LIBRARY = Path("/usr/local/lib/gonka-devnet")
NETWORK_ENV = Path("/etc/gonka/gdc-network-observer.env")
SYSTEMD = Path("/etc/systemd/system")
UNITS = (
    "gdc-gateway-health-probe.service",
    "gdc-gateway-health-probe.timer",
    "gdc-participants-proxy.socket",
    "gdc-participants-proxy@.service",
    "gdc-network-observer.service",
    "gdc-network-observer.timer",
    "gdc-network-observer.socket",
    "gdc-network-observer@.service",
    "gdc-gateway-reserve-controller.service",
    "gdc-gateway-reserve-controller.timer",
)
if any(path.exists() for path in (DESTINATION, LIBRARY, NETWORK_ENV)) or any(
    (SYSTEMD / unit).exists() for unit in UNITS
):
    raise SystemExit("Refusing an existing OPS install; use fresh disposable /srv/dai and system paths")
SYSTEMD.mkdir(parents=True, exist_ok=True)

with tempfile.TemporaryDirectory(prefix="gdc-network-observer-install-") as temporary:
    tmp = Path(temporary)
    render = tmp / "render"
    bindir = tmp / "bin"
    render.mkdir()
    bindir.mkdir()
    (render / ".env").write_text("SITE_HOST=fixture.test\n")
    (render / "config.js").write_text("window.GDC_CONFIG = {};\n")
    (render / "Caddyfile").write_text(
        "http://:8081 { handle /status/network/ws { reverse_proxy 127.0.0.1:18094 } }\n"
    )
    (render / "network-observer.env").write_text(
        "GDC_NETWORK_CHAIN_ID=fixture-chain\nGDC_NETWORK_BOOTSTRAP_URL=https://fixture.test/bootstrap.json\n"
    )
    (render / "prometheus.yml").write_text("global: {scrape_interval: 15s}\n")
    systemctl = bindir / "systemctl"
    systemctl.write_text("#!/bin/sh\nexit 0\n")
    systemctl.chmod(0o755)
    env = {**os.environ, "PATH": f"{bindir}:{os.environ['PATH']}", "SUDO_USER": "root"}

    staged_ops = tmp / "remote" / "04-ops"
    shutil.copytree(ROOT / "04-ops", staged_ops)
    staged_helpers = {
        "gateway-reserve-policy.sh": ROOT / "scripts/gateway-reserve-policy.sh",
        "lib-lock.sh": ROOT / "scripts/lib-lock.sh",
    }
    for name, source in staged_helpers.items():
        shutil.copyfile(source, staged_ops / name)

    def reset_install_state():
        shutil.rmtree(DESTINATION, ignore_errors=True)
        shutil.rmtree(LIBRARY, ignore_errors=True)
        NETWORK_ENV.unlink(missing_ok=True)
        for unit in UNITS:
            (SYSTEMD / unit).unlink(missing_ok=True)

    def install(ops_dir, component):
        result = subprocess.run(
            ["bash", str(ops_dir / "install-ops.sh"), "--component", component,
             "--render-dir", str(render)],
            env=env, check=False, capture_output=True, text=True, timeout=45,
        )
        if result.returncode != 0:
            raise SystemExit(result.stderr + result.stdout)

    def verify_install(layout):
        installed_script = Path("/usr/local/lib/gonka-devnet/network-observer-http.py")
        installed_unit = SYSTEMD / "gdc-network-observer@.service"
        if not installed_script.is_file() or not os.access(installed_script, os.X_OK):
            raise SystemExit(f"{layout}: clean site install did not install executable observer adapter")
        if "network-observer-http.py" not in installed_unit.read_text():
            raise SystemExit(f"{layout}: clean site install did not install adapter-backed socket unit")
        installed_policy = Path("/usr/local/lib/gonka-devnet/gateway-reserve-policy.sh")
        installed_lock = Path("/usr/local/lib/gonka-devnet/lib-lock.sh")
        if installed_policy.read_bytes() != staged_helpers["gateway-reserve-policy.sh"].read_bytes():
            raise SystemExit(f"{layout}: installer did not select the expected reserve policy")
        if installed_lock.read_bytes() != staged_helpers["lib-lock.sh"].read_bytes():
            raise SystemExit(f"{layout}: installer did not select the expected shared lock helper")

    layouts = (("repository", ROOT / "04-ops"), ("remote-staged", staged_ops))
    for index, (layout, ops_dir) in enumerate(layouts):
        if index:
            reset_install_state()
        if DESTINATION.exists() or LIBRARY.exists() or NETWORK_ENV.exists():
            raise SystemExit(f"{layout}: install fixture was not clean before site install")
        install(ops_dir, "site")
        verify_install(layout)
        install(ops_dir, "monitoring")
        verify_install(layout)
        if "status/network/ws" not in (DESTINATION / "Caddyfile").read_text():
            raise SystemExit(f"{layout}: subsequent monitoring install lost the rendered WebSocket route")
        print(f"PASS {layout} clean site then monitoring OPS installs retain observer and shared helpers")

    reset_install_state()
