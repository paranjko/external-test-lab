#!/usr/bin/env python3
"""Behavioral software -> profile -> deployment/runtime tests, without SSH."""
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile
from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parent.parent


class BootstrapJoin(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="gdc-bootstrap-join-")
        self.addCleanup(self.temporary.cleanup)
        self.tmp = Path(self.temporary.name)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.env = {"PATH": str(self.bin) + ":" + os.environ["PATH"], "HOME": str(self.tmp)}
        for tool in ("ssh", "scp", "curl", "wget", "inferenced"):
            stub = self.bin / tool
            stub.write_text("#!/bin/sh\necho unexpected external call >&2\nexit 97\n")
            stub.chmod(0o755)
        self.document = json.loads((ROOT.parent / "bootstrap/gonka-devnet-community.json").read_text())
        self.bootstrap = self.tmp / "bootstrap.json"
        self.bootstrap.write_text(json.dumps(self.document))
        self.observation = self.tmp / "observation.json"
        self.components = self.tmp / "components.json"
        self.profile = self.tmp / "profile.json"

    def run_command(self, *args, success=True, **kwargs):
        result = subprocess.run([str(arg) for arg in args], env=self.env, capture_output=True,
                                text=True, timeout=30, **kwargs)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def compile(self, source=None):
        args = ["bash", ROOT / "scripts/observe-network-state.sh", "--bootstrap-file", self.bootstrap,
                "--bootstrap-url", "https://example.test/bootstrap.json", "--chain-id",
                self.document["chain_id"], "--run-id", "fixture", "--output", self.observation]
        if source:
            args += ["--source-rpc", source]
        self.run_command(*args)
        self.run_command("bash", ROOT / "scripts/resolve-join-components.sh", "--observation",
                         self.observation, "--output", self.components)
        self.run_command("bash", ROOT / "scripts/resolve-join-profile.sh", "--observation", self.observation,
                         "--components", self.components, "--node-name", "fixture",
                         "--public-host", "fixture.example.test", "--operation", "new",
                         "--run-id", "fixture", "--output", self.profile)
        return json.loads(self.profile.read_text())

    def test_actual_join_preflight_uses_declaration_without_remote_calls(self):
        self.env["GDC_HOME"] = str(self.tmp / "operator")
        result = self.run_command("bash", ROOT / "gdc.sh", "host", "join", "--preflight",
            "--bootstrap-file", self.bootstrap, "--public-host", "fixture.example.test", "fixture")
        self.assertIn("PASS JOIN preflight completed without Host mutation", result.stdout)
        self.assertNotIn("WAIT JOIN software observation", result.stdout)
        retained = list((self.tmp / "operator/fixture/runs").glob("*/join-fixture/join-profile.v1.json"))
        self.assertEqual(len(retained), 1)
        profile = json.loads(retained[0].read_text())
        self.assertEqual(profile["spec"]["deployment"]["software"], self.document["software"])

    def test_declaration_compiles_without_network_and_preserves_source_authority(self):
        profile = self.compile(self.document["seeds"][0]["rpc"])
        self.assertEqual(profile["spec"]["deployment"]["software"], self.document["software"])
        schema = json.loads((ROOT.parent / "schema/join-profile.v1.schema.json").read_text())
        Draft202012Validator(schema).validate(profile)
        self.assertEqual(profile["spec"]["state_acquisition"]["trust_authority"]["rpc_url"],
                         self.document["seeds"][0]["rpc"])
        self.assertEqual(json.loads(self.observation.read_text())["runtime_api_origins"], [])
        core = profile["spec"]["components"]["core"]["installation"]
        self.assertNotEqual(core["binary"]["sha256"], core["runtime_upgrade"]["artifact"]["sha256"])
        self.assertEqual(core["runtime_upgrade"]["name"], "v0.2.16")
        self.assertEqual(profile["spec"]["components"]["core"]["expected_runtime"]["version"], "0.2.16-post1")
        before = profile["profile_id"]
        self.assertEqual(self.compile(self.document["seeds"][0]["rpc"])["profile_id"], before)

    def test_unsupported_present_software_never_falls_back(self):
        for field, value in (("platform", "linux/arm64"), ("accelerator", "rocm"),
                             ("model", {**self.document["software"]["model"], "id": "Unknown/Model"}),
                             ("deployment", {**self.document["software"]["deployment"], "compose_files": [
                                 {"path": "deploy/join/docker-compose.yml", "sha256": "f" * 64}]})):
            with self.subTest(field=field):
                doc = copy.deepcopy(self.document)
                doc["software"][field] = value
                self.bootstrap.write_text(json.dumps(doc))
                result = self.run_command("bash", ROOT / "scripts/observe-network-state.sh",
                    "--bootstrap-file", self.bootstrap, "--bootstrap-url", "https://example.test/bootstrap.json",
                    "--chain-id", doc["chain_id"], "--run-id", "fixture", "--output", self.observation, success=False)
                self.assertIn("bootstrap_software_unsupported", result.stderr)
                self.assertNotIn("unexpected external call", result.stderr)
                self.assertFalse(self.observation.exists())

    def test_model_arguments_come_from_declaration(self):
        model = self.document["software"]["model"]
        model.update(context_length=4096, max_num_seqs=17, gpu_memory_utilization=0.7,
                     dtype="float16", tensor_parallel_size=2)
        self.bootstrap.write_text(json.dumps(self.document))
        self.compile()
        output = self.tmp / "node-config.json"
        self.run_command("bash", ROOT / "02-node/render-node-config.sh", "--node-name", "fixture",
            "--runtime-id", "qwen3-0.6b:gonka1wz8n3avzmma55z880jdrn8h5dg6nd2lrse4ar3",
            "--join-profile", self.profile, "--output", output)
        config = json.loads(output.read_text())[0]
        self.assertEqual(config["max_concurrent"], 17)
        args = config["models"][model["id"]]["args"]
        for flag, expected in (("--revision", model["revision"]), ("--max-model-len", "4096"),
                               ("--max-num-seqs", "17"), ("--gpu-memory-utilization", "0.7"),
                               ("--dtype", "float16"), ("--tensor-parallel-size", "2")):
            self.assertEqual(args[args.index(flag) + 1], expected)

    def test_devnet_declaration_matches_release_and_model_layers(self):
        release = {}
        for line in (ROOT / "profiles/releases/v2026.10.06.lock").read_text().splitlines():
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                release[key] = value
        mapping = {"node":"INFERENCED_IMAGE", "api":"DAPI_IMAGE", "tmkms":"TMKMS_IMAGE", "mlnode":"MLNODE_GENERIC_IMAGE",
                   "proxy":"PROXY_IMAGE", "proxy-policy":"PROXY_POLICY_IMAGE", "versiond":"VERSIOND_IMAGE",
                   "versiond-router":"VERSIOND_ROUTER_IMAGE", "edge-api":"EDGE_API_IMAGE", "bridge":"BRIDGE_IMAGE"}
        software = self.document["software"]
        for role, variable in mapping.items():
            self.assertEqual(software["components"][role]["image"], release[variable])
        for role, prefix in (("node", "INFERENCED"), ("api", "DAPI")):
            upgrade = software["components"][role]["upgrade"]
            self.assertEqual(upgrade["name"], release["UPGRADE_PLAN_NAME"])
            self.assertEqual(upgrade["artifact"]["url"], release[prefix + "_UPGRADE_URL"])
            self.assertEqual(upgrade["artifact"]["sha256"], release[prefix + "_UPGRADE_SHA256"])
        self.assertEqual(software["operator_cli"]["artifact"]["sha256"], release["INFERENCED_OPERATOR_SHA256_LINUX_AMD64"])
        self.assertEqual(software["deployment"]["commit"], release["GONKA_COMMIT"])

    def test_profile_cannot_override_pins_even_with_recomputed_profile_id(self):
        profile = self.compile()
        profile["spec"]["components"]["core"]["installation"]["image"]["digest"] = "sha256:" + "f" * 64
        canonical = json.dumps(profile["spec"], sort_keys=True, separators=(",", ":")) + "\n"
        profile["profile_id"] = hashlib.sha256(canonical.encode()).hexdigest()
        self.profile.write_text(json.dumps(profile))
        result = self.run_command("bash", ROOT / "scripts/join-profile.sh", "validate", self.profile, success=False)
        self.assertIn("differs from Bootstrap", result.stderr)

    def test_runtime_installation_flat_legacy_restart_upgrade_and_corruption(self):
        profile = self.compile()
        archives = self.tmp / "archives"
        archives.mkdir()
        for role, binary in (("node", "inferenced"), ("api", "decentralized-api")):
            archive = archives / (role + ".zip")
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr(binary, "#!/bin/sh\nprintf 'runtime fixture\\n'\n")
                if role == "api":
                    output.writestr("inferenced", "#!/bin/sh\nprintf 'co-packaged runtime fixture\\n'\n")
                output.writestr("libgcc_s.so.1", "fixture library")
                output.writestr("wrapped_token.wasm", "fixture wasm")
            artifact = profile["spec"]["deployment"]["software"]["components"][role]["upgrade"]["artifact"]
            artifact["url"] = "https://example.test/" + role + ".zip"
            artifact["sha256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
        self.profile.write_text(json.dumps(profile))
        self.env["ARCHIVES"] = str(archives)
        (self.bin / "curl").write_text("#!/bin/bash\nset -eu\nwhile (($#)); do\n"
            "case $1 in https://example.test/*) url=$1;; -o) shift; output=$1;; esac\nshift\ndone\n"
            'cp "$ARCHIVES/${url##*/}" "$output"\n')
        staged = self.tmp / "staged"
        staged.mkdir()
        self.run_command("bash", ROOT / "02-node/prepare-bootstrap-runtime.sh", self.profile, staged)
        for layout in ("data.generations/fixture", "gdc-node9"):
            for role, folder, binary in (("node", "inference", "inferenced"), ("api", "dapi", "decentralized-api")):
                with self.subTest(layout=layout, role=role):
                    state = self.tmp / layout / folder
                    package = staged / "bootstrap-runtime" / role
                    command = ["sh", ROOT / "02-node/bootstrap-runtime.sh", state, package, binary]
                    self.run_command(*command)
                    self.assertEqual((state / "cosmovisor/current/bin/libgcc_s.so.1").read_bytes(), b"fixture library")
                    self.assertEqual(self.run_command(state / "cosmovisor/current/bin" / binary).stdout, "runtime fixture\n")
                    if role == "api":
                        self.assertEqual(self.run_command(state / "cosmovisor/current/bin/inferenced").stdout,
                                         "co-packaged runtime fixture\n")
                    self.run_command(*command)
                    current = state / "cosmovisor/current"
                    upgraded = state / "cosmovisor/upgrades/next/bin"
                    upgraded.mkdir(parents=True)
                    shutil.copy2(package / "bin" / binary, upgraded / binary)
                    current.unlink()
                    current.symlink_to("upgrades/next")
                    self.run_command(*command)
                    self.assertEqual(os.readlink(current), "upgrades/next")
                    (state / "cosmovisor/genesis/bin/libgcc_s.so.1").write_text("corrupt")
                    self.run_command(*command, success=False)
                    self.assertEqual(os.readlink(current), "upgrades/next")

    def test_archive_digest_and_paths_are_checked_before_installation(self):
        profile = self.compile()
        archive = self.tmp / "malicious.zip"
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("../../escape", "not allowed")
        self.env["ARCHIVE"] = str(archive)
        (self.bin / "curl").write_text('#!/bin/bash\nset -eu\nwhile (($#)); do if [[ $1 == -o ]]; then shift; output=$1; fi; shift; done\ncp "$ARCHIVE" "$output"\n')
        for digest, expected in (("a" * 64, "FAILED"), (hashlib.sha256(archive.read_bytes()).hexdigest(), "unsupported node runtime archive entry")):
            profile["spec"]["deployment"]["software"]["components"]["node"]["upgrade"]["artifact"]["sha256"] = digest
            self.profile.write_text(json.dumps(profile))
            destination = self.tmp / digest
            destination.mkdir()
            result = self.run_command("bash", ROOT / "02-node/prepare-bootstrap-runtime.sh", self.profile, destination, success=False)
            self.assertIn(expected, result.stderr + result.stdout)
            self.assertFalse((self.tmp / "escape").exists())

    def prepare_compose_env(self):
        loader = '. "$1"; load_join_profile "$2"; env'
        loaded = self.run_command("bash", "-c", loader, "_", ROOT / "scripts/profile.sh", self.profile)
        variables = dict(line.split("=", 1) for line in loaded.stdout.splitlines() if "=" in line)
        self.env.update(variables)
        self.env.update(CHAIN_ID="fixture", KEY_NAME="fixture", ACCOUNT_PUBKEY="fixture", KEYRING_PASSWORD="fixture",
                        POSTGRES_PASSWORD="fixture", PUBLIC_HOST="fixture.example.test", PUBLIC_URL="https://fixture.example.test",
                        SEED_NODE_RPC_URL="https://example.test/chain-rpc", SEED_NODE_P2P_URL="tcp://example.test:5000",
                        RPC_SERVER_URL_1="https://example.test/chain-rpc", RPC_SERVER_URL_2="https://example2.test/chain-rpc",
                        SEED_API_URL="https://example.test", GENESIS_SEEDS="fixture", P2P_EXTERNAL_ADDRESS="tcp://fixture.example.test:5000",
                        GENESIS_FILE="/srv/dai/shared/genesis.json", NODE_CONFIG_FILE="./node-config.json")

    def test_compose_topology_preserves_identity_and_uses_declared_images(self):
        self.compile()
        self.prepare_compose_env()
        empty_env = self.tmp / "empty.env"
        empty_env.touch()
        for layout in ("data.generations/fixture", "gdc-node9"):
            self.env.update(DATA_DIR="/srv/dai/" + layout, IDENTITY_DIR="/srv/dai/identity", SIGNER_DIR="/srv/dai/signer")
            adapted = self.run_command("bash", ROOT / "02-node/render-bootstrap-compose.sh", ROOT / "02-node/compose.yaml", empty_env)
            compose = self.tmp / "compose.json"
            compose.write_text(adapted.stdout)
            actual = json.loads(self.run_command("docker", "compose", "--profile", "*", "-f", compose,
                                                "config", "--format", "json").stdout)
            services = actual["services"]
            pins = self.document["software"]["components"]
            for role in ("node", "api", "tmkms", "proxy", "proxy-policy", "versiond-router", "versiond"):
                self.assertEqual(services[role]["image"], pins[role]["image"])
            self.assertEqual(services["proxy-policy2"]["image"], pins["proxy-policy"]["image"])
            self.assertEqual(services["versiond-router"]["environment"]["VERSIOND_ROUTER_POOL_SLOTS"], "1")
            self.assertIsNone(services["proxy"].get("command"))
            self.assertIsNone(services["proxy"].get("entrypoint"))
            self.assertNotIn("ports", services["proxy-policy"])
            self.assertEqual(services["tmkms"]["profiles"], ["signer"])
            node_mounts = {v["target"]: v["source"] for v in services["node"]["volumes"]}
            self.assertEqual(node_mounts["/root/.inference"], "/srv/dai/" + layout + "/inference")
            self.assertEqual(node_mounts["/gdc-identity"], "/srv/dai/identity")
            self.assertTrue(services["node"]["depends_on"]["tmkms"]["required"] is False)
            self.assertEqual(services["node"]["environment"]["GDC_BOOTSTRAP_SOFTWARE"], "true")


if __name__ == "__main__":
    unittest.main()
