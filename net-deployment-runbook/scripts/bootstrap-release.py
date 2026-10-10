#!/usr/bin/env python3
"""Prepare, verify and switch static bootstrap releases; never query seed health."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
import uuid

NAME = r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}"
PUBLIC_PATH = re.compile(rf"(?:{NAME}\.schema\.json|{NAME}/bootstrap\.(?:json|env))")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def strict_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, f"duplicate JSON key: {key}")
            result[key] = value
        return result
    def constant(_):
        raise ValueError("non-finite JSON number")
    return json.loads(data, object_pairs_hook=pairs, parse_constant=constant)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def prepare(repository, destination, revision):
    import jsonschema
    require(re.fullmatch(r"[0-9a-f]{40}", revision), "revision must be a full Git commit")
    require(not destination.exists(), "release destination already exists; choose a fresh directory")
    module_path = repository / "net-deployment-runbook/scripts/network-bootstrap.py"
    spec = importlib.util.spec_from_file_location("bootstrap", module_path)
    bootstrap = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bootstrap)
    files = {}
    for path in sorted((repository / "schema").glob("*.schema.json")):
        require(not path.is_symlink(), f"symlink input: {path.name}")
        schema = strict_json(path.read_bytes())
        jsonschema.Draft202012Validator.check_schema(schema)
        require(schema.get("$id") == "https://gonka-dev.net/" + path.name,
                f"schema identity differs from public URL: {path.name}")
        files[path.name] = path.read_bytes()
    require("v1.bootstrap.schema.json" in files, "bootstrap schema missing")
    schemas = len(files)
    descriptors = sorted((repository / "bootstrap").glob("*.json"))
    require(descriptors, "no bootstrap descriptors")
    for path in descriptors:
        require(not path.is_symlink(), f"symlink input: {path.name}")
        doc = bootstrap.validate(strict_json(path.read_bytes()))
        require(path.stem == doc["chain_id"], f"chain ID differs from filename: {path.name}")
        env_path = path.with_suffix(".env")
        projection = bootstrap.env(doc)
        require(env_path.is_file() and not env_path.is_symlink(), f"ENV projection missing: {env_path.name}")
        require(env_path.read_bytes() == projection, f"stale ENV projection: {env_path.name}")
        files[f"{path.stem}/bootstrap.json"] = path.read_bytes()
        files[f"{path.stem}/bootstrap.env"] = projection
    require({p.stem for p in (repository / "bootstrap").glob("*.env")} == {p.stem for p in descriptors},
            "orphan ENV projection")
    manifest = {"revision": revision, "files": {name: digest(data) for name, data in sorted(files.items())}}
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".bootstrap-build-", dir=destination.parent) as temp:
        staged = Path(temp) / "release"
        for name, data in files.items():
            require(PUBLIC_PATH.fullmatch(name), f"unsafe publication path: {name}")
            target = staged / "public" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        (staged / "manifest.json").write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
        check(staged)
        staged.rename(destination)
    print(f"PASS prepared {schemas} schemas and {len(descriptors)} JSON/ENV pairs")


def check(release):
    require(release.is_dir() and not release.is_symlink(), "release must be a real directory")
    require(not (release / "manifest.json").is_symlink(), "manifest symlink refused")
    manifest_bytes = (release / "manifest.json").read_bytes()
    manifest = strict_json(manifest_bytes)
    require(isinstance(manifest, dict) and set(manifest) == {"revision", "files"}, "invalid manifest fields")
    require(re.fullmatch(r"[0-9a-f]{40}", manifest["revision"]), "invalid manifest revision")
    require(isinstance(manifest["files"], dict) and manifest["files"], "empty release")
    actual = set()
    for path in release.rglob("*"):
        require(not path.is_symlink(), "release symlinks refused")
        if path.is_file():
            actual.add(path.relative_to(release).as_posix())
        else:
            require(path.is_dir(), "special release file refused")
    require(actual == {"manifest.json"} | {"public/" + name for name in manifest["files"]},
            "release inventory differs from manifest")
    for name, expected in manifest["files"].items():
        require(PUBLIC_PATH.fullmatch(name), "unsafe manifest path")
        require(re.fullmatch(r"[0-9a-f]{64}", expected), "invalid file digest")
        require(digest((release / "public" / name).read_bytes()) == expected, f"digest mismatch: {name}")
        if name.endswith("/bootstrap.json"):
            require(name[:-4] + "env" in manifest["files"], "incomplete bootstrap pair")
        if name.endswith("/bootstrap.env"):
            require(name[:-3] + "json" in manifest["files"], "orphan bootstrap ENV")
    require("v1.bootstrap.schema.json" in manifest["files"], "bootstrap schema missing")
    return manifest, digest(manifest_bytes)


def switch(root, target):
    temporary = root / (".current-" + uuid.uuid4().hex)
    temporary.symlink_to(target)
    try:
        os.replace(temporary, root / "current")
    finally:
        temporary.unlink(missing_ok=True)


def activate(root, upload, expected):
    require(root.is_dir() and not root.is_symlink(), "publication root must be a real directory")
    require(upload.parent == root and upload.name.startswith(".upload-"), "upload outside publication root")
    manifest, generation = check(upload)
    require(generation == expected, "uploaded manifest differs from prepared release")
    current = root / "current"
    releases = root / "releases"
    require(not releases.is_symlink(), "releases directory symlink refused")
    releases.mkdir(exist_ok=True)
    target = releases / generation
    receipt = root / ("receipt-" + generation + ".json")
    require(not receipt.is_symlink() and not (root / ".publish.lock").is_symlink(), "publication metadata symlink refused")
    with (root / ".publish.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if current.is_symlink() and os.readlink(current) == f"releases/{generation}/public":
            require(check(target)[1] == generation, "active release is damaged")
            print("PASS release already active")
            return
        if target.exists():
            require(check(target)[1] == generation, "retained generation is damaged")
        else:
            upload.rename(target)
        previous = None
        if current.is_symlink():
            previous = os.readlink(current)
            require(re.fullmatch(r"releases/(?:[0-9a-f]{64}/public|legacy-[0-9a-f]{32})", previous),
                    "unmanaged current symlink; operator migration required")
            require(current.is_dir(), "broken current symlink")
        elif current.exists():
            require(current.is_dir(), "current is not a directory")
            previous = "releases/legacy-" + uuid.uuid4().hex
            current.rename(root / previous)
        try:
            receipt.write_text(json.dumps({"generation": generation, "previous": previous}) + "\n")
            switch(root, f"releases/{generation}/public")
        except Exception:
            if previous and not current.exists():
                switch(root, previous)
            raise
    print(f"PASS activated revision={manifest['revision']} generation={generation}")


def rollback(root, generation):
    require(re.fullmatch(r"[0-9a-f]{64}", generation), "invalid generation")
    with (root / ".publish.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        current = root / "current"
        require(current.is_symlink() and os.readlink(current) == f"releases/{generation}/public",
                "current changed; refusing rollback of another release")
        receipt = strict_json((root / ("receipt-" + generation + ".json")).read_bytes())
        previous = receipt["previous"]
        require(previous and re.fullmatch(r"releases/(?:[0-9a-f]{64}/public|legacy-[0-9a-f]{32})", previous),
                "no previous release; retain failed generation for operator inspection")
        require((root / previous).is_dir(), "previous release missing")
        switch(root, previous)
    print("PASS restored previous release; failed generation retained")


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError("public artifact redirect refused")


def verify(release, origin, attempts=3):
    manifest, _ = check(release)
    parsed = urlsplit(origin)
    require(parsed.scheme == "https" or (parsed.scheme == "http" and parsed.hostname in ("127.0.0.1", "localhost")),
            "public origin must use HTTPS (HTTP is limited to loopback fixtures)")
    require(parsed.hostname and parsed.path in ("", "/") and not parsed.query and not parsed.fragment
            and not parsed.username and not parsed.password, "invalid public origin")
    opener = build_opener(NoRedirect())
    for name in manifest["files"]:
        expected = (release / "public" / name).read_bytes()
        for attempt in range(attempts):
            try:
                request = Request(origin.rstrip("/") + "/" + name, headers={"Cache-Control": "no-cache"})
                with opener.open(request, timeout=10) as response:
                    require(response.status == 200 and response.read(len(expected) + 1) == expected,
                            f"published content differs: {name}")
                break
            except Exception:
                if attempt + 1 == attempts:
                    raise ValueError(f"public readback failed: {name}") from None
                time.sleep(2)
    print(f"PASS public bytes match all {len(manifest['files'])} artifacts")


def routes(source, destination):
    data = source.read_text()
    require("root * /edge/bootstrap/current" in data, "edge bootstrap route missing")
    require("handle /v1.bootstrap.schema.json {" in data or "handle /*.schema.json {" in data,
            "unrecognized schema route; manual review required")
    destination.write_text(data.replace("handle /v1.bootstrap.schema.json {", "handle /*.schema.json {"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("repository", type=Path); p.add_argument("destination", type=Path); p.add_argument("revision")
    p = sub.add_parser("check"); p.add_argument("release", type=Path)
    p = sub.add_parser("activate")
    p.add_argument("root", type=Path); p.add_argument("upload", type=Path); p.add_argument("generation")
    p = sub.add_parser("rollback"); p.add_argument("root", type=Path); p.add_argument("generation")
    p = sub.add_parser("verify"); p.add_argument("release", type=Path); p.add_argument("origin")
    p = sub.add_parser("routes"); p.add_argument("source", type=Path); p.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "prepare": prepare(args.repository, args.destination, args.revision)
        elif args.command == "check": print(check(args.release)[1])
        elif args.command == "activate": activate(args.root, args.upload, args.generation)
        elif args.command == "rollback": rollback(args.root, args.generation)
        elif args.command == "verify": verify(args.release, args.origin)
        elif args.command == "routes": routes(args.source, args.destination)
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(f"bootstrap release: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
