#!/usr/bin/env python3
"""Execute the shipped deployer with strict transports and disposable Host state."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

# Every transport invocation is recorded, unexpected operations fail closed.
TRANSPORT = r'''#!/usr/bin/env python3
import json, os, pathlib, re, shutil, sys
root = pathlib.Path(os.environ["FIXTURE_ROOT"])
kind = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps([kind, args]) + "\n")
def require(value):
    if not value:
        (root / "unexpected").write_text(json.dumps([kind, args]))
        raise SystemExit(97)
if kind == "getent":
    require(args[:1] == ["ahostsv4"] and args[1] in ["ops.example.test", "old.example.test"])
    print("192.0.2.10 STREAM fixture")
elif kind == "rsync":
    require(args[:8] == ["-a", "--delete", "--exclude", ".env", "--exclude", "data", "--exclude", "__pycache__"])
    require(len(args) == 10 and args[8].endswith("/scripts/telegram-bot/"))
    require(re.fullmatch(r"ops:/tmp/gdc-telegram-bot-\d+/source/", args[9]))
    shutil.copytree(args[8], root / "uploaded", dirs_exist_ok=True)
elif kind == "scp":
    require(len(args) == 3 and args[0] == "-q")
    require(re.fullmatch(r"ops:/tmp/gdc-telegram-bot-\d+/bot.env", args[2]))
    shutil.copyfile(args[1], root / "uploaded.env")
elif kind == "ssh":
    if args[:1] == ["-T"]: args = args[1:]
    require(len(args) == 2 and args[0] in ["ops", "old"])
    host, command = args
    if command == "docker info >/dev/null 2>&1":
        require(host == "old")
    elif command.startswith("sudo install -d -m 0750 "):
        require(host == "ops" and command == "sudo install -d -m 0750 '/srv/dai/gonka-devnet-bot' '/srv/dai/gonka-devnet-bot/data'; sudo install -d -m 0755 /var/lib/node_exporter/textfile_collector")
    elif re.fullmatch(r"rm -rf '/tmp/gdc-telegram-bot-\d+' && mkdir -p '/tmp/gdc-telegram-bot-\d+'", command):
        require(host == "ops")
    elif command.startswith("set -Eeuo pipefail\n  sudo cp -a "):
        require(host == "ops")
        expected = """set -Eeuo pipefail
  sudo cp -a 'REMOTE/source/.' '/srv/dai/gonka-devnet-bot/'
  sudo install -o root -g root -m 0600 'REMOTE/bot.env' '/srv/dai/gonka-devnet-bot/bot.env'
  rm -rf 'REMOTE'
  sudo chown -R root:root '/srv/dai/gonka-devnet-bot'
  sudo chown -R 10001:10001 '/srv/dai/gonka-devnet-bot/data'
  sudo chown 10001:10001 /var/lib/node_exporter/textfile_collector
  sudo rm -f '/srv/dai/gonka-devnet-bot/gateway-key-pool.json' '/srv/dai/gonka-devnet-bot/.env'
  cd '/srv/dai/gonka-devnet-bot'
  sudo docker compose up -d --build --force-recreate >/dev/null"""
        require(re.sub(r"/tmp/gdc-telegram-bot-\d+", "REMOTE", command) == expected)
        shutil.copytree(root / "uploaded", root / "bot", dirs_exist_ok=True)
        shutil.copyfile(root / "uploaded.env", root / "bot/bot.env")
        (root / "applied").touch()
    elif command == "bash -s":
        require(host == "ops")
        source = pathlib.Path(os.environ["FIXTURE_DEPLOY"]).read_text()
        expected = source.split("<<'REMOTE'\n", 1)[1].split("\nREMOTE", 1)[0] + "\n"
        require(sys.stdin.read() == expected)
        (root / "ready").touch()
    elif command.startswith("bash -s -- "):
        require(host == "ops" and re.fullmatch(r"bash -s -- '[^']+' '[0-9]+'", command))
        require(sys.stdin.read() == pathlib.Path(os.environ["FIXTURE_PROBE"]).read_text())
        require((root / "ready").exists())
        (root / "probe").touch()
    elif command == "docker ps --format \"{{.Names}}\" | grep -qx gonka-devnet-bot-bot-1":
        require(host == "ops" and (root / "probe").exists())
    elif command == "! docker ps --format \"{{.Names}}\" | grep -qx gonka-devnet-bot-bot-1":
        require(host == "old")
    elif command == """set -Eeuo pipefail
    docker ps -q --filter name=gonka-devnet-bot-bot | xargs -r docker stop >/dev/null
    sudo rm -f /var/lib/node_exporter/textfile_collector/telegram-bot.prom""":
        require(host == "old")
        (root / "old-poller-stopped").touch()
    else: require(False)
else: require(False)
'''


class DeploymentLayouts(unittest.TestCase):
    def test_flat_and_legacy_preserve_host_state(self):
        for layout in ("flat", "legacy"):
            with self.subTest(layout=layout), tempfile.TemporaryDirectory(prefix="gdc-bot-layout-") as temporary:
                fixture = Path(temporary)
                tools = fixture / "bin"
                tools.mkdir()
                dispatcher = tools / "dispatcher"
                dispatcher.write_text(TRANSPORT)
                dispatcher.chmod(0o755)
                for name in ("ssh", "scp", "rsync", "getent"):
                    (tools / name).symlink_to(dispatcher)
                home = fixture / "empty-home"
                home.mkdir()
                data = fixture / "gdc"
                secrets = data / "state/secrets"
                secrets.mkdir(parents=True)
                for name in ("gateway.telegram-a-client-key", "gateway.telegram-b-client-key",
                             "telegram.conversation-api-token", "telegram.faucet-token", "bifrost.broker-token"):
                    (secrets / name).write_text("fixture-" + name)
                config = data / ".env"
                config.write_text('GDC_NODE_ALIASES="ops old"\nGDC_NODE_PUBLIC_HOSTS="ops=ops.example.test old=old.example.test"\n'
                                  'GDC_NODE_P2P_PORTS="ops=5000 old=5000"\nGDC_NODE_GPU_PROFILES="ops=a5000-24g old=t4-16g"\n'
                                  'GDC_GATEWAY_NODE=ops\nGDC_TELEGRAM_BOT_HOST=ops\nTELEGRAM_BOT_TOKEN=fixture-token\n'
                                  'GDC_GRAFANA_HOST=metrics.example.test\n')
                # Deployer owns a fixed standalone bot path, neither Host layout.
                host = fixture / "host/deploy"
                if layout == "legacy": host /= "ops"
                host.mkdir(parents=True)
                (host / "compose.yaml").write_text("retained Host compose\n")
                (host / "identity").write_bytes(b"retained Host identity")
                (fixture / "bot/data").mkdir(parents=True)
                (fixture / "bot/data/bot.sqlite3").write_bytes(b"retained bot database")
                before = {p: p.read_bytes() for p in (host / "compose.yaml", host / "identity", fixture / "bot/data/bot.sqlite3")}
                environment = {"HOME": str(home), "PATH": str(tools) + ":/usr/local/bin:/usr/bin:/bin",
                               "GDC_HOME": str(data), "FIXTURE_ROOT": str(fixture),
                               "FIXTURE_DEPLOY": str(ROOT / "scripts/deploy-telegram-bot.sh"),
                               "FIXTURE_PROBE": str(ROOT / "scripts/telegram-consumer-probe-loop.sh")}
                result = subprocess.run(["bash", environment["FIXTURE_DEPLOY"]], env=environment,
                                        text=True, capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse((fixture / "unexpected").exists())
                for path, content in before.items(): self.assertEqual(path.read_bytes(), content)
                self.assertTrue((fixture / "old-poller-stopped").exists())
                self.assertTrue((fixture / "probe").exists())
                env = dict(line.split("=", 1) for line in (fixture / "bot/bot.env").read_text().splitlines())
                self.assertEqual(env["GATEWAY_TRAFFIC_METRICS_URL"], "https://metrics.example.test/api/datasources/proxy/uid/prometheus/api/v1/query")
                backends = json.loads(env["GATEWAY_BACKENDS_JSON"])
                self.assertEqual([b["name"] for b in backends], ["A", "B"])
                self.assertTrue((fixture / "bot/gateway_traffic.py").is_file())
                self.assertNotIn("fixture-token", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
