#!/usr/bin/env python3
"""Build and publish a frozen DevShard lab candidate."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[1]
DEFINITION = ROOT / "releases/devshard-v6.json"
REPOSITORY = "paranjko/external-test-lab"
ASSETS = {"devshardd.zip", "source.json", "approved-version.json", "build-info.txt", "SHA256SUMS"}


def run(*args: str, **kwargs) -> str:
    return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE, **kwargs).stdout.strip()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def dependencies(command: str) -> None:
    commands = {"go", "bash", "curl", "unzip", "zipinfo", "nm", "objdump", "od", "sha256sum"}
    if command == "fetch":
        commands = {"git"}
    if command == "build":
        commands.update(("git", "tar", "docker", "python3"))
    if command == "publish":
        commands.update(("git", "gh"))
    missing = sorted(name for name in commands if shutil.which(name) is None)
    require(not missing, "missing DevShard release dependencies: " + ", ".join(missing))


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def definition(path: Path = DEFINITION) -> dict:
    value = json.loads(path.read_text())
    require(set(value) == {
        "schema_version", "classification", "source_repository", "source_commit",
        "source_tree", "protocol", "release_tag", "binary_version", "platform", "base_images",
    }, "unexpected release definition fields")
    require(value["schema_version"] == 1 and value["classification"] == "lab-candidate",
            "only schema 1 lab candidates are supported")
    require(value["source_repository"] == "gonka-ai/gonka", "unexpected source repository")
    for field in ("source_commit", "source_tree"):
        require(bool(re.fullmatch(r"[0-9a-f]{40}", value[field])), f"invalid {field}")
    require(value["protocol"] == "v6" and value["platform"] == "linux/amd64",
            "this release path supports only v6 linux/amd64")
    tag = f"lab-devshard-v6-{value['source_commit'][:12]}"
    require(value["release_tag"] == tag and value["binary_version"] == tag,
            "release tag and binary stamp must bind the frozen commit")
    require(set(value["base_images"]) == {"golang:1.25.9-alpine3.23", "alpine:3.23"},
            "unexpected Docker base set")
    for digest in value["base_images"].values():
        require(bool(re.fullmatch(r"sha256:[0-9a-f]{64}", digest)), "unpinned Docker base")
    return value


def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def approved_version(value: dict, checksum: str) -> dict:
    return {
        "name": value["protocol"],
        "binary": f"https://github.com/{REPOSITORY}/releases/download/{value['release_tag']}/devshardd.zip",
        "sha256": checksum,
    }


def check_metadata(metadata: str, value: dict) -> None:
    settings = {}
    for line in metadata.splitlines():
        fields = line.strip().split("\t", 1)
        if len(fields) == 2 and fields[0] == "build" and "=" in fields[1]:
            key, setting = fields[1].split("=", 1)
            # Go quotes settings that contain spaces, including the linker flags.
            settings[key] = json.loads(setting) if setting.startswith('"') else setting
    require(settings.get("GOOS") == "linux" and settings.get("GOARCH") == "amd64",
            "binary is not linux/amd64")
    require(settings.get("-tags", "").strip() == "muslc", "release must not contain test build tags")
    flags = shlex.split(settings.get("-ldflags", ""))
    bindings = [flags[i + 1] for i, flag in enumerate(flags[:-1]) if flag == "-X"]
    for key, expected in {
        "main.Version": value["protocol"],
        "main.BinaryVersion": value["binary_version"],
        "devshard/types.buildStateRootProtocolVersion": value["protocol"],
    }.items():
        require([item for item in bindings if item.startswith(key + "=")] == [f"{key}={expected}"],
                f"incorrect linked identity: {key}")


def package(binary: Path, output: Path, value: dict) -> None:
    require(binary.is_file() and not binary.is_symlink(), "missing regular devshardd binary")
    metadata = run("go", "version", "-m", str(binary))
    check_metadata(metadata, value)
    # Drop the builder's local absolute path from the public build information.
    metadata = "devshardd:" + metadata.split(":", 1)[1] + "\n"
    info = zipfile.ZipInfo("devshardd", date_time=(1980, 1, 1, 0, 0, 0))
    info.create_system = 3
    info.external_attr = (stat.S_IFREG | 0o755) << 16
    info.compress_type = zipfile.ZIP_DEFLATED
    with zipfile.ZipFile(output / "devshardd.zip", "x") as archive:
        archive.writestr(info, binary.read_bytes())
    write_json(output / "source.json", value)
    write_json(output / "approved-version.json", approved_version(value, sha256(output / "devshardd.zip")))
    (output / "build-info.txt").write_text(metadata)
    (output / "SHA256SUMS").write_text("".join(
        f"{sha256(output / name)}  {name}\n" for name in sorted(ASSETS - {"SHA256SUMS"})
    ))


def verify(output: Path, value: dict) -> None:
    require(output.is_dir() and {p.name for p in output.iterdir()} == ASSETS, "unexpected release asset set")
    require(all(p.is_file() and not p.is_symlink() for p in output.iterdir()), "non-regular release asset")
    require(json.loads((output / "source.json").read_text()) == value, "source definition mismatch")
    checksums = "".join(f"{sha256(output / name)}  {name}\n" for name in sorted(ASSETS - {"SHA256SUMS"}))
    require((output / "SHA256SUMS").read_text() == checksums, "release checksum mismatch")
    checksum = sha256(output / "devshardd.zip")
    require(json.loads((output / "approved-version.json").read_text()) == approved_version(value, checksum),
            "approved version does not bind this archive")
    with tempfile.TemporaryDirectory(prefix="devshard-release-verify-") as directory:
        temporary = Path(directory)
        with zipfile.ZipFile(output / "devshardd.zip") as archive:
            require(archive.namelist() == ["devshardd"], "archive must contain only root devshardd")
            member = archive.infolist()[0]
            require(member.external_attr >> 16 == stat.S_IFREG | 0o755, "archive executable mode mismatch")
            binary = temporary / "devshardd"
            binary.write_bytes(archive.read(member))
        metadata = run("go", "version", "-m", str(binary))
        check_metadata(metadata, value)
        require((output / "build-info.txt").read_text() == "devshardd:" + metadata.split(":", 1)[1] + "\n",
                "build metadata mismatch")
        # This verifier reads ELF symbols without executing the candidate binary.
        print(run("bash", str(ROOT / "scripts/verify-devshard-archive.sh"), value["protocol"],
                  (output / "devshardd.zip").resolve().as_uri(), checksum, str(temporary / "cache")))


def verify_source(source: Path, value: dict) -> None:
    require(run("git", "-C", str(source), "rev-parse", "HEAD") == value["source_commit"], "source HEAD mismatch")
    require(run("git", "-C", str(source), "rev-parse", "HEAD^{tree}") == value["source_tree"], "source tree mismatch")


def fetch(source: Path, value: dict) -> None:
    require(not source.exists(), "source destination already exists; never overwrite a checkout")
    source.mkdir(parents=True)
    run("git", "-C", str(source), "init", "--quiet")
    # Public source needs no Actions checkout token and is never executed on the runner.
    run("git", "-C", str(source), "-c", "credential.helper=", "fetch", "--no-tags", "--depth=1",
        "https://github.com/gonka-ai/gonka.git", value["source_commit"])
    run("git", "-C", str(source), "checkout", "--quiet", "--detach", "FETCH_HEAD")
    verify_source(source, value)


def build(source: Path, output: Path, value: dict) -> None:
    verify_source(source, value)
    output.mkdir(parents=True, exist_ok=True)
    require(not any(output.iterdir()), "release output must be empty; never overwrite a prior build")
    with tempfile.TemporaryDirectory(prefix="devshard-release-build-") as directory:
        temporary = Path(directory)
        context = temporary / "source"
        context.mkdir()
        # Only committed bytes enter Docker, never local secrets or ignored fixtures.
        archive = temporary / "source.tar"
        run("git", "-C", str(source), "archive", "--format=tar", f"--output={archive}", value["source_commit"])
        run("tar", "-xf", str(archive), "-C", str(context))
        dockerfile = temporary / "Dockerfile"
        run("python3", str(ROOT / "scripts/pin-candidate-dockerfile.py"),
            "--source", str(context / "devshard/Dockerfile"), "--output", str(dockerfile),
            "--base-images-json", json.dumps(value["base_images"]))
        run("python3", str(ROOT / "scripts/patch-candidate-go-mod-download.py"),
            "--source", str(dockerfile), "--output", str(dockerfile))
        with dockerfile.open("a") as stream:
            stream.write("\nFROM scratch AS release-export\n"
                         "COPY --from=builder /app/devshard/build/devshardd /devshardd\n"
                         "COPY --from=builder /usr/lib/libgcc_s.so.1 /libgcc_s.so.1\n")
        exported = temporary / "export"
        subprocess.run([
            "docker", "buildx", "build", "--progress=plain", "--platform=linux/amd64",
            "--file", str(dockerfile), "--target=release-export", "--output", f"type=local,dest={exported}",
            "--build-arg", "GOOS=linux", "--build-arg", "GOARCH=amd64",
            "--build-arg", "BLST_PORTABLE=0", "--build-arg", "DEVSHARD_BUILD_TAGS=",
            "--build-arg", f"DEVSHARD_VERSION={value['protocol']}",
            "--build-arg", f"DEVSHARD_BINARY_VERSION={value['binary_version']}", str(context),
        ], check=True)
        binary = exported / "devshardd"
        runtime = "alpine:3.23@" + value["base_images"]["alpine:3.23"]
        for flag, expected in (("--print-protocol-version", value["protocol"]),
                               ("--print-binary-version", value["binary_version"])):
            observed = run("docker", "run", "--rm", "--network=none", "--read-only", "--cap-drop=ALL",
                           "--security-opt=no-new-privileges", "--user=65534:65534", "--memory=512m", "--cpus=1",
                           "--mount", f"type=bind,src={binary},dst=/devshardd,readonly",
                           "--mount", f"type=bind,src={exported / 'libgcc_s.so.1'},dst=/usr/lib/libgcc_s.so.1,readonly",
                           "--entrypoint=/devshardd", runtime, flag, timeout=60)
            require(observed == expected, f"runtime identity mismatch for {flag}")
        package(binary, output, value)
    verify(output, value)


def publish(output: Path, value: dict) -> None:
    require(os.environ.get("GITHUB_REPOSITORY") == REPOSITORY and
            os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch" and
            os.environ.get("GITHUB_REF") == "refs/heads/main",
            "publication requires a manual default-branch workflow in the release repository")
    revision = os.environ.get("GITHUB_SHA", "")
    require(bool(re.fullmatch(r"[0-9a-f]{40}", revision)), "missing automation revision")
    require(run("git", "-C", str(ROOT), "rev-parse", "HEAD") == revision, "automation checkout mismatch")
    verify(output, value)
    tag = value["release_tag"]
    releases = json.loads(run("gh", "release", "list", "--repo", REPOSITORY, "--limit", "1000", "--json", "tagName"))
    require(all(item["tagName"] != tag for item in releases), "release already exists; never replace published assets")
    refs = json.loads(run("gh", "api", f"repos/{REPOSITORY}/git/matching-refs/tags/{tag}"))
    require(not any(item["ref"] == f"refs/tags/{tag}" for item in refs), "release tag already exists")
    with tempfile.TemporaryDirectory(prefix="devshard-release-publish-") as directory:
        temporary = Path(directory)
        notes = temporary / "notes.md"
        notes.write_text(
            "Lab candidate, not an official Gonka release or v6 qualification result.\n\n"
            f"Source: https://github.com/{value['source_repository']}/commit/{value['source_commit']}\n\n"
            f"Protocol `{value['protocol']}`, Linux amd64, no test tags. Requires musl, "
            "`libgcc_s.so.1` and CPUs compatible with upstream `BLST_PORTABLE=0`.\n\n"
            "The ZIP contains only `devshardd`; SHA256 covers the ZIP. "
            "After compatibility review and governance approval, append this entry "
            "without replacing existing approved versions:\n\n```json\n"
            + (output / "approved-version.json").read_text() + "```\n\n"
            "No gateway, versiond, deployment or on-chain changes are included.\n"
        )
        run("gh", "release", "create", tag, "--repo", REPOSITORY, "--target", revision,
            "--title", tag, "--draft", "--prerelease", "--latest=false", "--notes-file", str(notes),
            *(str(output / name) for name in sorted(ASSETS)))
        downloaded = temporary / "download"
        run("gh", "release", "download", tag, "--repo", REPOSITORY, "--dir", str(downloaded))
        verify(downloaded, value)
        require(all(sha256(downloaded / name) == sha256(output / name) for name in ASSETS),
                "uploaded release differs from built assets; draft retained")
        run("gh", "release", "edit", tag, "--repo", REPOSITORY, "--draft=false", "--prerelease", "--latest=false")
        published = json.loads(run("gh", "release", "view", tag, "--repo", REPOSITORY,
                                   "--json", "isDraft,isPrerelease,url"))
        require(not published["isDraft"] and published["isPrerelease"], "release publication readback failed")
        print(published["url"])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "fetch", "build", "verify", "publish"))
    args = parser.parse_args()
    value = definition()
    if args.command != "prepare":
        dependencies(args.command)
    output = Path(os.environ.get("DEVSHARD_RELEASE_DIR", str(ROOT / ".data/devshard-release"))).resolve()
    if args.command == "prepare":
        print(json.dumps(value, indent=2))
    elif args.command in ("fetch", "build"):
        require(bool(os.environ.get("DEVSHARD_SOURCE")), "set DEVSHARD_SOURCE to the frozen Gonka checkout")
        source = Path(os.environ["DEVSHARD_SOURCE"]).resolve()
        if args.command == "fetch":
            fetch(source, value)
        else:
            build(source, output, value)
    elif args.command == "verify":
        verify(output, value)
    else:
        publish(output, value)


if __name__ == "__main__":
    main()
