#!/usr/bin/env python3
"""Run the real installer and native archive; replace only HTTPS transport."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

import release


def main():
    assets = release.ROOT.parent / "build/gonkactl-release"
    release.verify(assets)
    with tempfile.TemporaryDirectory(prefix="ctl-native-install-") as directory:
        root = Path(directory)
        commands = root / "bin"
        commands.mkdir()
        transport = commands / "curl"
        transport.write_text("""#!/bin/sh
set -eu
out=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in --output) shift; out=$1;; https:*) url=$1;; esac
  shift
done
case "$url" in
  https://github.com/paranjko/external-test-lab/releases/download/gonkactl-v1.0.0-alpha.3/*) ;;
  *) exit 71;;
esac
cp "$TEST_ASSETS/${url##*/}" "$out"
""")
        transport.chmod(0o755)
        home = root / "home"
        home.mkdir()
        env = dict(os.environ, HOME=str(home), PATH=f"{commands}:" + os.environ["PATH"],
                   TEST_ASSETS=str(assets))
        for key in list(env):
            if key.startswith(("GDC_", "GONKACTL_")):
                del env[key]
        installer = release.ROOT.parent / "net-deployment-runbook/04-ops/site/ctl/install.sh"
        subprocess.run(["sh"], input=installer.read_bytes(), env=env, check=True)
        binary = home / ".local/bin/gonkactl"
        result = subprocess.check_output([str(binary), "version"], text=True)
        metadata = json.loads((assets / "build.json").read_text())
        expected = f"{release.VERSION}\ncommit: {metadata['commit']}\nbuilt: {metadata['build_time']}\n"
        if result != expected:
            raise ValueError("installed binary metadata does not match release")
        subprocess.run([str(binary), "--help"], check=True)
        for command in ("update", "validate"):
            subprocess.run([str(binary), "bootstrap", command, "--help"], check=True)
        print("Native archive installed through piped POSIX installer in an empty HOME")


if __name__ == "__main__":
    main()
