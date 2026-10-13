#!/usr/bin/env python3
"""Real image and remote shell, synthetic Telegram transport, no live claims."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
image = "gdc-telegram-registration-fixture:%s" % os.getpid()
name = "gdc-telegram-registration-fixture-%s" % os.getpid()
docker = shutil.which("docker")
assert docker, "Docker is required for this lifecycle gate"
remote = (ROOT / "scripts/deploy-telegram-bot.sh").read_text().split("<<'REMOTE'\n", 1)[1].split("\nREMOTE", 1)[0]

with tempfile.TemporaryDirectory(prefix="gdc-telegram-registration-") as temporary:
    fixture = Path(temporary)
    fixture.chmod(0o755)
    tools = fixture / "bin"
    tools.mkdir()
    # Replace only Telegram transport, execute the shipped helper as bot UID
    (fixture / "run.py").write_text('''import io, json, os, runpy
import urllib.request, urllib.error
def open_request(request, timeout):
    assert timeout == 15 and request.get_method() == "POST"
    assert request.full_url.startswith("https://api.telegram.org/botfixture-token/")
    method = request.full_url.rsplit("/", 1)[-1]
    payload = json.loads(request.data)
    commands = [{"command":"api_key", "description":"Issue or replace stable API key"}]
    if method == "getMe": result = {"is_bot": True}
    elif method in ("deleteMyCommands", "setMyCommands"):
        if method == "setMyCommands":
            assert payload == {"scope":{"type":"all_private_chats"}, "commands":commands}
        result = True
    elif method == "getMyCommands": result = commands if payload.get("scope") else []
    else: raise AssertionError("unexpected management call")
    if os.environ.get("FIXTURE_REJECT"):
        raise urllib.error.URLError("private fixture-token must not be printed")
    return io.BytesIO(json.dumps({"ok":True, "result":result}).encode())
urllib.request.urlopen = open_request
runpy.run_path("/app/register-commands.py", run_name="__main__")
''')
    (tools / "docker").write_text('''#!/bin/sh
set -eu
case "$*" in
  "ps -q --filter name=gonka-devnet-bot-bot") printf '%s\\n' "$FIXTURE_CONTAINER" ;;
  "inspect -f {{.State.Health.Status}} "*)
    [ "$4" = "$FIXTURE_CONTAINER" ] || exit 96
    printf 'healthy\\n' ;;
  "exec "*)
    [ "$2" = "$FIXTURE_CONTAINER" ] && [ "$3" = python3 ] && [ "$4" = /app/register-commands.py ] && [ "$#" = 4 ] || exit 97
    exec "$FIXTURE_DOCKER" exec "$2" python3 /fixture/run.py ;;
  *) printf 'unexpected Docker call\\n' >&2; exit 98 ;;
esac
''')
    (tools / "curl").write_text('''#!/bin/sh
set -eu
[ "$*" = "-fsS http://127.0.0.1:9464/metrics" ] || exit 99
printf 'gdc_telegram_bot_up 1\\n'
''')
    for executable in tools.iterdir():
        executable.chmod(0o755)
    state = fixture / "bot.sqlite3"
    state.write_bytes(b"retained-fixture-state-not-a-live-database")
    before = hashlib.sha256(state.read_bytes()).hexdigest()
    environment = {key: value for key, value in os.environ.items() if key != "TELEGRAM_BOT_TOKEN"}
    environment.update(PATH=str(tools) + os.pathsep + os.environ["PATH"], FIXTURE_DOCKER=docker, FIXTURE_CONTAINER=name)
    try:
        subprocess.run([docker, "build", "--network=none", "--pull=false", "-t", image, str(ROOT / "scripts/telegram-bot")], check=True)
        for reject in (False, True):
            command = [docker, "run", "-d", "--name", name, "--network=none", "--read-only",
                       "--mount", "type=bind,src=%s,dst=/fixture,readonly" % fixture,
                       "--mount", "type=bind,src=%s,dst=/data/bot.sqlite3" % state,
                       "-e", "TELEGRAM_BOT_TOKEN=fixture-token", "-e", "PYTHONDONTWRITEBYTECODE=1"]
            if reject:
                command += ["-e", "FIXTURE_REJECT=1"]
            command += [image, "python3", "-c", "import time; time.sleep(300)"]
            subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
            for restart in (False, True):
                if restart:
                    subprocess.run([docker, "restart", name], check=True, stdout=subprocess.DEVNULL)
                result = subprocess.run(["bash", "-s"], input=remote, text=True, env=environment, capture_output=True)
                assert (result.returncode != 0) == reject, result.stderr
                assert "fixture-token" not in result.stdout + result.stderr
                assert hashlib.sha256(state.read_bytes()).hexdigest() == before
            subprocess.run([docker, "rm", "-f", name], check=True, stdout=subprocess.DEVNULL)
    finally:
        subprocess.run([docker, "rm", "-f", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run([docker, "image", "rm", image], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print("PASS real Telegram image and strict remote shell, restart/state preservation and secret-safe rejection")
