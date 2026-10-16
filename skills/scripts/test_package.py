import hashlib
from html.parser import HTMLParser
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest
import zipfile

from package import FILES, package

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "skills/gonka-validator-diagnosis"


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.active = None
        self.values = {}

    def handle_starttag(self, tag, attrs):
        if tag == "code":
            self.active = dict(attrs).get("id")

    def handle_endtag(self, tag):
        if tag == "code":
            self.active = None

    def handle_data(self, data):
        if self.active:
            self.values[self.active] = self.values.get(self.active, "") + data


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.archive = self.base / "skill.zip"
        package(SOURCE, self.archive)
        self.page = Page()
        self.page.feed((ROOT / "net-deployment-runbook/04-ops/site/trace/index.html").read_text())

    def test_deterministic_contents_and_manifest(self):
        second = self.base / "second.zip"
        package(SOURCE, second)
        self.assertEqual(self.archive.read_bytes(), second.read_bytes())
        with zipfile.ZipFile(self.archive) as archive:
            prefix = "gonka-validator-diagnosis/"
            self.assertEqual(set(archive.namelist()), {prefix + f for f in (*FILES, "SHA256SUMS")})
            for line in archive.read(prefix + "SHA256SUMS").decode().splitlines():
                digest, name = line.split("  ", 1)
                self.assertEqual(digest, hashlib.sha256(archive.read(prefix + name)).hexdigest())
                self.assertEqual(archive.read(prefix + name), (SOURCE / name).read_bytes())

    def test_page_digest_matches_package(self):
        self.assertEqual(self.page.values["skill-sha256"], hashlib.sha256(self.archive.read_bytes()).hexdigest())

    def run_install(self, tamper=False, installer=False):
        # Only the fixture substitutes the fixed system PATH for its network
        # mock. Production has no configurable helper-path override.
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        (bin_dir / "curl").write_text('#!/bin/sh\n[ "$1" = -fLsS ] && [ "$3" = -o ] || exit 99\ncp "$TEST_ARCHIVE" "$4"\n')
        (bin_dir / "npx").write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$TEST_RECEIPT"\npwd >> "$TEST_RECEIPT"\n')
        for entry in bin_dir.iterdir():
            entry.chmod(0o755)
        artifact = self.archive
        command_id = "skill-install-command"
        if installer:
            artifact = self.base / "original-install.sh"
            artifact.write_bytes((ROOT / "net-deployment-runbook/04-ops/site/trace/install.sh").read_bytes())
            command_id = "install-command"
        if tamper:
            with artifact.open("ab") as stream:
                stream.write(b"tampered")
        receipt = self.base / "receipt"
        environment = {
            "PATH": f"{bin_dir}:/usr/bin:/bin",
            "TMPDIR": str(self.base),
            "TEST_ARCHIVE": str(artifact),
            "TEST_RECEIPT": str(receipt),
        }
        command = self.page.values[command_id]
        self.assertEqual(command.count("PATH=/usr/bin:/bin\n"), 1)
        command = command.replace("PATH=/usr/bin:/bin\n", f"PATH='{bin_dir}:/usr/bin:/bin'\n")
        # Keep negative-case extraction observable inside this test fixture.
        command = command.replace("/tmp/gonka-", f"{self.base}/gonka-")
        result = subprocess.run(["/bin/sh", "-c", command],
                                cwd=self.base, env=environment, capture_output=True, text=True)
        return result, receipt

    def test_verified_archive_is_ready_for_manual_copy_without_registry_code(self):
        result, receipt = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(receipt.exists(), "Preparation must not execute a registry installer")
        source = next(line.removeprefix("Verified skill folder: ") for line in result.stdout.splitlines()
                      if line.startswith("Verified skill folder: "))
        self.assertEqual((Path(source) / "SKILL.md").read_bytes(), (SOURCE / "SKILL.md").read_bytes())

    def test_tampered_archive_never_extracts_or_activates(self):
        result, receipt = self.run_install(tamper=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(receipt.exists())
        self.assertFalse(list(self.base.glob("*/gonka-validator-diagnosis")))

    def test_official_installer_pin_and_verified_download(self):
        script = ROOT / "net-deployment-runbook/04-ops/site/trace/install.sh"
        self.assertEqual(self.page.values["installer-sha256"], hashlib.sha256(script.read_bytes()).hexdigest())
        result, receipt = self.run_install(installer=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Verified installer:", result.stdout)
        self.assertNotIn("Downloading gonkactl-trace", result.stdout)
        self.assertFalse(receipt.exists())

    def test_tampered_official_installer_is_not_accepted(self):
        result, receipt = self.run_install(installer=True, tamper=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Verified installer:", result.stdout)
        self.assertFalse(receipt.exists())

    def test_page_commands_ignore_untrusted_helper_path(self):
        malicious = self.base / "malicious"
        malicious.mkdir()
        marker = self.base / "helper-ran"
        for name in ("sh", "mktemp", "curl", "sha256sum", "shasum", "unzip", "cp"):
            path = malicious / name
            path.write_text(f"#!/bin/sh\nprintf unsafe > '{marker}'\nexit 99\n")
            path.chmod(0o755)
        for command_id in ("install-command", "skill-install-command"):
            command = self.page.values[command_id]
            # Network alone is mocked as a shell function using an absolute
            # system cp; PATH reset and checksum/extraction remain unchanged.
            mock = 'curl() { /bin/cp "$TEST_ARCHIVE" "$4"; }\n'
            artifact = (ROOT / "net-deployment-runbook/04-ops/site/trace/install.sh"
                        if command_id == "install-command" else self.archive)
            result = subprocess.run(["/bin/sh", "-c", mock + command],
                                    env={"PATH": str(malicious), "TMPDIR": str(self.base),
                                         "TEST_ARCHIVE": str(artifact)},
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(marker.exists())
            printed = next(line.split(": ", 1)[1] for line in result.stdout.splitlines()
                           if line.startswith(("Verified installer:", "Verified skill folder:")))
            directory = Path(printed).parent
            self.assertEqual(directory.parent, Path("/tmp"))
            self.assertTrue(directory.name.startswith(("gonka-trace.", "gonka-skill.")))
            self.addCleanup(shutil.rmtree, directory)

    def test_executable_examples_are_absolute(self):
        self.assertNotRegex(self.page.values["trace-example"], r"(?m)^gonkactl-trace\s")
        reference = (SOURCE / "references/trace-collection.md").read_text()
        self.assertNotRegex(reference, r"(?m)^gonkactl-trace\s")
        self.assertIn("/approved/absolute/path/gonkactl-trace report", reference)
        readme = (ROOT / "gonkactl-trace/README.md").read_text()
        self.assertNotRegex(readme, r"(?m)^(?:\./)?gonkactl-trace\s")
        self.assertNotIn("install.sh | sh", readme)


if __name__ == "__main__":
    unittest.main()
