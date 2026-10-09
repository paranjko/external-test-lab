#!/usr/bin/env python3
"""Read-only public bootstrap monitoring; Telegram credentials belong only to notify."""
from __future__ import annotations

import argparse
import hashlib
import html
import importlib.util
import json
import os
import re
import socket
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

ROOT = Path(__file__).resolve().parent.parent
SCHEMA_URL = "https://gonka-dev.net/v1.bootstrap.schema.json"
DOCUMENT_LIMIT = 256 * 1024
GENESIS_LIMIT = 64 * 1024 * 1024


class MonitorError(ValueError):
    pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise MonitorError("HTTP redirect refused")


def strict_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise MonitorError("duplicate JSON key")
            result[key] = value
        return result

    def constant(_):
        raise MonitorError("non-finite JSON number")

    return json.loads(data, object_pairs_hook=pairs, parse_constant=constant)


def safe_url(url):
    parsed = urlsplit(url)
    if (parsed.scheme not in ("http", "https") or not parsed.hostname
            or parsed.username or parsed.password or parsed.fragment):
        raise MonitorError("invalid HTTP URL")
    return parsed


class Transport:
    def __init__(self, timeout=10, attempts=2):
        self.timeout = timeout
        self.attempts = attempts
        self.opener = build_opener(NoRedirect())

    def get(self, url, limit=DOCUMENT_LIMIT):
        safe_url(url)
        for attempt in range(self.attempts):
            try:
                request = Request(url, headers={"User-Agent": "gonka-bootstrap-monitor/1"})
                with self.opener.open(request, timeout=self.timeout) as response:
                    data = response.read(limit + 1)
                if len(data) > limit:
                    raise MonitorError("response exceeds size limit")
                return data
            except HTTPError as error:
                if error.code not in (408, 429, 500, 502, 503, 504) or attempt + 1 == self.attempts:
                    raise MonitorError(f"HTTP {error.code}") from None
            except (URLError, TimeoutError, OSError):
                if attempt + 1 == self.attempts:
                    raise MonitorError("connection failed or timed out") from None
            time.sleep(1)
        raise MonitorError("request failed")

    def tcp(self, url):
        parsed = urlsplit(url)
        if parsed.scheme != "tcp" or not parsed.hostname or not parsed.port:
            raise MonitorError("invalid P2P endpoint")
        for attempt in range(self.attempts):
            try:
                with socket.create_connection((parsed.hostname, parsed.port), timeout=self.timeout):
                    return
            except OSError:
                if attempt + 1 == self.attempts:
                    raise MonitorError("P2P connection failed or timed out") from None
                time.sleep(1)


def genesis_bytes(payload):
    """Match inferenced download-genesis: preserve result.genesis RawMessage bytes."""
    document = strict_json(payload)
    if (not isinstance(document, dict) or not isinstance(document.get("result"), dict)
            or not isinstance(document["result"].get("genesis"), dict)):
        raise MonitorError("RPC response has no genesis object")
    decoder = json.JSONDecoder()

    def member(text, name):
        position = text.index("{") + 1
        while True:
            position += len(text[position:]) - len(text[position:].lstrip())
            key, position = decoder.raw_decode(text, position)
            position += len(text[position:]) - len(text[position:].lstrip())
            position += 1  # colon; the entire document was already strictly parsed
            position += len(text[position:]) - len(text[position:].lstrip())
            _, end = decoder.raw_decode(text, position)
            if key == name:
                return text[position:end]
            position = end + len(text[end:]) - len(text[end:].lstrip())
            if text[position] != ",":
                raise MonitorError("RPC member missing")
            position += 1

    return member(member(payload.decode("utf-8"), "result"), "genesis").encode("utf-8")


def load_schema(transport):
    schema = strict_json(transport.get(SCHEMA_URL))
    if not isinstance(schema, dict) or schema.get("$id") != SCHEMA_URL:
        raise MonitorError("published schema has the wrong identity")

    def local_refs(value):
        if isinstance(value, dict):
            for key, item in value.items():
                if key in ("$ref", "$dynamicRef") and (not isinstance(item, str) or not item.startswith("#")):
                    raise MonitorError("external schema references are not supported")
                local_refs(item)
        elif isinstance(value, list):
            for item in value:
                local_refs(item)

    local_refs(schema)
    return schema


def validator():
    spec = importlib.util.spec_from_file_location("network_bootstrap", ROOT / "scripts/network-bootstrap.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def check_bootstrap(chain_id, url, schema, transport):
    result = {"chain_id": chain_id, "bootstrap_url": url, "ok": False, "checks": []}

    def check(stage, endpoint, operation):
        item = {"stage": stage, "url": endpoint, "ok": False}
        result["checks"].append(item)
        try:
            value = operation()
            item["ok"] = True
            return value
        except Exception as error:
            # Never dump payloads, credentials, or unbounded schema validation errors.
            item["error"] = str(error)[:400] if isinstance(error, MonitorError) else type(error).__name__
            return None

    def document():
        doc = strict_json(transport.get(url))
        contract = validator()
        try:
            contract.validate(doc, schema=schema)
        except contract.BootstrapError as error:
            raise MonitorError(str(error)) from None
        if doc["chain_id"] != chain_id:
            raise MonitorError("bootstrap chain ID differs from requested network")
        return doc

    doc = check("bootstrap", url, document)
    if doc is None:
        return result

    for seed in doc["seeds"]:
        rpc = seed["rpc"].rstrip("/")

        def status(seed=seed, rpc=rpc):
            observed = strict_json(transport.get(rpc + "/status"))["result"]
            if observed["node_info"]["id"] != seed["node_id"]:
                raise MonitorError("RPC node ID differs from bootstrap")
            if observed["node_info"]["network"] != chain_id:
                raise MonitorError("RPC chain ID differs from bootstrap")

        def genesis(rpc=rpc):
            raw = genesis_bytes(transport.get(rpc + "/genesis", GENESIS_LIMIT))
            if hashlib.sha256(raw).hexdigest() != doc["genesis"]["sha256"]:
                raise MonitorError("genesis SHA-256 differs from bootstrap")
            if strict_json(raw).get("chain_id") != chain_id:
                raise MonitorError("genesis chain ID differs from bootstrap")

        check("rpc", rpc + "/status", status)
        check("genesis", rpc + "/genesis", genesis)
        check("p2p", seed["p2p"], lambda seed=seed: transport.tcp(seed["p2p"]))
        if "api" in seed:
            endpoint = seed["api"].rstrip("/") + "/v1/participants"

            def participants(endpoint=endpoint):
                if not isinstance(strict_json(transport.get(endpoint, GENESIS_LIMIT)).get("participants"), list):
                    raise MonitorError("participant API has no participants array")

            check("api", endpoint, participants)
    result["ok"] = all(item["ok"] for item in result["checks"])
    return result


def targets(release_dir, base_url):
    safe_url(base_url)
    networks = [path.stem for path in sorted(release_dir.glob("gonka-*.json"))]
    if not networks:
        raise MonitorError("no bootstrap descriptors in release directory")
    if any(not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", name) for name in networks):
        raise MonitorError("invalid network name in release inventory")
    return [(name, f"{base_url.rstrip('/')}/{name}/bootstrap.json") for name in networks]


def run_checks(networks, transport):
    try:
        schema = load_schema(transport)
    except Exception as error:
        reason = str(error)[:400] if isinstance(error, MonitorError) else type(error).__name__
        return [{"chain_id": name, "bootstrap_url": url, "ok": False,
                 "checks": [{"stage": "schema", "url": SCHEMA_URL, "ok": False, "error": reason}]}
                for name, url in networks]
    return [check_bootstrap(name, url, schema, transport) for name, url in networks]


def telegram_payload(result, chat_id, run_url, run_id):
    safe_url(result["bootstrap_url"])
    safe_url(run_url)
    escape = html.escape
    text = (f'<b>⚠️ Warning:</b> The Bootstrap <a href="{escape(result["bootstrap_url"], quote=True)}">'
            f'{escape(result["chain_id"])}</a> needs to be updated, validation for '
            f'<a href="{escape(run_url, quote=True)}">'
            f'{escape(run_id)}</a> failed')
    return {"chat_id": chat_id, "text": text, "parse_mode": "HTML"}


def send_telegram(token, payload):
    if not re.fullmatch(r"[0-9]+:[A-Za-z0-9_-]+", token):
        raise MonitorError("invalid Telegram bot token format")
    request = Request(f"https://api.telegram.org/bot{token}/sendMessage",
                      data=json.dumps(payload).encode("utf-8"),
                      headers={"Content-Type": "application/json"}, method="POST")
    try:
        # Do not retry POST: a lost response might already have delivered the message.
        with build_opener(NoRedirect()).open(request, timeout=20) as response:
            data = response.read(DOCUMENT_LIMIT + 1)
        if len(data) > DOCUMENT_LIMIT:
            raise MonitorError("Telegram response exceeds size limit")
        reply = strict_json(data)
        if not isinstance(reply, dict) or reply.get("ok") is not True:
            raise MonitorError("Telegram rejected the notification")
    except Exception:
        # HTTP exceptions can contain the secret-bearing request URL.
        raise MonitorError("Telegram notification failed; verify token, chat permissions and connectivity") from None


def notify(results, environment, sender=send_telegram):
    failed = [result for result in results if not result["ok"]]
    if not failed:
        print("PASS no failed bootstraps; no Telegram message")
        return 0
    token = environment.get("GDC_TELEGRAM_BOT_TOKEN", "")
    chat = environment.get("GDC_TELEGRAM_NOTIFICATION", "")
    run_id = environment.get("GITHUB_RUN_ID", "")
    repository = environment.get("GITHUB_REPOSITORY", "")
    if not all((token, chat, run_id, repository)):
        raise MonitorError("notification requires Telegram token/chat and GitHub run context")
    run_url = f'{environment.get("GITHUB_SERVER_URL", "https://github.com")}/{repository}/actions/runs/{run_id}'
    failures = 0
    for result in failed:
        try:
            sender(token, telegram_payload(result, chat, run_url, run_id))
            print(f'SENT bootstrap warning chain_id={result["chain_id"]}')
        except MonitorError as error:
            failures += 1
            print(str(error), file=sys.stderr)
    return 1 if failures else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "notify"))
    parser.add_argument("--release-dir", type=Path, default=ROOT / "bootstrap/release")
    parser.add_argument("--base-url", default="https://gonka-dev.net")
    parser.add_argument("--report", type=Path, default=ROOT / ".data/bootstrap-monitor/report.json")
    args = parser.parse_args(argv)
    try:
        if args.command == "notify":
            return notify(strict_json(args.report.read_bytes())["results"], os.environ)
        results = run_checks(targets(args.release_dir, args.base_url), Transport())
        failed = sum(not result["ok"] for result in results)
        report = {"observed_at": datetime.now(timezone.utc).isoformat(), "results": results}
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")
        for result in results:
            print(f'{"PASS" if result["ok"] else "FAIL"} {result["chain_id"]} {result["bootstrap_url"]}')
            for check in result["checks"]:
                if not check["ok"]:
                    print(f'  {check["stage"]}: {check["url"]}: {check["error"]}')
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                output.write(f'failed={str(bool(failed)).lower()}\n')
        return 1 if failed else 0
    except (MonitorError, OSError, ValueError, KeyError) as error:
        print(f"bootstrap monitor: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
