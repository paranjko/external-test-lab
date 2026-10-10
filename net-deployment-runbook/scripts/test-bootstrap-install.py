#!/usr/bin/env python3
"""Run only inside a disposable root with /srv/dai on a fresh tmpfs.

Exercises the real installer and entrypoints, using synthetic runtime archives,
Compose config (no daemon), and a recording Cosmovisor instead of live services.
"""
import hashlib
import json
import os
from pathlib import Path
import runpy
import shutil
import unittest
import zipfile

if os.geteuid() != 0 or os.environ.get("GDC_TEST_DISPOSABLE_ROOT") != "true" or not Path("/.dockerenv").exists():
    raise SystemExit("Run in a disposable root with GDC_TEST_DISPOSABLE_ROOT=true")
if any(Path("/srv/dai").iterdir()):
    raise SystemExit("Refusing a non-empty /srv/dai")
support = runpy.run_path(str(Path(__file__).with_name("test-bootstrap-join.py")))
ROOT = support["ROOT"]


class BootstrapInstall(support["BootstrapJoin"]):
    def test_installer_and_entrypoints(self):
        archives = self.tmp / "archives"
        archives.mkdir()
        for role, binary in (("node", "inferenced"), ("api", "decentralized-api")):
            archive = archives / (role + ".zip")
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr(binary, "#!/bin/sh\necho bootstrap-runtime-fixture\n")
                output.writestr("libgcc_s.so.1", "fixture library")
            artifact = self.document["software"]["components"][role]["upgrade"]["artifact"]
            artifact.update(url="https://example.test/" + role + ".zip",
                            sha256=hashlib.sha256(archive.read_bytes()).hexdigest())
        self.bootstrap.write_text(json.dumps(self.document))
        original_node_archive = (archives / "node.zip").read_bytes()
        self.compile()
        self.prepare_compose_env()
        self.env["ARCHIVES"] = str(archives)
        (self.bin / "curl").write_text('#!/bin/bash\nset -eu\nwhile (($#)); do\n'
            'case $1 in https://example.test/*) url=$1;; -o) shift; output=$1;; esac\nshift\ndone\n'
            'cp "$ARCHIVES/${url##*/}" "$output"\n')
        config = self.tmp / "node-config.json"
        config.write_text("[]\n")
        genesis = self.tmp / "genesis.json"
        genesis.write_text("{}\n")
        destination = Path("/srv/dai/deploy")
        work = self.tmp / "entrypoint"
        work.mkdir()
        (work / "init-docker.sh").write_text('#!/bin/sh\ninferenced version\n')
        Path("/root/api-config.yaml").write_text("fixture: true\n")
        cosmovisor = self.bin / "cosmovisor"
        cosmovisor.write_text('#!/bin/sh\ntest "$1" = run\necho COSMOVISOR\n')
        cosmovisor.chmod(0o755)
        for layout in ("data.generations/fixture", "gdc-node9"):
            with self.subTest(layout=layout):
                data = Path("/srv/dai") / layout
                self.env.update(DATA_DIR=str(data), IDENTITY_DIR="/srv/dai/identity", SIGNER_DIR="/srv/dai/signer",
                    GDC_PROFILE_KIND="generated_join", GDC_JOIN_PROFILE_SHA256=hashlib.sha256(self.profile.read_bytes()).hexdigest())
                env_file = self.tmp / "node.env"
                env_file.write_text("".join(key + "=" + value + "\n" for key, value in self.env.items()))
                command = ["bash", ROOT / "02-node/install-node.sh", "--node-name", "fixture", "--env", env_file,
                    "--node-config", config, "--genesis", genesis, "--join-profile", self.profile]
                self.run_command(*command)
                self.run_command(*command)  # same descriptor can be staged again
                installed = json.loads(self.run_command("docker", "compose", "--env-file", destination / ".env",
                    "--profile", "*", "-f", destination / "compose.yaml", "config", "--format", "json").stdout)
                mounts = {mount["target"]: mount["source"] for mount in installed["services"]["node"]["volumes"]}
                self.assertEqual(mounts["/root/.inference"], str(data / "inference"))
                self.assertEqual(mounts["/gdc-bootstrap-runtime"], str(destination / "bootstrap-runtime"))
                helper = Path("/usr/local/bin/gdc-bootstrap-runtime")
                if not helper.exists():
                    helper.symlink_to(destination / "bootstrap-runtime.sh")
                    Path("/gdc-bootstrap-runtime").symlink_to(destination / "bootstrap-runtime")
                self.env.update(GDC_BOOTSTRAP_SOFTWARE="true", STATE_DIR=str(data / "inference"), INIT_ONLY="true")
                for _ in range(2):
                    result = self.run_command("sh", "-x", destination / "node-entrypoint.sh", cwd=work)
                    self.assertEqual(result.stdout, "bootstrap-runtime-fixture\n")
                    result = self.run_command("sh", destination / "api-entrypoint.sh", data / "dapi", cwd=work)
                    self.assertEqual(result.stdout, "COSMOVISOR\n")
                self.assertTrue((data / "dapi/.nats").is_dir())
                self.assertTrue((data / "dapi/api-config.yaml").is_file())
                # A corrupt download must not replace an already installed deployment.
                before = (destination / "compose.yaml").read_bytes()
                (archives / "node.zip").write_bytes(b"corrupt")
                self.run_command(*command, success=False)
                self.assertEqual((destination / "compose.yaml").read_bytes(), before)
                self.assertFalse(list(Path("/srv/dai").glob(".gdc-stage.*")))
                # Restore the fixture for the other layout, never touch host state.
                (archives / "node.zip").write_bytes(original_node_archive)
                shutil.rmtree(destination)


if __name__ == "__main__":
    unittest.main(defaultTest="BootstrapInstall.test_installer_and_entrypoints")
