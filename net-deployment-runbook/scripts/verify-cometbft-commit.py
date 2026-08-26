#!/usr/bin/env python3
"""Verify one CometBFT/Tendermint commit using canonical v0.34 semantics."""

import base64
import binascii
import datetime
import hashlib
import json
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile

MAX_COMMIT_BYTES = 8 * 1024 * 1024
MAX_SIGNATURES = 10_000
MAX_INT64 = (1 << 63) - 1
MAX_INT32 = (1 << 31) - 1
MAX_UINT32 = (1 << 32) - 1
MAX_UINT64 = (1 << 64) - 1


class InvalidCommit(ValueError):
    pass


def fail(message):
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def object_without_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise InvalidCommit("duplicate JSON key")
        result[key] = value
    return result


def require_object(value, label):
    if not isinstance(value, dict):
        raise InvalidCommit(f"{label} is not an object")
    return value


def require_json_integer(value, minimum, maximum, label):
    if isinstance(value, bool) or not isinstance(value, int):
        raise InvalidCommit(f"{label} is not an integer")
    if value < minimum or value > maximum:
        raise InvalidCommit(f"{label} is out of range")
    return value


def require_decimal_string(value, minimum, maximum, label):
    if not isinstance(value, str) or re.fullmatch(r"0|[1-9][0-9]*", value) is None:
        raise InvalidCommit(f"{label} is not a canonical integer string")
    number = int(value)
    if number < minimum or number > maximum:
        raise InvalidCommit(f"{label} is out of range")
    return number


def require_hex(value, byte_lengths, label, allow_empty=False):
    if not isinstance(value, str):
        raise InvalidCommit(f"{label} is not a string")
    if value == "" and allow_empty:
        return b""
    if len(value) not in {length * 2 for length in byte_lengths}:
        raise InvalidCommit(f"{label} has the wrong size")
    if re.fullmatch(r"[0-9A-Fa-f]+", value) is None:
        raise InvalidCommit(f"{label} is not hexadecimal")
    return bytes.fromhex(value)


def require_base64(value, expected_size, label):
    if not isinstance(value, str):
        raise InvalidCommit(f"{label} is not a string")
    try:
        decoded = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as error:
        raise InvalidCommit(f"{label} is not base64") from error
    if len(decoded) != expected_size or base64.b64encode(decoded).decode("ascii") != value:
        raise InvalidCommit(f"{label} is not canonical {expected_size}-byte base64")
    return decoded


def parse_timestamp(value, label):
    if not isinstance(value, str):
        raise InvalidCommit(f"{label} is not a string")
    match = re.fullmatch(
        r"([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,9}))?Z",
        value,
    )
    if match is None:
        raise InvalidCommit(f"{label} is not a canonical UTC RFC3339 timestamp")
    year, month, day, hour, minute, second = map(int, match.groups()[:6])
    if year == 0:
        raise InvalidCommit(f"{label} year is out of range")
    try:
        instant = datetime.datetime(year, month, day, hour, minute, second)
    except ValueError as error:
        raise InvalidCommit(f"{label} is not a real timestamp") from error
    epoch = datetime.datetime(1970, 1, 1)
    seconds = (instant - epoch).days * 86400 + (instant - epoch).seconds
    nanos = int((match.group(7) or "").ljust(9, "0") or "0")
    return seconds, nanos


def varint(value):
    if value < 0:
        value &= MAX_UINT64
    encoded = bytearray()
    while value >= 0x80:
        encoded.append((value & 0x7F) | 0x80)
        value >>= 7
    encoded.append(value)
    return bytes(encoded)


def field_key(number, wire_type):
    return varint((number << 3) | wire_type)


def varint_field(number, value):
    return b"" if value == 0 else field_key(number, 0) + varint(value)


def bytes_field(number, value):
    return field_key(number, 2) + varint(len(value)) + value


def message_field(number, value):
    return b"" if not value else bytes_field(number, value)


def protobuf_timestamp(value, label):
    seconds, nanos = parse_timestamp(value, label)
    return varint_field(1, seconds) + varint_field(2, nanos)


def part_set_from_json(value, label, allow_empty=False):
    part_set = require_object(value, label)
    total = require_json_integer(part_set.get("total"), 0, MAX_UINT32, f"{label}.total")
    if total == 0 and allow_empty:
        if part_set.get("hash") != "":
            raise InvalidCommit(f"{label} has a hash for an empty part set")
        return total, b""
    if total == 0:
        raise InvalidCommit(f"{label}.total must be positive")
    digest = require_hex(part_set.get("hash"), {32}, f"{label}.hash")
    return total, digest


def block_id_from_json(value, label, allow_empty=False):
    block_id = require_object(value, label)
    if allow_empty and block_id.get("hash") == "":
        digest = b""
    else:
        digest = require_hex(block_id.get("hash"), {32}, f"{label}.hash")
    aliases = [name for name in ("parts", "part_set_header") if name in block_id]
    if len(aliases) != 1:
        raise InvalidCommit(f"{label} must contain exactly one parts header")
    total, parts_hash = part_set_from_json(
        block_id[aliases[0]], f"{label}.{aliases[0]}", allow_empty=allow_empty
    )
    if (not digest) != (total == 0):
        raise InvalidCommit(f"{label} has an inconsistent empty block ID")
    parts = varint_field(1, total) + (bytes_field(2, parts_hash) if parts_hash else b"")
    encoded = (bytes_field(1, digest) if digest else b"") + bytes_field(2, parts)
    return digest, total, parts_hash, encoded


def merkle_hash(leaves):
    if not leaves:
        return hashlib.sha256(b"").digest()
    if len(leaves) == 1:
        return hashlib.sha256(b"\x00" + leaves[0]).digest()
    split = 1 << ((len(leaves) - 1).bit_length() - 1)
    return hashlib.sha256(
        b"\x01" + merkle_hash(leaves[:split]) + merkle_hash(leaves[split:])
    ).digest()


def header_hash(header, expected_chain, expected_height):
    header = require_object(header, "signed header")
    version = require_object(header.get("version"), "header.version")
    block_version = require_decimal_string(
        version.get("block"), 0, MAX_UINT64, "header.version.block"
    )
    app_version_value = version.get("app", "0")
    app_version = require_decimal_string(
        app_version_value, 0, MAX_UINT64, "header.version.app"
    )
    version_bytes = varint_field(1, block_version) + varint_field(2, app_version)
    chain_id = header.get("chain_id")
    if not isinstance(chain_id, str) or chain_id != expected_chain:
        raise InvalidCommit("header chain ID does not match")
    if require_decimal_string(header.get("height"), 1, MAX_INT64, "header.height") != expected_height:
        raise InvalidCommit("header height does not match")
    header_time = protobuf_timestamp(header.get("time"), "header.time")
    last_block = header.get("last_block_id")
    if last_block is None:
        last_block_bytes = bytes_field(2, b"")
    else:
        _, _, _, last_block_bytes = block_id_from_json(
            last_block, "header.last_block_id", allow_empty=True
        )

    fixed_hashes = {
        "validators_hash": {32},
        "next_validators_hash": {32},
        "consensus_hash": {32},
        "proposer_address": {20},
    }
    optional_hashes = {
        "last_commit_hash": {32},
        "data_hash": {32},
        "last_results_hash": {32},
        "evidence_hash": {32},
    }
    decoded = {}
    for name, sizes in fixed_hashes.items():
        decoded[name] = require_hex(header.get(name), sizes, f"header.{name}")
    for name, sizes in optional_hashes.items():
        decoded[name] = require_hex(
            header.get(name), sizes, f"header.{name}", allow_empty=True
        )
    app_hash_value = header.get("app_hash")
    if not isinstance(app_hash_value, str) or len(app_hash_value) % 2:
        raise InvalidCommit("header.app_hash has an invalid size")
    if app_hash_value and re.fullmatch(r"[0-9A-Fa-f]+", app_hash_value) is None:
        raise InvalidCommit("header.app_hash is not hexadecimal")
    decoded["app_hash"] = bytes.fromhex(app_hash_value)

    def wrapped_bytes(value):
        return bytes_field(1, value) if value else b""

    leaves = [
        version_bytes,
        bytes_field(1, chain_id.encode("utf-8")),
        varint_field(1, expected_height),
        header_time,
        last_block_bytes,
        wrapped_bytes(decoded["last_commit_hash"]),
        wrapped_bytes(decoded["data_hash"]),
        wrapped_bytes(decoded["validators_hash"]),
        wrapped_bytes(decoded["next_validators_hash"]),
        wrapped_bytes(decoded["consensus_hash"]),
        wrapped_bytes(decoded["app_hash"]),
        wrapped_bytes(decoded["last_results_hash"]),
        wrapped_bytes(decoded["evidence_hash"]),
        wrapped_bytes(decoded["proposer_address"]),
    ]
    return merkle_hash(leaves)


def canonical_vote_bytes(chain_id, height, round_number, block_id, timestamp):
    block_hash, total, parts_hash, _ = block_id
    parts = varint_field(1, total) + bytes_field(2, parts_hash)
    canonical_block_id = bytes_field(1, block_hash) + message_field(2, parts)
    vote = (
        varint_field(1, 2)
        + field_key(2, 1)
        + struct.pack("<q", height)
        + (field_key(3, 1) + struct.pack("<q", round_number) if round_number else b"")
        + message_field(4, canonical_block_id)
        + bytes_field(5, protobuf_timestamp(timestamp, "commit signature timestamp"))
        + bytes_field(6, chain_id.encode("utf-8"))
    )
    return varint(len(vote)) + vote


def verify_ed25519(public_key, signature, sign_bytes):
    openssl = shutil.which("openssl")
    if openssl is None:
        raise InvalidCommit("OpenSSL is unavailable")
    # RFC 8410 SubjectPublicKeyInfo prefix for a raw 32-byte Ed25519 public key.
    public_der = bytes.fromhex("302a300506032b6570032100") + public_key
    with tempfile.TemporaryDirectory(prefix="gdc-commit-verify-") as work:
        public_path = os.path.join(work, "public.der")
        signature_path = os.path.join(work, "signature.raw")
        sign_bytes_path = os.path.join(work, "sign-bytes.raw")
        for path, contents in (
            (public_path, public_der),
            (signature_path, signature),
            (sign_bytes_path, sign_bytes),
        ):
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as output:
                output.write(contents)
        result = subprocess.run(
            [
                openssl,
                "pkeyutl",
                "-verify",
                "-pubin",
                "-inkey",
                public_path,
                "-keyform",
                "DER",
                "-rawin",
                "-in",
                sign_bytes_path,
                "-sigfile",
                signature_path,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    if result.returncode != 0:
        raise InvalidCommit("Ed25519 commit signature verification failed")


def load_commit(path):
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError as error:
        raise InvalidCommit("commit evidence cannot be opened safely") from error
    with os.fdopen(descriptor, "rb") as source:
        status = os.fstat(source.fileno())
        if not stat.S_ISREG(status.st_mode) or status.st_size <= 0 or status.st_size > MAX_COMMIT_BYTES:
            raise InvalidCommit("commit evidence size or type is invalid")
        try:
            return json.load(source, object_pairs_hook=object_without_duplicates)
        except (json.JSONDecodeError, UnicodeDecodeError) as error:
            raise InvalidCommit("commit evidence is not valid JSON") from error


def verify(path, expected_chain, expected_height_text, expected_key_text, expected_address):
    expected_height = require_decimal_string(
        expected_height_text, 1, MAX_INT64, "expected height"
    )
    public_key = require_base64(expected_key_text, 32, "expected consensus public key")
    derived_address = hashlib.sha256(public_key).digest()[:20].hex().upper()
    if expected_address != "-" and expected_address != derived_address:
        raise InvalidCommit("expected consensus address is not derived from the public key")

    document = require_object(load_commit(path), "commit evidence")
    result = require_object(document.get("result"), "result")
    if result.get("canonical") is not True:
        raise InvalidCommit("commit response is not canonical")
    signed_header = require_object(result.get("signed_header"), "signed_header")
    commit = require_object(signed_header.get("commit"), "commit")
    if require_decimal_string(commit.get("height"), 1, MAX_INT64, "commit.height") != expected_height:
        raise InvalidCommit("commit height does not match")
    round_number = require_json_integer(commit.get("round"), 0, MAX_INT32, "commit.round")
    block_id = block_id_from_json(commit.get("block_id"), "commit.block_id")
    computed_header_hash = header_hash(
        signed_header.get("header"), expected_chain, expected_height
    )
    if block_id[0] != computed_header_hash:
        raise InvalidCommit("commit block ID is not the canonical signed header hash")

    signatures = commit.get("signatures")
    if not isinstance(signatures, list) or not signatures or len(signatures) > MAX_SIGNATURES:
        raise InvalidCommit("commit signatures are missing or excessive")
    seen = set()
    match = None
    for index, raw_signature in enumerate(signatures):
        item = require_object(raw_signature, f"commit.signatures[{index}]")
        flag = require_json_integer(item.get("block_id_flag"), 1, 3, "block_id_flag")
        timestamp = item.get("timestamp")
        parse_timestamp(timestamp, "commit signature timestamp")
        address = item.get("validator_address")
        if flag == 1:
            if address != "" or item.get("signature") is not None:
                raise InvalidCommit("absent commit signature has non-empty identity material")
            continue
        address_bytes = require_hex(address, {20}, "commit validator address")
        canonical_address = address_bytes.hex().upper()
        signature = require_base64(item.get("signature"), 64, "commit signature")
        if canonical_address in seen:
            raise InvalidCommit("duplicate commit validator address")
        seen.add(canonical_address)
        if expected_address != "-" and canonical_address == expected_address:
            if match is not None:
                raise InvalidCommit("duplicate expected commit signature")
            match = (flag, timestamp, signature)

    signed = False
    verified_timestamp = None
    if match is not None and match[0] == 2:
        sign_bytes = canonical_vote_bytes(
            expected_chain, expected_height, round_number, block_id, match[1]
        )
        verify_ed25519(public_key, match[2], sign_bytes)
        signed = True
        verified_timestamp = match[1]
    return {
        "signed": signed,
        "header_hash": computed_header_hash.hex().upper(),
        "commit_round": round_number,
        "verified_signature_timestamp": verified_timestamp,
    }


def main():
    if len(sys.argv) != 6:
        fail(
            "usage: verify-cometbft-commit.py COMMIT CHAIN_ID HEIGHT CONSENSUS_KEY CONSENSUS_ADDRESS_OR_DASH"
        )
    try:
        result = verify(*sys.argv[1:])
    except (InvalidCommit, OSError, OverflowError, UnicodeError) as error:
        fail(str(error))
    json.dump(result, sys.stdout, separators=(",", ":"), sort_keys=True)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
