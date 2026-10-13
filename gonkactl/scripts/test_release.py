import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT.parent / "net-deployment-runbook/04-ops/site/ctl/install.sh"
VERSION = "1.0.0-alpha.1"


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="test-installer-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.mock = self.root / "commands"
        self.mock.mkdir()
        self.assets = self.root / "assets"
        self.assets.mkdir()
        self.home = self.root / "home with ' quote"
        self.home.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), PATH=f"{self.mock}:/usr/bin:/bin", NO_COLOR="", TEST_ASSETS=str(self.assets))
        self.script("curl", '''#!/bin/sh
set -eu
out=
while [ "$#" -gt 0 ]; do
  case "$1" in --output) shift; out=$1;; https:*) url=$1;; esac
  shift
done
case "$url" in https://github.com/paranjko/external-test-lab/releases/download/gonkactl-v*/gonkactl_*|https://github.com/paranjko/external-test-lab/releases/download/gonkactl-v*/checksums.txt) ;; *) exit 71;; esac
cp "$TEST_ASSETS/${url##*/}" "$out"
''')

    def script(self, name, contents):
        path = self.mock / name
        path.write_text(contents)
        path.chmod(0o755)

    def archive(self, system="linux", arch="amd64", version=VERSION):
        suffix = ".zip" if system == "windows" else ".tar.gz"
        path = self.assets / f"gonkactl_{version}_{system}_{arch}{suffix}"
        binary = "gonkactl.exe" if system == "windows" else "gonkactl"
        data = f"#!/bin/sh\nprintf '%s\\n' '{version}'\n".encode()
        if suffix == ".zip":
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr(binary, data)
        else:
            with tarfile.open(path, "w:gz") as archive:
                item = tarfile.TarInfo(binary)
                item.size = len(data)
                item.mode = 0o755
                archive.addfile(item, io.BytesIO(data))
        self.checksum = hashlib.sha256(path.read_bytes()).hexdigest()
        (self.assets / "checksums.txt").write_text(f"{self.checksum}  {path.name}\n")
        return path, binary

    def install(self):
        return subprocess.run(["sh", str(INSTALLER)], env=self.env, text=True, capture_output=True, timeout=30)

    def test_platform_mapping_and_no_color(self):
        for uname, machine, system, arch in [("Linux", "x86_64", "linux", "amd64"), ("Linux", "aarch64", "linux", "arm64"), ("Darwin", "x86_64", "darwin", "amd64"), ("Darwin", "arm64", "darwin", "arm64"), ("MINGW64_NT-10.0", "x86_64", "windows", "amd64"), ("MSYS_NT-10.0", "amd64", "windows", "amd64"), ("MINGW64_NT-10.0", "arm64", "windows", "arm64")]:
            with self.subTest(system=system, arch=arch, uname=uname):
                self.script("uname", f"#!/bin/sh\ncase $1 in -s) echo {uname};; -m) echo {machine};; esac\n")
                _, binary = self.archive(system, arch)
                result = self.install()
                self.assertEqual(result.returncode, 0, result.stderr)
                installed = self.home / ".local/bin" / binary
                self.assertEqual(subprocess.check_output([str(installed), "--version"], text=True).strip(), VERSION)
                self.assertNotIn("\x1b", result.stdout)
                export = next(line.strip() for line in result.stdout.splitlines() if line.strip().startswith("export PATH="))
                checked = subprocess.check_output(["sh", "-c", export + '; printf "%s" "$PATH"'], env=self.env, text=True)
                self.assertTrue(checked.startswith(str(installed.parent) + ":"))

    def test_mismatch_preserves_existing_binary(self):
        path, binary = self.archive()
        installed = self.home / ".local/bin" / binary
        installed.parent.mkdir(parents=True)
        installed.write_text("preserve-me")
        path.write_bytes(path.read_bytes() + b"corrupted")
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA-256 mismatch", result.stderr)
        self.assertEqual(installed.read_text(), "preserve-me")

    def test_bad_manifest_is_rejected(self):
        path, _ = self.archive()
        for manifest in ["", f"bad  {path.name}\n", f"{self.checksum}  {path.name}\n" * 2]:
            (self.assets / "checksums.txt").write_text(manifest)
            result = self.install()
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((self.home / ".local/bin/gonkactl").exists())

    def test_download_failure(self):
        self.script("curl", "#!/bin/sh\nexit 22\n")
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.home / ".local/bin").exists())

    def test_piped_install_and_temporary_cleanup(self):
        self.archive()
        temporary = self.root / "temporary"
        temporary.mkdir()
        self.env["TMPDIR"] = str(temporary)
        result = subprocess.run(["sh"], input=INSTALLER.read_text(), env=self.env,
                                text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(list(temporary.iterdir()), [])
        self.assertEqual(sorted(p.name for p in self.home.iterdir()), [".local"])
        self.assertNotIn("Downloading", result.stdout)
        self.script("curl", "#!/bin/sh\nexit 22\n")
        self.assertNotEqual(self.install().returncode, 0)
        self.assertEqual(list(temporary.iterdir()), [])

    def test_wrong_executable_version_preserves_destination(self):
        path, binary = self.archive(version="wrong")
        renamed = self.assets / f"gonkactl_{VERSION}_linux_amd64.tar.gz"
        path.rename(renamed)
        (self.assets / "checksums.txt").write_text(f"{self.checksum}  {renamed.name}\n")
        installed = self.home / ".local/bin" / binary
        installed.parent.mkdir(parents=True)
        installed.write_text("preserve-me")
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected version", result.stderr)
        self.assertEqual(installed.read_text(), "preserve-me")

    def test_unsupported_target_and_invalid_version(self):
        self.script("uname", "#!/bin/sh\necho unsupported\n")
        self.assertNotEqual(self.install().returncode, 0)
        self.env["GONKACTL_VERSION"] = "../../other"
        self.assertIn("Invalid", self.install().stderr)

    def test_version_override_and_custom_destination(self):
        self.archive(version="1.0.0-beta.2")
        self.env["GONKACTL_VERSION"] = "v1.0.0-beta.2"
        self.env["GONKACTL_INSTALL_DIR"] = str(self.home / "custom bin")
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.home / "custom bin/gonkactl").is_file())

    def test_wget_and_shasum_fallback(self):
        self.archive()
        isolated = self.root / "fallback"
        isolated.mkdir()
        for name in ["uname", "mktemp", "mkdir", "chmod", "mv", "rm", "awk", "sed", "cat", "tar", "gzip", "cp", "shasum", "perl"]:
            executable = shutil.which(name)
            if executable:
                (isolated / name).symlink_to(executable)
        self.script("wget", '''#!/bin/sh
set -eu
for arg do case "$arg" in --output-document=*) out=${arg#*=};; https:*) url=$arg;; esac; done
cp "$TEST_ASSETS/${url##*/}" "$out"
''')
        shutil.copy(self.mock / "wget", isolated / "wget")
        self.env["PATH"] = str(isolated)
        result = subprocess.run(["/bin/sh", str(INSTALLER)], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
