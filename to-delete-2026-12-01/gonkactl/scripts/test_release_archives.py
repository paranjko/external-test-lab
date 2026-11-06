import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import release


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.output = Path(temporary.name)
        for target in release.TARGETS:
            path = self.output / release.name(target)
            binary = "gonkactl.exe" if target.startswith("windows/") else "gonkactl"
            if path.suffix == ".zip":
                with zipfile.ZipFile(path, "w") as archive:
                    for name in (binary, "README.md", "LICENSE"):
                        archive.writestr(name, b"fixture")
            else:
                with tarfile.open(path, "w:gz") as archive:
                    for name in (binary, "README.md", "LICENSE"):
                        member = tarfile.TarInfo(name)
                        member.size = 7
                        archive.addfile(member, io.BytesIO(b"fixture"))
        self.manifest()
        self.metadata = {"commit": "a" * 40, "dirty": False, "version": release.VERSION,
                         "tag": release.TAG, "targets": list(release.TARGETS)}
        self.write_metadata()

    def manifest(self):
        (self.output / "checksums.txt").write_text("".join(
            f"{release.digest(self.output / release.name(t))}  {release.name(t)}\n"
            for t in release.TARGETS))

    def write_metadata(self):
        (self.output / "build.json").write_text(json.dumps(self.metadata))

    def test_complete_manifest(self):
        release.verify(self.output)

    def test_default_generated_paths_do_not_dirty_source(self):
        checkout = self.output / "checkout"
        checkout.mkdir()
        subprocess.run(["git", "init", "--quiet", str(checkout)], check=True)
        (checkout / ".gitignore").write_bytes((release.ROOT.parent / ".gitignore").read_bytes())
        for path in ("build/gonkactl/receipt", "build/gonkactl-browser-tmp/profile",
                     "build/gonkactl-release/build.json", "gonkactl/cmd/cli.go"):
            ignored = subprocess.run(["git", "-c", f"core.excludesFile={os.devnull}",
                                      "check-ignore", "--quiet", "--no-index", path], cwd=checkout)
            self.assertEqual(ignored.returncode, 0 if path.startswith("build/") else 1, path)

    def test_corruption_and_missing_entries(self):
        archive = self.output / release.name(release.TARGETS[0])
        archive.write_bytes(archive.read_bytes() + b"corruption")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            release.verify(self.output)
        (self.output / "checksums.txt").write_text("")
        with self.assertRaisesRegex(ValueError, "exactly the six"):
            release.verify(self.output)

    def test_duplicate_entry(self):
        manifest = self.output / "checksums.txt"
        manifest.write_text(manifest.read_text() * 2)
        with self.assertRaisesRegex(ValueError, "duplicate"):
            release.verify(self.output)

    def test_publication_requires_clean_matching_source_and_tag(self):
        for tag, dirty, commit, checkout in [
            ("wrong-tag", False, "a" * 40, ""),
            (release.TAG, True, "a" * 40, ""),
            (release.TAG, False, "b" * 40, ""),
            (release.TAG, False, "a" * 40, " M source.go"),
        ]:
            with self.subTest(tag=tag, dirty=dirty, commit=commit, checkout=checkout):
                self.metadata.update(dirty=dirty, commit=commit)
                self.write_metadata()
                with patch.dict(release.os.environ, RELEASE_TAG=tag), patch.object(
                    release, "run", side_effect=lambda *args: checkout if "status" in args else "a" * 40
                ), patch.object(release.subprocess, "run") as publish:
                    with self.assertRaises(ValueError):
                        release.publish(self.output)
                    publish.assert_not_called()

    def test_publication_uploads_before_undrafting(self):
        with patch.dict(release.os.environ, RELEASE_TAG=release.TAG), patch.object(
            release, "run", side_effect=lambda *args: "" if "status" in args else "a" * 40
        ), patch.object(release.subprocess, "run") as publish:
            release.publish(self.output)
            create, edit = [call.args[0] for call in publish.call_args_list]
            self.assertEqual(create[:4], ["gh", "release", "create", release.TAG])
            self.assertIn("--draft", create)
            self.assertIn("--verify-tag", create)
            self.assertEqual(create[create.index("--notes-file") + 1], str(release.ROOT / "RELEASE_NOTES.md"))
            self.assertIn(release.VERSION, (release.ROOT / "RELEASE_NOTES.md").read_text())
            self.assertTrue(all(str(self.output / release.name(t)) in create for t in release.TARGETS))
            self.assertEqual(edit[:4], ["gh", "release", "edit", release.TAG])
            self.assertIn("--draft=false", edit)
