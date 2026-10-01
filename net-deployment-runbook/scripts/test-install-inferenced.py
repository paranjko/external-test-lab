#!/usr/bin/env python3
"""Offline selected-release installer behavior with real ZIP and SHA-256."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

INSTALLER = Path(__file__).resolve().parents[2] / "install_inferenced.sh"


class Installer(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.dest = self.root / "installed"
        self.dest.mkdir()
        self.log = self.root / "curl.log"
        self.fixtures = self.root / "fixtures"
        self.fixtures.mkdir()
        for version in ("0.2.14", "0.2.16"):
            self.release(version)
        (self.fixtures / "releases.json").write_text(json.dumps([
            {"tag_name": "devshard/v5.0.2"}, {"tag_name": "release/v0.2.16"},
            {"tag_name": "release/v0.2.14"},
        ]))
        self.tool("uname", '#!/bin/sh\ncase "$1" in -s) echo Linux ;; -m) echo x86_64 ;; *) exit 1 ;; esac\n')
        self.tool("curl", '''#!/usr/bin/env python3
import os, pathlib, sys
args = sys.argv[1:]
url = args[-1]
root = pathlib.Path(os.environ["FIXTURES"])
with open(os.environ["CURL_LOG"], "a") as log: log.write(url + "\\n")
if os.environ.get("FAIL_DOWNLOAD") == "true" and "/download/" in url: sys.exit(22)
if url.endswith("releases?per_page=100"): src = root / "releases.json"
elif "/tags/release%2Fv" in url: src = root / (url.rsplit("v", 1)[1] + ".json")
elif "/download/release/v" in url: src = root / (url.split("/release/v", 1)[1].split("/", 1)[0] + ".zip")
else: sys.exit("unexpected URL: " + url)
pathlib.Path(args[args.index("-o") + 1]).write_bytes(src.read_bytes())
''')
        self.env = {
            "PATH": str(self.bin) + ":" + os.environ["PATH"],
            "HOME": str(self.root), "INSTALL_DIR": str(self.dest),
            "FIXTURES": str(self.fixtures), "CURL_LOG": str(self.log),
        }

    def tool(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def release(self, version, binary_version=None):
        archive = self.fixtures / (version + ".zip")
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("inferenced", '#!/bin/sh\n[ "$1" = version ] || exit 2\necho "v' + (binary_version or version) + '"\n')
        asset = "inferenced-linux-amd64.zip"
        metadata = {"tag_name": "release/v" + version, "assets": [{
            "name": asset,
            "browser_download_url": "https://github.com/gonka-ai/gonka/releases/download/release/v" + version + "/" + asset,
            "digest": "sha256:" + hashlib.sha256(archive.read_bytes()).hexdigest(),
        }]}
        (self.fixtures / (version + ".json")).write_text(json.dumps(metadata))

    def installed(self, version):
        path = self.dest / "inferenced"
        path.write_text('#!/bin/sh\necho "v' + version + '"\n')
        path.chmod(0o755)
        return path.read_bytes()

    def run_installer(self, *args, **variables):
        result = subprocess.run(["sh", str(INSTALLER), *args], env={**self.env, **variables}, text=True, capture_output=True)
        self.assertNotIn("fail: not found", result.stderr)
        return result

    def assert_version(self, version):
        result = subprocess.run([str(self.dest / "inferenced"), "version"], text=True, capture_output=True, check=True)
        self.assertEqual(result.stdout.strip(), "v" + version)

    def test_argument_forms_select_different_release(self):
        for form in ("0.2.16", "v0.2.16", "release/v0.2.16"):
            with self.subTest(form=form):
                self.installed("0.2.14")
                result = self.run_installer(form)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_version("0.2.16")
                self.assertNotIn("v0.2.15", self.log.read_text())

    def test_environment_forms(self):
        for form in ("0.2.16", "v0.2.16", "release/v0.2.16"):
            with self.subTest(form=form):
                self.installed("0.2.14")
                result = self.run_installer(INFERENCED_VERSION=form)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_version("0.2.16")

    def test_argument_overrides_environment(self):
        result = self.run_installer("0.2.14", INFERENCED_VERSION="invalid")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_version("0.2.14")
        self.assertNotIn("0.2.16", self.log.read_text())

    def test_no_argument_preserves_newest_published_resolution(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_version("0.2.16")
        self.assertIn("releases?per_page=100", self.log.read_text())

    def test_invalid_and_excess_arguments_fail_before_network(self):
        for args in (("",), ("latest",), ("0.2.16/other",), ("release/0.2.16",), ("1.2.3;false",), ("0.2.16\nother",), ("v0.2.16-beta",), ("0.2.16", "extra")):
            with self.subTest(args=args):
                before = self.installed("0.2.14")
                result = self.run_installer(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((self.dest / "inferenced").read_bytes(), before)
                self.assertFalse(self.log.exists())
        result = self.run_installer(INFERENCED_VERSION="invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.log.exists())

    def test_same_version_no_op_has_no_network(self):
        before = self.installed("0.2.16")
        result = self.run_installer("release/v0.2.16")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.dest / "inferenced").read_bytes(), before)
        self.assertFalse(self.log.exists())

    def test_failure_preserves_installed_binary(self):
        for failure in ("download", "digest", "missing_digest", "tag", "asset_url", "duplicate_asset", "binary_version"):
            with self.subTest(failure=failure):
                before = self.installed("0.2.14")
                self.release("0.2.16", "0.2.14" if failure == "binary_version" else None)
                path = self.fixtures / "0.2.16.json"
                metadata = json.loads(path.read_text())
                if failure == "digest": metadata["assets"][0]["digest"] = "sha256:" + "0" * 64
                if failure == "missing_digest": metadata["assets"][0]["digest"] = None
                if failure == "tag": metadata["tag_name"] = "release/v0.2.15"
                if failure == "asset_url": metadata["assets"][0]["browser_download_url"] = "https://example.invalid/other.zip"
                if failure == "duplicate_asset": metadata["assets"].append(metadata["assets"][0].copy())
                path.write_text(json.dumps(metadata))
                result = self.run_installer("0.2.16", FAIL_DOWNLOAD="true" if failure == "download" else "false")
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((self.dest / "inferenced").read_bytes(), before)
                self.assertFalse(list(self.dest.glob(".inferenced.*")))
                self.assertNotIn("release/v0.2.15/", self.log.read_text())

    def test_devnet_pin_does_not_accept_changed_artifact(self):
        before = self.installed("0.2.14")
        self.release("0.2.15")
        result = self.run_installer("0.2.15")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("pinned DevNet artifact", result.stderr)
        self.assertEqual((self.dest / "inferenced").read_bytes(), before)

    def test_no_releases_does_not_fall_back(self):
        before = self.installed("0.2.14")
        (self.fixtures / "releases.json").write_text("[]")
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.dest / "inferenced").read_bytes(), before)
        self.assertNotIn("/download/", self.log.read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
