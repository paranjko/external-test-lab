import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import release

INSTALLER = release.ROOT.parent / "net-deployment-runbook/04-ops/site/trace/install.sh"


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "commands"
        self.bin.mkdir()
        self.dest = self.root / "install path's bin"
        for command in ("mkdir", "mktemp", "rm", "cat", "chmod", "mv", "sed", "tar", "gzip", "unzip"):
            (self.bin / command).symlink_to(shutil.which(command))
        self.env = dict(os.environ, PATH=str(self.bin), GONKACTL_INSTALL_DIR=str(self.dest), TMPDIR=str(self.root),
                        FIXTURE=str(self.root), FIXTURE_OS="Linux", FIXTURE_ARCH="x86_64")
        self.script("uname", '#!/bin/sh\ncase "$1" in -s) printf "%s\\n" "$FIXTURE_OS";; -m) printf "%s\\n" "$FIXTURE_ARCH";; esac\n')
        self.downloader("curl")
        self.hash_tool("sha256sum")
        self.payload = b"#!/bin/sh\nprintf 'fixture binary\\n'\n"
        self.fixture()

    def script(self, name, source):
        path = self.bin / name
        path.write_text(source)
        path.chmod(0o755)

    def downloader(self, name):
        self.script(name, f"#!{sys.executable}\n" +
                    "import os, pathlib, shutil, sys\n"
                    "args=sys.argv[1:]\n"
                    "flag='-o' if '-o' in args else '-O'\n"
                    "dest=args[args.index(flag)+1]\n"
                    "url=next(a for a in args if a.startswith('https://'))\n"
                    "shutil.copyfile(pathlib.Path(os.environ['FIXTURE']) / url.rsplit('/',1)[-1], dest)\n")

    def hash_tool(self, name):
        for candidate in ("sha256sum", "shasum", "openssl"):
            (self.bin / candidate).unlink(missing_ok=True)
        if name:
            (self.bin / name).symlink_to(shutil.which(name))

    def fixture(self, target="linux_amd64"):
        binary = "gonkactl-trace.exe" if target.startswith("windows") else "gonkactl-trace"
        extension = ".zip" if target.startswith("windows") else ".tar.gz"
        self.asset = f"gonkactl-trace_{release.VERSION}_{target}{extension}"
        release.archive(self.root / self.asset, binary, self.payload, 1700000000)
        self.sums = self.root / "SHA256SUMS"
        self.sums.write_text(hashlib.sha256((self.root / self.asset).read_bytes()).hexdigest() + "  " + self.asset + "\n")

    def invoke(self, *args, success=True):
        result = subprocess.run(["/bin/sh", str(INSTALLER), *args], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def test_install_and_quoted_path_guidance(self):
        result = self.invoke()
        self.assertEqual((self.dest / "gonkactl-trace").read_bytes(), self.payload)
        export = next(line.strip() for line in result.stdout.splitlines() if line.strip().startswith("export PATH="))
        path = subprocess.check_output(["/bin/sh", "-c", export + '; printf "%s" "$PATH"'], env=self.env, text=True)
        self.assertEqual(path, str(self.dest) + ":" + str(self.bin))

    def test_hash_fallbacks_and_wget_quiet(self):
        (self.bin / "curl").unlink()
        self.downloader("wget")
        for tool in ("shasum", "openssl"):
            with self.subTest(tool=tool):
                self.hash_tool(tool)
                self.assertEqual(self.invoke("-q").stdout, "")
                self.assertEqual((self.dest / "gonkactl-trace").read_bytes(), self.payload)

    def test_corrupt_archive_preserves_existing_binary(self):
        self.dest.mkdir()
        installed = self.dest / "gonkactl-trace"
        installed.write_bytes(b"previous version")
        (self.root / self.asset).write_bytes(b"corrupted")
        self.assertIn("SHA256 mismatch", self.invoke("--quiet", success=False).stderr)
        self.assertEqual(installed.read_bytes(), b"previous version")

    def test_missing_duplicate_and_invalid_checksums(self):
        original = self.sums.read_text()
        for value in ("", original * 2, "x" * 64 + "  " + self.asset + "\n"):
            self.sums.write_text(value)
            self.invoke(success=False)
            self.assertFalse(self.dest.exists())

    def test_no_verifier_fails_before_install(self):
        self.hash_tool(None)
        self.invoke(success=False)
        self.assertFalse(self.dest.exists())

    def test_preview_is_read_only(self):
        self.assertIn("linux_amd64", self.invoke("--dry-run").stdout)
        self.assertFalse(self.dest.exists())
        self.assertFalse(list(self.root.glob("gonkactl-trace.*")))

    def test_platform_mapping(self):
        for system, arch, target in (("Linux", "aarch64", "linux_arm64"), ("Darwin", "arm64", "darwin_arm64"),
                                     ("Darwin", "x86_64", "darwin_amd64"), ("MINGW64_NT", "AMD64", None),
                                     ("MSYS_NT", "x86_64", "windows_amd64"), ("Linux", "i686", None)):
            with self.subTest(system=system, arch=arch):
                self.env.update(FIXTURE_OS=system, FIXTURE_ARCH=arch)
                if target:
                    self.fixture(target)
                    self.invoke("--quiet")
                    binary = "gonkactl-trace.exe" if target.startswith("windows") else "gonkactl-trace"
                    self.assertEqual((self.dest / binary).read_bytes(), self.payload)
                else:
                    self.invoke(success=False)

    def test_symlink_is_not_replaced(self):
        self.dest.mkdir()
        victim = self.root / "victim"
        victim.write_bytes(b"keep")
        (self.dest / "gonkactl-trace").symlink_to(victim)
        self.invoke(success=False)
        self.assertEqual(victim.read_bytes(), b"keep")


class ArchiveTests(unittest.TestCase):
    def test_verification_rejects_corrupt_missing_and_duplicate_archives(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            names = []
            sums = []
            for target in release.TARGETS:
                name = f"gonkactl-trace_{release.VERSION}_{target}" + (".zip" if target.startswith("windows") else ".tar.gz")
                (directory / name).write_bytes(b"archive")
                names.append(name)
                sums.append(hashlib.sha256(b"archive").hexdigest() + "  " + name + "\n")
            import json
            (directory / "build.json").write_text(json.dumps({"version": release.VERSION, "targets": release.TARGETS}))
            checksum = directory / "SHA256SUMS"
            checksum.write_text("".join(sums))
            self.assertEqual(release.verify(directory)[1], sorted(names))
            for invalid in (sums[:-1], sums + sums[:1], ["0" * 64 + "  " + names[0] + "\n"] + sums[1:]):
                checksum.write_text("".join(invalid))
                with self.assertRaises(ValueError):
                    release.verify(directory)

    def test_publisher_rejects_dirty_or_mismatched_source_before_gh(self):
        for dirty, tag_commit in ((True, "a"), (False, "b")):
            manifest = {"commit": "a", "source_dirty": dirty}
            with patch.object(release, "verify", return_value=(manifest, [])), \
                    patch.object(release, "run", side_effect=["a", tag_commit, ""]), \
                    patch.object(release.subprocess, "run") as publish:
                with self.assertRaises(ValueError):
                    release.publish()
                publish.assert_not_called()

    def test_archives_are_deterministic_and_contain_only_binary(self):
        with tempfile.TemporaryDirectory() as temp:
            for extension in (".tar.gz", ".zip"):
                first, second = Path(temp) / ("a" + extension), Path(temp) / ("b" + extension)
                for path in (first, second):
                    release.archive(path, "gonkactl-trace", b"binary", 1700000000)
                self.assertEqual(first.read_bytes(), second.read_bytes())
                if extension == ".zip":
                    with zipfile.ZipFile(first) as archive:
                        self.assertEqual(archive.namelist(), ["gonkactl-trace"])
                else:
                    with tarfile.open(first) as archive:
                        self.assertEqual(archive.getnames(), ["gonkactl-trace"])


if __name__ == "__main__":
    unittest.main()
