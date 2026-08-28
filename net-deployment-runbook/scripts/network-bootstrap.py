#!/usr/bin/env python3
"""Deterministic Gonka Network Bootstrap v1 renderer and offline verifier."""

from __future__ import annotations

import argparse
import base64
import hashlib
import ipaddress
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

import jsonschema

SCHEMA_URI = "https://gonka-dev.net/v1.bootstrap.schema.json"
MAX_DOCUMENT_BYTES = 2 * 1024 * 1024
MAX_GENESIS_BYTES = 1024 * 1024
NODE_ID_RE = re.compile(r"^[0-9a-f]{40}$")
CHAIN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
DNS_RE = re.compile(r"^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")
PRIVATE_CREDENTIAL_RE = re.compile(r"(?i)(-----BEGIN|\b(?:mnemonic|private[_ -]?key|wallet|tmkms|ssh-|ghp_|github_pat_|xox[bpras]-|sk-[a-z0-9]))")


class BootstrapError(ValueError):
    """A safe, file- and field-specific bootstrap validation error."""

    def __init__(self, stage: str, field: str, message: str):
        super().__init__(f"bootstrap validation failed stage={stage} field={field}: {message}")


def reject_duplicates(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise BootstrapError("parse", key, "duplicate key")
        result[key] = value
    return result


def load_json(path: Path) -> object:
    try:
        data = path.read_bytes()
    except OSError as error:
        raise BootstrapError("read", str(path), str(error)) from error
    if len(data) > MAX_DOCUMENT_BYTES:
        raise BootstrapError("size", str(path), f"document exceeds {MAX_DOCUMENT_BYTES} bytes")
    try:
        text = data.decode("utf-8", "strict")
    except UnicodeDecodeError as error:
        raise BootstrapError("parse", str(path), "invalid UTF-8") from error
    try:
        return json.loads(text, object_pairs_hook=reject_duplicates)
    except BootstrapError:
        raise
    except json.JSONDecodeError as error:
        raise BootstrapError("parse", str(path), f"invalid JSON at line {error.lineno}") from error


def schema_path() -> Path:
    return Path(__file__).resolve().parent.parent / "bootstrap" / "v1.bootstrap.schema.json"


def validate_schema(document: object, source: Path) -> None:
    schema = load_json(schema_path())
    try:
        jsonschema.Draft202012Validator.check_schema(schema)
        errors = sorted(jsonschema.Draft202012Validator(schema).iter_errors(document), key=lambda error: list(error.path))
    except jsonschema.SchemaError as error:
        raise BootstrapError("schema", str(schema_path()), "repository schema is invalid") from error
    if errors:
        error = errors[0]
        field = ".".join(str(part) for part in error.absolute_path) or "$"
        raise BootstrapError("schema", field, error.message)


def validate_host(host: str, field: str) -> None:
    if any(marker in host for marker in ("://", "@", "/", "?", "#", "[", "]")) or host != host.strip():
        raise BootstrapError("semantics", field, "must be a bare DNS name, IPv4 address, or IPv6 address")
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        if not DNS_RE.fullmatch(host) or host.lower() != host:
            raise BootstrapError("semantics", field, "must be a lowercase DNS name, IPv4 address, or IPv6 address")
    else:
        if address.is_unspecified or address.is_multicast or address.is_loopback or address.is_link_local or address.is_private or address.is_reserved:
            raise BootstrapError("semantics", field, "must be a publicly usable address")


def validate_https_url(value: str, field: str) -> None:
    parsed = urlsplit(value)
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password or parsed.fragment:
        raise BootstrapError("semantics", field, "must be an absolute HTTPS URL without credentials or fragment")


def strict_genesis(data: str, field: str) -> bytes:
    try:
        decoded = base64.b64decode(data.encode("ascii"), validate=True)
    except (UnicodeEncodeError, ValueError) as error:
        raise BootstrapError("semantics", field, "must be strict RFC 4648 Base64") from error
    if len(decoded) > MAX_GENESIS_BYTES:
        raise BootstrapError("size", field, f"decoded Genesis exceeds {MAX_GENESIS_BYTES} bytes")
    return decoded


def validate_document(document: object, source: Path) -> bytes:
    if not isinstance(document, dict):
        raise BootstrapError("schema", "$", "must be an object")
    validate_schema(document, source)
    chain_id = document["chain_id"]
    if not CHAIN_ID_RE.fullmatch(chain_id):
        raise BootstrapError("semantics", "chain_id", "contains unsafe characters")
    genesis = document["genesis"]
    decoded = strict_genesis(genesis["data"], "genesis.data")
    actual_hash = hashlib.sha256(decoded).hexdigest()
    if actual_hash != genesis["sha256"]:
        raise BootstrapError("semantics", "genesis.sha256", f"expected {genesis['sha256']}, actual {actual_hash}")
    try:
        genesis_text = decoded.decode("utf-8", "strict")
        genesis_json = json.loads(genesis_text, object_pairs_hook=reject_duplicates)
    except (UnicodeDecodeError, json.JSONDecodeError, BootstrapError) as error:
        if isinstance(error, BootstrapError):
            raise BootstrapError("semantics", "genesis.data", "decoded Genesis contains duplicate JSON keys") from error
        raise BootstrapError("semantics", "genesis.data", "decoded Genesis is not valid UTF-8 JSON") from error
    if not isinstance(genesis_json, dict) or genesis_json.get("chain_id") != chain_id:
        actual = genesis_json.get("chain_id") if isinstance(genesis_json, dict) else "missing"
        raise BootstrapError("semantics", "chain_id", f"expected {chain_id}, actual {actual}")
    seed_keys: set[tuple[str, str, int]] = set()
    seed_ids: set[str] = set()
    for number, seed in enumerate(document["seeds"]):
        field = f"seeds[{number}]"
        if not NODE_ID_RE.fullmatch(seed["node_id"]):
            raise BootstrapError("semantics", f"{field}.node_id", "must be 40 lowercase hexadecimal characters")
        validate_host(seed["host"], f"{field}.host")
        key = (seed["node_id"], seed["host"], seed["port"])
        if key in seed_keys or seed["node_id"] in seed_ids:
            raise BootstrapError("semantics", field, "duplicate seed")
        seed_keys.add(key)
        seed_ids.add(seed["node_id"])
    services = document.get("services", {})
    for name in ("rpc", "api"):
        for number, service in enumerate(services.get(name, [])):
            validate_https_url(service, f"services.{name}[{number}]")
    inference_urls: set[str] = set()
    for number, service in enumerate(services.get("inference", [])):
        validate_https_url(service["url"], f"services.inference[{number}].url")
        if service["url"] in inference_urls:
            raise BootstrapError("semantics", f"services.inference[{number}].url", "duplicate service URL")
        inference_urls.add(service["url"])
        auth = service.get("authentication")
        if auth and PRIVATE_CREDENTIAL_RE.search(auth["credential"]):
            raise BootstrapError("semantics", f"services.inference[{number}].authentication.credential", "looks like private credential material")
    return decoded


def canonical_json(document: object) -> bytes:
    return (json.dumps(document, sort_keys=True, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")


def command_verify(path: Path) -> int:
    document = load_json(path)
    decoded = validate_document(document, path)
    print(f"PASS network bootstrap file={path} chain_id={document['chain_id']} genesis_sha256={hashlib.sha256(decoded).hexdigest()} seeds={len(document['seeds'])}")
    print("Repository attestation was not checked by this command.")
    return 0


def command_render(input_path: Path, output_path: Path) -> int:
    document = load_json(input_path)
    validate_document(document, input_path)
    rendered = canonical_json(document)
    if len(rendered) > MAX_DOCUMENT_BYTES:
        raise BootstrapError("size", str(output_path), f"rendered document exceeds {MAX_DOCUMENT_BYTES} bytes")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = output_path.with_name(f".{output_path.name}.tmp")
    temporary.write_bytes(rendered)
    temporary.replace(output_path)
    print(f"PASS rendered network bootstrap file={output_path} sha256={hashlib.sha256(rendered).hexdigest()}")
    return 0


def command_stage(input_path: Path, destination: Path) -> int:
    document = load_json(input_path)
    decoded = validate_document(document, input_path)
    destination.mkdir(mode=0o700, parents=True, exist_ok=True)
    digest = hashlib.sha256(input_path.read_bytes()).hexdigest()
    staged = {
        "genesis.json": decoded,
        "genesis-seeds.txt": "".join(f"{seed['node_id']}@{seed['host']}:{seed['port']}\n" for seed in document["seeds"]).encode("utf-8"),
        "bootstrap.env": (
            f"bootstrap_sha256={digest}\n"
            f"bootstrap_schema={SCHEMA_URI}\n"
            f"chain_id={document['chain_id']}\n"
            f"genesis_sha256={document['genesis']['sha256']}\n"
            f"seed_host={document['seeds'][0]['host']}\n"
        ).encode("utf-8"),
    }
    services = document.get("services", {})
    inference = services.get("inference", [])
    for service in inference:
        authentication = service.get("authentication")
        if authentication:
            staged["gateway.join-client-key"] = authentication["credential"].encode("utf-8")
            break
    for name, content in staged.items():
        temporary = destination / f".{name}.tmp"
        temporary.write_bytes(content)
        temporary.chmod(0o600)
        temporary.replace(destination / name)
    print(f"PASS staged network bootstrap chain_id={document['chain_id']} genesis_sha256={document['genesis']['sha256']} seeds={len(document['seeds'])}")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    verify = subcommands.add_parser("verify")
    verify.add_argument("file", type=Path)
    render = subcommands.add_parser("render")
    render.add_argument("input", type=Path)
    render.add_argument("output", type=Path)
    stage = subcommands.add_parser("stage")
    stage.add_argument("file", type=Path)
    stage.add_argument("destination", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "verify":
            return command_verify(args.file)
        if args.command == "render":
            return command_render(args.input, args.output)
        return command_stage(args.file, args.destination)
    except BootstrapError as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
