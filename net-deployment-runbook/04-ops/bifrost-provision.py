#!/usr/bin/env python3
"""Configure the private Bifrost instance without replacing its durable state."""
import base64
import argparse
import hashlib
import json
import os
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen


class ProvisionError(RuntimeError):
    pass


OFFICIAL_IMAGE = "maximhq/bifrost@sha256:5f8215163cea192451f4b2ee5e0b583874ffe9435a5ab733e08c07aaf38ace57"


def required(name):
    value = os.environ.get(name, "")
    if not value:
        raise ProvisionError(f"{name} is required")
    return value


def loopback_url(name):
    value = required(name).rstrip("/")
    parsed = urlsplit(value)
    if parsed.scheme not in {"http", "https"} or parsed.hostname not in {"127.0.0.1", "::1"}:
        raise ProvisionError(f"{name} must be a loopback HTTP(S) URL")
    return value


class Client:
    def __init__(self, base_url, username, password):
        self.base_url = base_url
        self.basic = "Basic " + base64.b64encode(f"{username}:{password}".encode()).decode()

    def request(self, method, path, payload=None, authenticated=True):
        headers = {"Accept": "application/json"}
        data = None
        if payload is not None:
            headers["Content-Type"] = "application/json"
            data = json.dumps(payload).encode()
        if authenticated:
            headers["Authorization"] = self.basic
        request = Request(self.base_url + path, data=data, headers=headers, method=method)
        try:
            with urlopen(request, timeout=15) as response:
                body = response.read()
                return response.status, json.loads(body) if body else {}
        except HTTPError as error:
            body = error.read()
            try:
                detail = json.loads(body) if body else {}
            except json.JSONDecodeError:
                detail = {}
            return error.code, detail
        except (URLError, OSError, json.JSONDecodeError) as error:
            raise ProvisionError(f"Bifrost management request {method} {path} failed") from error


def expect(client, method, path, payload=None, authenticated=True, allowed=(200,)):
    status, result = client.request(method, path, payload, authenticated)
    if status not in allowed:
        raise ProvisionError(f"Bifrost management {method} {path} returned {status}")
    return result


def bootstrap_if_empty(client, setup_token, username, password):
    status, config = client.request("GET", "/api/config", authenticated=False)
    if status == 200:
        if config.get("auth_config") is not None:
            raise ProvisionError("Bifrost reports an administrator but accepts unauthenticated management access")
        payload = {
            "client_config": {"log_retention_days": 1},
            "auth_config": {
                "admin_username": {"value": username},
                "admin_password": {"value": password},
                "is_enabled": True,
                "setup_token": setup_token,
            },
        }
        expect(client, "PUT", "/api/config", payload, authenticated=False)
        return True
    if status == 401:
        expect(client, "GET", "/api/config")
        return False
    raise ProvisionError(f"cannot determine Bifrost bootstrap state: GET /api/config returned {status}")


def provider_payload(provider, base_url):
    return {
        "provider": provider,
        "network_config": {
            "base_url": base_url,
            "allow_private_network": True,
            "default_request_timeout_in_seconds": 60,
            "max_retries": 0,
        },
        "concurrency_and_buffer_size": {"concurrency": 8, "buffer_size": 16},
        "custom_provider_config": {"base_provider_type": "openai", "is_key_less": False},
    }


def find_provider(config, provider):
    providers = config.get("providers", [])
    if not isinstance(providers, list):
        raise ProvisionError("Bifrost provider readback is malformed")
    matches = [item for item in providers if isinstance(item, dict) and item.get("name") == provider]
    if len(matches) > 1:
        raise ProvisionError("Bifrost provider readback has duplicate provider names")
    return matches[0] if matches else None


def canonical_sha256(value):
    """Return a stable receipt hash without ever serialising credential values."""
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def desired_state():
    """Return the non-secret Bifrost state GDC is allowed to reconcile."""
    port = os.environ.get("BIFROST_PORT", "9467")
    if not port.isdigit() or not 1 <= int(port) <= 65535:
        raise ProvisionError("BIFROST_PORT must be a valid TCP port")
    return {
        "image": os.environ.get("BIFROST_IMAGE", OFFICIAL_IMAGE),
        "provider": required("BIFROST_GONKA_PROVIDER"),
        "model": required("BIFROST_GONKA_MODEL"),
        "upstream": loopback_url("BIFROST_GONKA_BASE_URL"),
        "port": int(port),
    }


def current_state(client, provider):
    """Read the management state needed for a redacted preview receipt."""
    status, config = client.request("GET", "/api/config", authenticated=False)
    if status == 200:
        if config.get("auth_config") is not None:
            raise ProvisionError("Bifrost reports an administrator but accepts unauthenticated management access")
        return {"bootstrap": "empty", "provider": None}
    if status != 401:
        raise ProvisionError(f"cannot determine Bifrost bootstrap state: GET /api/config returned {status}")
    expect(client, "GET", "/api/config")
    providers = expect(client, "GET", "/api/providers")
    existing = find_provider(providers, provider)
    if existing is None:
        return {"bootstrap": "configured", "provider": None}
    network = existing.get("network_config") or {}
    custom = existing.get("custom_provider_config") or {}
    keys = expect(client, "GET", f"/api/providers/{provider}/keys")
    key_rows = keys.get("keys", []) if isinstance(keys, dict) else []
    # The pinned release represents an empty provider-key collection as
    # {"keys": null, "total": 0}; null is a valid empty collection, not a
    # malformed readback.
    if key_rows is None:
        key_rows = []
    if not isinstance(key_rows, list):
        raise ProvisionError("Bifrost provider-key readback is malformed")
    return {
        "bootstrap": "configured",
        "provider": {
            "base_url": network.get("base_url"),
            "base_provider_type": custom.get("base_provider_type"),
            "key_count": len(key_rows),
            "models": sorted({model for row in key_rows if isinstance(row, dict) for model in row.get("models", []) if isinstance(model, str)}),
        },
    }


def preview_state(client):
    """Produce the receipt that binds apply to the observed current state."""
    desired = desired_state()
    current = current_state(client, desired["provider"])
    delta = []
    if current["bootstrap"] != "configured":
        delta.append("bootstrap")
    existing = current["provider"]
    if existing is None:
        delta.extend(["provider", "provider_key"])
    else:
        if existing["base_url"] != desired["upstream"]:
            delta.append("provider.base_url")
        if existing["base_provider_type"] != "openai":
            delta.append("provider.base_provider_type")
        if existing["key_count"] != 1:
            delta.append("provider_key.count")
        if desired["model"] not in existing["models"]:
            delta.append("provider_key.models")
    return {
        "schema": "gdc-bifrost-state/1",
        "applied": False,
        "current": current,
        "desired": desired,
        "before_sha256": canonical_sha256(current),
        "desired_sha256": canonical_sha256(desired),
        "delta": delta,
    }


def provision():
    management_url = loopback_url("BIFROST_MANAGEMENT_URL")
    username = required("BIFROST_ADMIN_USERNAME")
    password = required("BIFROST_ADMIN_PASSWORD")
    if len(password.encode()) < 12 or not all(any(predicate(char) for char in password) for predicate in (str.isupper, str.islower, str.isdigit)) or not any(not char.isalnum() for char in password):
        raise ProvisionError("BIFROST_ADMIN_PASSWORD does not meet the pinned Bifrost password policy")
    desired = desired_state()
    provider = desired["provider"]
    model = desired["model"]
    upstream = desired["upstream"]
    provider_key = required("BIFROST_GONKA_PROVIDER_KEY")
    setup_token = required("BIFROST_SETUP_TOKEN")
    client = Client(management_url, username, password)
    bootstrapped = bootstrap_if_empty(client, setup_token, username, password)

    providers = expect(client, "GET", "/api/providers")
    existing = find_provider(providers, provider)
    if existing is None:
        expect(client, "POST", "/api/providers", provider_payload(provider, upstream))
    else:
        network = existing.get("network_config") or {}
        custom = existing.get("custom_provider_config") or {}
        if network.get("base_url") != upstream or custom.get("base_provider_type") != "openai":
            raise ProvisionError("existing Bifrost provider does not match the managed stable Gonka target")

    keys = expect(client, "GET", f"/api/providers/{provider}/keys")
    key_rows = keys.get("keys", []) if isinstance(keys, dict) else []
    if key_rows is None:
        key_rows = []
    if not isinstance(key_rows, list):
        raise ProvisionError("Bifrost provider-key readback is malformed")
    if len(key_rows) == 0:
        created = expect(client, "POST", f"/api/providers/{provider}/keys", {
            "value": {"value": provider_key}, "models": [model], "enabled": True,
        })
        key_id = created.get("id") if isinstance(created, dict) else None
    elif len(key_rows) == 1:
        key_id = key_rows[0].get("id") if isinstance(key_rows[0], dict) else None
        models = key_rows[0].get("models", []) if isinstance(key_rows[0], dict) else []
        if model not in models:
            raise ProvisionError("existing Bifrost provider key does not allow the managed stable Gonka model")
    else:
        raise ProvisionError("Bifrost provider has multiple keys; refuse ambiguous virtual-key binding")
    if not isinstance(key_id, str) or not key_id:
        raise ProvisionError("Bifrost provider key readback has no ID")
    # This is consumed by the private broker service only. It deliberately has
    # no credential values and is replaced atomically after a successful readback.
    output = required("BIFROST_BROKER_BINDING_FILE")
    temporary = output + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        handle.write(f"BIFROST_GONKA_PROVIDER={provider}\nBIFROST_GONKA_MODEL={model}\nBIFROST_GONKA_KEY_ID={key_id}\n")
    # The broker sees this single file read-only. It has object IDs only;
    # credentials remain in its root-only env file.
    os.chmod(temporary, 0o444)
    os.replace(temporary, output)
    return {"bootstrap": bootstrapped, "provider": provider, "model": model, "key_id": key_id}


def client_from_environment():
    return Client(loopback_url("BIFROST_MANAGEMENT_URL"), required("BIFROST_ADMIN_USERNAME"), required("BIFROST_ADMIN_PASSWORD"))


def main(argv):
    # Existing direct GDC provisioning remains available while phase-bifrost is
    # migrated to the receipt-bound invocation below.
    if not argv:
        print(json.dumps(provision(), sort_keys=True))
        return
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--preview", action="store_true")
    group.add_argument("--apply", action="store_true")
    parser.add_argument("--expected-sha256")
    arguments = parser.parse_args(argv)
    client = client_from_environment()
    receipt = preview_state(client)
    if arguments.preview:
        if arguments.expected_sha256:
            raise ProvisionError("--expected-sha256 is valid only with --apply")
        print(json.dumps(receipt, sort_keys=True))
        return
    if arguments.expected_sha256 != receipt["before_sha256"]:
        raise ProvisionError("Bifrost preview is stale; current state fingerprint changed")
    if not receipt["delta"]:
        receipt["outcome"] = "no-change"
        print(json.dumps(receipt, sort_keys=True))
        return
    provision()
    after = preview_state(client)
    if after["delta"]:
        raise ProvisionError("Bifrost apply completed without converging to desired state")
    after.update({"applied": True, "outcome": "PASS", "before_sha256": receipt["before_sha256"]})
    print(json.dumps(after, sort_keys=True))


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except ProvisionError as error:
        print(f"ERROR {error}", file=sys.stderr)
        sys.exit(1)
