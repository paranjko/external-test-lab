#!/usr/bin/env python3
"""Build deterministic, credential-free archives; publish only a verified tag."""
import datetime
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TARGETS = ("linux_amd64", "linux_arm64", "darwin_amd64", "darwin_arm64", "windows_amd64")
VERSION = "1.0.0-beta.1"
REPOSITORY = "paranjko/external-test-lab"


def run(*args, **kwargs):
    return subprocess.check_output(args, cwd=ROOT, text=True, **kwargs).strip()


def tag():
    value = os.environ.get("TRACE_RELEASE_TAG", "gonkactl-trace-v" + VERSION)
    if value != "gonkactl-trace-v" + VERSION:
        raise ValueError(f"this source releases only gonkactl-trace-v{VERSION}")
    return value


def archive(path, binary, data, epoch):
    if path.suffix == ".zip":
        info = zipfile.ZipInfo(binary, datetime.datetime.fromtimestamp(max(epoch, 315532800), datetime.timezone.utc).timetuple()[:6])
        info.create_system = 3
        info.external_attr = 0o100755 << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        with zipfile.ZipFile(path, "w") as stream:
            stream.writestr(info, data)
    else:
        with path.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as stream:
                info = tarfile.TarInfo(binary)
                info.size, info.mode, info.mtime = len(data), 0o755, epoch
                stream.addfile(info, io.BytesIO(data))


def output_dir():
    return Path(os.environ.get("TRACE_RELEASE_DIR", ROOT / ".cache/release")).resolve()


def build():
    tag()
    commit = run("git", "rev-parse", "HEAD")
    epoch = int(run("git", "show", "-s", "--format=%ct", "HEAD"))
    date = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    # Never silently embed a developer's optional Perfetto checkout or assets.
    if sorted(p.name for p in (ROOT / "ui-dist").iterdir()) != ["NOTICE"]:
        raise ValueError("release archives require a clean ui-dist containing only NOTICE")
    output = output_dir()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError("release output must be empty; retain prior builds in separate directories")
    checksums = []
    with tempfile.TemporaryDirectory(prefix="trace-build-") as temporary:
        for target in TARGETS:
            system, arch = target.split("_")
            binary = "gonkactl-trace" + (".exe" if system == "windows" else "")
            destination = Path(temporary) / binary
            environment = dict(os.environ, CGO_ENABLED="0", GOOS=system, GOARCH=arch, GOAMD64="v1", GOARM64="v8.0",
                               GOEXPERIMENT="", GOENV="off", GOWORK="off", GOFLAGS="", GOTOOLCHAIN="local")
            subprocess.run(["go", "build", "-mod=readonly", "-trimpath", "-buildvcs=false", "-ldflags",
                            f"-s -w -buildid= -X main.version={VERSION} -X main.commit={commit} -X main.buildDate={date}",
                            "-o", str(destination), "."], cwd=ROOT, env=environment, check=True)
            extension = ".zip" if system == "windows" else ".tar.gz"
            name = f"gonkactl-trace_{VERSION}_{target}{extension}"
            archive(output / name, binary, destination.read_bytes(), epoch)
            checksums.append(f"{hashlib.sha256((output / name).read_bytes()).hexdigest()}  {name}\n")
    (output / "SHA256SUMS").write_text("".join(sorted(checksums)))
    (output / "build.json").write_text(json.dumps({"version": VERSION, "commit": commit, "build_date": date,
                                                  "source_dirty": bool(run("git", "status", "--porcelain", "--untracked-files=normal")),
                                                  "toolchain": run("go", "version"), "targets": TARGETS}, indent=2) + "\n")
    print(output)


def verify(output):
    manifest = json.loads((output / "build.json").read_text())
    if manifest["version"] != VERSION or manifest["targets"] != list(TARGETS):
        raise ValueError("wrong release manifest")
    expected = {f"gonkactl-trace_{VERSION}_{target}" + (".zip" if target.startswith("windows") else ".tar.gz") for target in TARGETS}
    seen = set()
    for line in (output / "SHA256SUMS").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([^/]+)", line)
        if not match:
            raise ValueError("invalid checksum row")
        digest, name = match.groups()
        if name not in expected or name in seen or hashlib.sha256((output / name).read_bytes()).hexdigest() != digest:
            raise ValueError("archive checksum or name mismatch")
        seen.add(name)
    if seen != expected:
        raise ValueError("missing release archives")
    return manifest, sorted(expected)


def publish():
    release_tag = tag()
    output = output_dir()
    manifest, names = verify(output)
    head = run("git", "rev-parse", "HEAD")
    tagged = run("git", "rev-parse", f"refs/tags/{release_tag}^{{commit}}")
    if manifest.get("source_dirty", True) or run("git", "status", "--porcelain", "--untracked-files=normal"):
        raise ValueError("publication requires clean committed source")
    if manifest["commit"] != head or tagged != head:
        raise ValueError("tag, source and archive commit must match")
    subprocess.run(["gh", "release", "create", release_tag, "--repo", REPOSITORY, "--verify-tag", "--prerelease",
                    "--title", f"gonkactl-trace {VERSION}", "--notes-file", str(ROOT / "RELEASE_NOTES.md"),
                    *[str(output / name) for name in names + ["SHA256SUMS", "build.json"]]], check=True)


if __name__ == "__main__":
    try:
        {"build": build, "publish": publish}[sys.argv[1]]()
    except (ValueError, KeyError, IndexError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"release: {error}")
