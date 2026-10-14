#!/usr/bin/env python3
"""Build and verify the six standalone CLI release archives (stdlib only)."""
import argparse
import datetime
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = "1.0.0-alpha.3"
TAG = "gonkactl-v" + VERSION
TARGETS = ("linux/amd64", "linux/arm64", "darwin/amd64", "darwin/arm64", "windows/amd64", "windows/arm64")


def run(*args, **kwargs):
    return subprocess.check_output(args, cwd=ROOT, text=True, **kwargs).strip()


def name(target):
    return f"gonkactl_{VERSION}_{target.replace('/', '_')}" + (".zip" if target.startswith("windows/") else ".tar.gz")


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def build(output):
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError("release output must be empty; preserve previous evidence in a separate directory")
    commit = run("git", "rev-parse", "HEAD")
    dirty = bool(run("git", "status", "--porcelain"))
    epoch = int(run("git", "show", "-s", "--format=%ct", "HEAD"))
    stamp = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    flags = f"-s -w -X github.com/paranjko/external-test-lab/gonkactl/internal/cli.Version={VERSION} -X github.com/paranjko/external-test-lab/gonkactl/internal/cli.Commit={commit} -X github.com/paranjko/external-test-lab/gonkactl/internal/cli.BuildDate={stamp}"
    for target in TARGETS:
        system, arch = target.split("/")
        binary = "gonkactl" + (".exe" if system == "windows" else "")
        with tempfile.TemporaryDirectory(prefix="gonkactl-build-") as temporary:
            executable = Path(temporary) / binary
            env = dict(os.environ, CGO_ENABLED="0", GOOS=system, GOARCH=arch, GOTOOLCHAIN="local", GOWORK="off", GOENV="off", GOFLAGS="", GOEXPERIMENT="", GOAMD64="v1", GOARM64="v8.0")
            subprocess.run(["go", "build", "-mod=readonly", "-trimpath", "-buildvcs=false", "-ldflags", flags, "-o", str(executable), "./cmd/gonkactl"], cwd=ROOT, env=env, check=True)
            files = [(executable, binary), (ROOT / "RELEASE.md", "README.md"), (ROOT.parent / "LICENSE", "LICENSE")]
            destination = output / name(target)
            if system == "windows":
                with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED) as archive:
                    for source, member in files:
                        info = zipfile.ZipInfo(member, (1980, 1, 1, 0, 0, 0))
                        info.external_attr = (0o100755 if member == binary else 0o100644) << 16
                        archive.writestr(info, source.read_bytes(), compress_type=zipfile.ZIP_DEFLATED)
            else:
                with destination.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=epoch) as compressed, tarfile.open(fileobj=compressed, mode="w") as archive:
                    for source, member in files:
                        info = archive.gettarinfo(str(source), member)
                        info.uid = info.gid = 0
                        info.uname = info.gname = ""
                        info.mode = 0o755 if member == binary else 0o644
                        info.mtime = epoch
                        with source.open("rb") as contents:
                            archive.addfile(info, contents)
    (output / "checksums.txt").write_text("".join(f"{digest(output / name(t))}  {name(t)}\n" for t in TARGETS))
    (output / "build.json").write_text(json.dumps({"version": VERSION, "tag": TAG, "commit": commit, "dirty": dirty, "build_time": stamp, "targets": TARGETS}, indent=2) + "\n")
    verify(output)


def verify(output):
    metadata = json.loads((output / "build.json").read_text())
    if metadata.get("version") != VERSION or metadata.get("tag") != TAG or metadata.get("targets") != list(TARGETS):
        raise ValueError("release metadata does not match version, tag and targets")
    lines = (output / "checksums.txt").read_text().splitlines()
    expected = {name(t) for t in TARGETS}
    found = {}
    for line in lines:
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9_.-]+)", line)
        if not match or match[2] in found:
            raise ValueError("malformed or duplicate checksum entry")
        found[match[2]] = match[1]
    if set(found) != expected:
        raise ValueError("checksum manifest must name exactly the six release archives")
    for filename, checksum in found.items():
        if digest(output / filename) != checksum:
            raise ValueError(f"checksum mismatch: {filename}")
        if filename.endswith(".zip"):
            with zipfile.ZipFile(output / filename) as archive:
                members = archive.namelist()
            binary = "gonkactl.exe"
        else:
            with tarfile.open(output / filename) as archive:
                members = archive.getnames()
                if any(not item.isfile() for item in archive.getmembers()):
                    raise ValueError("archive contains a non-regular entry")
            binary = "gonkactl"
        if sorted(members) != sorted([binary, "README.md", "LICENSE"]):
            raise ValueError(f"unexpected archive members: {filename}")
    print("Verified six release archives and SHA-256 checksums")


def publish(output):
    verify(output)
    if os.environ.get("RELEASE_TAG") != TAG:
        raise ValueError(f"RELEASE_TAG must be {TAG}")
    head = run("git", "rev-parse", "HEAD")
    if run("git", "rev-parse", f"refs/tags/{TAG}^{{commit}}") != head:
        raise ValueError("tag does not identify the checked-out source")
    metadata = json.loads((output / "build.json").read_text())
    if metadata.get("dirty") is not False or run("git", "status", "--porcelain"):
        raise ValueError("publication requires clean committed source")
    if metadata["commit"] != head:
        raise ValueError("archives were built from a different source commit")
    repo = "paranjko/external-test-lab"
    # Never replace an existing release or assets, including another tool's.
    subprocess.run(["gh", "release", "create", TAG, "--repo", repo, "--verify-tag", "--draft", "--prerelease", "--title", f"gonkactl {VERSION}", "--notes-file", str(ROOT / "RELEASE_NOTES.md"), *[str(output / name(t)) for t in TARGETS], str(output / "checksums.txt"), str(output / "build.json")], check=True)
    subprocess.run(["gh", "release", "edit", TAG, "--repo", repo, "--draft=false", "--prerelease"], check=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("build", "verify", "publish"))
    parser.add_argument("--output", type=Path, default=ROOT.parent / "build/gonkactl-release")
    args = parser.parse_args()
    try:
        {"build": build, "verify": verify, "publish": publish}[args.action](args.output.resolve())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"release: {error}\n")
