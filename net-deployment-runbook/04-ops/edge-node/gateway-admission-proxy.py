#!/usr/bin/env python3
"""Bounded public-edge admission with one and only one gateway dispatch."""
import http.client
import json
import os
import re
import socket
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
from urllib.request import Request, urlopen


def env(name, default):
    return os.environ.get(name, str(default))


HOST = env("GDC_GATEWAY_ADMISSION_HOST", "127.0.0.1")
PORT = int(env("GDC_GATEWAY_ADMISSION_PORT", 18083))
UPSTREAM = urlsplit(env("GDC_GATEWAY_ADMISSION_UPSTREAM", "http://127.0.0.1:18080"))
STATUS_URL = env("GDC_GATEWAY_ADMISSION_STATUS_URL", "http://127.0.0.1:18080/v1/status")
EPOCH_URL = env("GDC_GATEWAY_ADMISSION_EPOCH_URL", "http://127.0.0.1:1317/productscience/inference/inference/current_epoch_group_data")
CHAIN_STATUS_URL = env("GDC_GATEWAY_ADMISSION_CHAIN_STATUS_URL", "http://127.0.0.1:26657/status")
CHAIN_PARAMS_URL = env("GDC_GATEWAY_ADMISSION_CHAIN_PARAMS_URL", "http://127.0.0.1:1317/productscience/inference/inference/params")
SAFE_GUARD_BLOCKS = int(env("GDC_GATEWAY_ADMISSION_SAFE_GUARD_BLOCKS", 10))
MAX_QUEUE = int(env("GDC_GATEWAY_ADMISSION_MAX_QUEUE", 16))
# Requests without an explicit deadline keep a short bounded default. Exact
# boundary observers may supply a longer deadline because three simultaneous
# arrivals are serialized through one upstream permit and can spend most of
# the default budget waiting for post-PoC recovery.
MAX_WAIT = float(env("GDC_GATEWAY_ADMISSION_MAX_WAIT_SECONDS", 300))
MAX_DEADLINE_WAIT = float(env("GDC_GATEWAY_ADMISSION_MAX_DEADLINE_SECONDS", 900))
POLL = float(env("GDC_GATEWAY_ADMISSION_POLL_SECONDS", 0.25))
MAX_BODY = int(env("GDC_GATEWAY_ADMISSION_MAX_BODY_BYTES", 1048576))
MAX_DISPATCHES_PER_BLOCK = int(env("GDC_GATEWAY_ADMISSION_MAX_DISPATCHES_PER_BLOCK", 1))
AUDIT_FILE = env("GDC_GATEWAY_ADMISSION_AUDIT_FILE", "/edge/status/gateway-admission.jsonl")
if not (MAX_QUEUE > 0 and MAX_WAIT > 0 and MAX_DEADLINE_WAIT >= MAX_WAIT
        and POLL > 0 and MAX_BODY > 0
        and SAFE_GUARD_BLOCKS > 0 and MAX_DISPATCHES_PER_BLOCK > 0):
    raise SystemExit("gateway admission configuration must be positive")
SLOTS = threading.BoundedSemaphore(MAX_QUEUE)
DISPATCH_PERMIT = threading.BoundedSemaphore(1)
DISPATCH_LOCK = threading.Lock()
AUDIT_LOCK = threading.Lock()
DISPATCHES_BY_HEIGHT = {}
COMPLETION_PATH = re.compile(r"^/(?:v1/chat/completions|devshard/[0-9]+/v1/chat/completions)$")
UPSTREAM_CONTENT_TYPES = {
    "application/json": "application/json",
    "text/event-stream": "text/event-stream",
    "text/plain": "text/plain",
}
PROTOCOL_CONTRACTS = {}


def load_protocol_contracts(value):
    """Validate the immutable protocol tuples accepted by this deployment."""
    try:
        contracts = json.loads(value)
    except (TypeError, ValueError) as error:
        raise ValueError("gateway admission protocol contracts are not valid JSON") from error
    if not isinstance(contracts, dict) or not contracts:
        raise ValueError("gateway admission protocol contracts must be a non-empty object")
    for version, contract in contracts.items():
        if not isinstance(version, str) or not re.fullmatch(r"v[1-9][0-9]*", version):
            raise ValueError("gateway admission protocol version is invalid")
        if not isinstance(contract, dict) or set(contract) != {"binary", "sha256"}:
            raise ValueError("gateway admission protocol contract is invalid")
        binary = contract["binary"]
        digest = contract["sha256"]
        parsed = urlsplit(binary) if isinstance(binary, str) else None
        if parsed is None or parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ValueError("gateway admission protocol binary URL is invalid")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError("gateway admission protocol SHA-256 is invalid")
    return contracts


def valid_approved_versions(versions):
    """Require one structurally valid immutable tuple per protocol name."""
    if not isinstance(versions, list):
        return False
    names = set()
    for entry in versions:
        if not isinstance(entry, dict):
            return False
        name = entry.get("name")
        binary = entry.get("binary")
        digest = entry.get("sha256")
        parsed = urlsplit(binary) if isinstance(binary, str) else None
        if (not isinstance(name, str)
                or not re.fullmatch(r"v[1-9][0-9]*", name)
                or name in names
                or parsed is None or parsed.scheme != "https" or not parsed.netloc
                or not isinstance(digest, str)
                or not re.fullmatch(r"[0-9a-f]{64}", digest)):
            return False
        names.add(name)
    return True


def runtime_protocol_version(item, runtime):
    """Normalize legacy and current gateway status fields fail closed."""
    observed = []
    containers = [runtime]
    if item is not runtime:
        containers.append(item)
    for container in containers:
        for field in ("session_version", "protocol_version"):
            if field not in container:
                continue
            value = container[field]
            if not isinstance(value, str):
                return None
            if re.fullmatch(r"[1-9][0-9]*", value):
                value = "v" + value
            elif not re.fullmatch(r"v[1-9][0-9]*", value):
                return None
            observed.append(value)
    if not observed or len(set(observed)) != 1:
        return None
    return observed[0]


def now_ms():
    return int(time.time() * 1000)


def record_audit(record):
    """Append sanitized admission facts only – never headers, keys, or prompts."""
    directory = os.path.dirname(AUDIT_FILE)
    if directory:
        os.makedirs(directory, exist_ok=True)
    encoded = json.dumps(record, separators=(",", ":"), sort_keys=True)
    with AUDIT_LOCK:
        with open(AUDIT_FILE, "a", encoding="utf-8") as output:
            output.write(encoded + "\n")


def dispatch_failure(error):
    """Return a sanitized, machine-readable transport failure classification."""
    if isinstance(error, (socket.timeout, TimeoutError)):
        return 504, "gateway_dispatch_timeout"
    if isinstance(error, (ConnectionRefusedError, ConnectionResetError,
                          ConnectionAbortedError, BrokenPipeError)):
        return 502, "gateway_dispatch_connection_failed"
    if isinstance(error, http.client.HTTPException):
        return 502, "gateway_dispatch_protocol_failed"
    if isinstance(error, OSError):
        return 502, "gateway_dispatch_io_failed"
    return 502, "gateway_dispatch_failed"


def upstream_timeout(deadline):
    """Honor the caller's absolute deadline at the one upstream connection."""
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("absolute deadline elapsed")
    return remaining


def safe_upstream_content_type(value):
    """Map untrusted upstream metadata to a fixed response-header value."""
    media_type = value.split(";", 1)[0].strip().lower()
    return UPSTREAM_CONTENT_TYPES.get(media_type, "application/octet-stream")


def get_json(url, deadline=None):
    timeout = 3
    if deadline is not None:
        timeout = upstream_timeout(deadline)
    with urlopen(Request(url, headers={"Accept": "application/json"}), timeout=timeout) as response:
        if response.status != 200:
            raise ValueError("state response was not successful")
        payload = json.load(response)
    # JSON parsing may finish after the socket read. A state observation that
    # consumed the caller's remaining budget is never usable for admission.
    if deadline is not None:
        upstream_timeout(deadline)
    return payload


def safe_generation(deadline=None):
    """Fresh phase generation only when capacity and participants agree."""
    try:
        status = get_json(STATUS_URL, deadline)
    except TimeoutError:
        return None, "deadline_elapsed"
    except Exception:
        return None, "status_unavailable"
    if not isinstance(status, dict):
        return None, "state_invalid"
    try:
        epoch = get_json(EPOCH_URL, deadline).get("epoch_group_data", {}).get("epoch_index")
    except TimeoutError:
        return None, "deadline_elapsed"
    except Exception:
        return None, "epoch_unavailable"
    try:
        height = get_json(CHAIN_STATUS_URL, deadline).get("result", {}).get("sync_info", {}).get("latest_block_height")
    except TimeoutError:
        return None, "deadline_elapsed"
    except Exception:
        return None, "chain_status_unavailable"
    try:
        params_payload = get_json(CHAIN_PARAMS_URL, deadline)
    except TimeoutError:
        return None, "deadline_elapsed"
    except Exception:
        return None, "params_unavailable"
    if not isinstance(params_payload, dict):
        return None, "state_invalid"
    params_root = params_payload.get("params", params_payload)
    if not isinstance(params_root, dict):
        return None, "state_invalid"
    params = params_root.get("epoch_params", {})
    escrow_params = params_root.get("devshard_escrow_params", {})
    if not isinstance(escrow_params, dict):
        return None, "protocol_approval_invalid"
    approved_versions = escrow_params.get("approved_versions")
    if not valid_approved_versions(approved_versions):
        return None, "protocol_approval_invalid"
    try:
        height = int(height)
        epoch_length = int(params["epoch_length"])
        safe_start = sum(int(params[name]) for name in ("poc_stage_duration", "poc_exchange_duration", "poc_validation_delay", "poc_validation_duration", "set_new_validators_delay")) + 1
    except (KeyError, TypeError, ValueError):
        return None, "state_invalid"
    # A block-derived fence is required in addition to a fresh runtime view:
    # do not open a first dispatch near a known PoC lifecycle boundary.
    if not safe_start <= height % epoch_length <= epoch_length - SAFE_GUARD_BLOCKS:
        return None, "poc_fence"
    if not isinstance(epoch, (str, int)):
        return None, "epoch_invalid"
    capacity = status.get("capacity", {})
    if not isinstance(capacity, dict):
        return None, "capacity_invalid"
    models = capacity.get("models", {})
    if not isinstance(models, dict):
        return None, "capacity_invalid"
    if any(not isinstance(item, dict) for item in models.values()):
        return None, "capacity_invalid"
    weights = [capacity.get("total_weight"), capacity.get("effective_weight")]
    weights.extend((item or {}).get("current_weight", (item or {}).get("total_weight"))
                   for item in models.values())
    try:
        positive = any(float(weight) > 0 for weight in weights if weight is not None)
    except (TypeError, ValueError):
        return None, "capacity_invalid"
    devshards = status.get("devshards", [])
    if not isinstance(devshards, list):
        return None, "state_invalid"
    participants = []
    for item in devshards:
        if not isinstance(item, dict):
            return None, "state_invalid"
        runtime = item.get("runtime")
        if runtime is None:
            runtime = item
        if not isinstance(runtime, dict):
            return None, "state_invalid"
        chain_phase = item.get("chain_phase") or runtime.get("chain_phase")
        if (item.get("active") is True and runtime.get("phase") == "active"
                and not runtime.get("requests_blocked", False)
                and chain_phase == "Inference"):
            version = runtime_protocol_version(item, runtime)
            if version is None:
                return None, "protocol_version_unavailable"
            contract = PROTOCOL_CONTRACTS.get(version)
            if contract is None:
                return None, "protocol_not_configured"
            named = [entry for entry in approved_versions
                     if isinstance(entry, dict) and entry.get("name") == version]
            if (len(named) != 1 or named[0].get("binary") != contract["binary"]
                    or named[0].get("sha256") != contract["sha256"]):
                return None, "protocol_not_approved"
            if item.get("id") is not None:
                participants.append("%s:%s:%s" % (item["id"], version, chain_phase))
    if not positive or not participants:
        return None, "runtime_unavailable"
    # Height proves this observation is fresh and fences the next transition,
    # but it is not itself a phase generation.  Including it would reject every
    # request on chains that produce blocks faster than the polling interval.
    return {
        "generation": "%s:%s" % (epoch, ",".join(sorted(participants))),
        "height": height,
    }, None


class Handler(BaseHTTPRequestHandler):
    server_version = "GonkaAdmission/1"

    def log_message(self, _format, *_args):
        # Prompts, credentials and request URLs are never written to logs.
        pass

    def connected(self):
        """Detect a closed client before opening the sole upstream connection."""
        try:
            data = self.connection.recv(1, socket.MSG_PEEK | socket.MSG_DONTWAIT)
            return data != b""
        except BlockingIOError:
            return True
        except OSError:
            return False

    def response_headers(self, record, admission):
        self.send_header("X-GDC-Admission", admission)
        self.send_header("X-GDC-Admission-ID", record["admission_id"])
        for key, header in (
            ("arrival_height", "X-GDC-Arrival-Height"),
            ("permit_height", "X-GDC-Permit-Height"),
            ("dispatch_height", "X-GDC-Dispatch-Height"),
            ("response_height", "X-GDC-Response-Height"),
        ):
            value = record.get(key)
            if isinstance(value, int) and value >= 0:
                self.send_header(header, str(value))
        if record.get("safe_generation"):
            self.send_header("X-GDC-Safe-Generation", record["safe_generation"])

    def reject(self, status, code, record, admission="pre_dispatch_rejected", deadline=None):
        payload = json.dumps({"error": {"code": code}}).encode()
        record.update({
            "admission": admission,
            "upstream_http_status": 0,
            "error_class": code,
            "response_at_ms": now_ms(),
            "response_height": self.current_height(deadline),
        })
        record_audit(record)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.response_headers(record, admission)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def deadline(self):
        client_deadline = self.headers.get("X-Request-Deadline-Ms")
        if client_deadline is None:
            absolute_ms = now_ms() + int(MAX_WAIT * 1000)
            return absolute_ms, time.monotonic() + MAX_WAIT
        try:
            remaining = int(client_deadline) / 1000.0 - time.time()
        except ValueError:
            return None
        effective_wait = min(MAX_DEADLINE_WAIT, remaining)
        absolute_ms = min(int(client_deadline), now_ms() + int(MAX_DEADLINE_WAIT * 1000))
        return absolute_ms, time.monotonic() + effective_wait

    def current_height(self, deadline=None):
        try:
            height = get_json(CHAIN_STATUS_URL, deadline).get("result", {}).get("sync_info", {}).get("latest_block_height")
            return int(height)
        except Exception:
            return None

    def wait_for_permit(self, stable_generation, deadline):
        """Return a fresh generation while holding the one upstream permit."""
        while time.monotonic() < deadline:
            if not self.connected():
                return None, "client_disconnected"
            remaining = deadline - time.monotonic()
            if not DISPATCH_PERMIT.acquire(timeout=min(POLL, max(0, remaining))):
                continue
            release = True
            try:
                if not self.connected():
                    return None, "client_disconnected"
                if time.monotonic() >= deadline:
                    return None, "admission_deadline_elapsed"
                current, reason = safe_generation(deadline)
                if current is None:
                    return None, reason
                if current["generation"] != stable_generation:
                    return None, "generation_unstable"
                with DISPATCH_LOCK:
                    # Preserve a small bounded map for diagnostics while making
                    # the per-height dispatch decision atomically with permit
                    # ownership. A new block may admit one new request only.
                    for height in list(DISPATCHES_BY_HEIGHT):
                        if height < current["height"] - 2:
                            del DISPATCHES_BY_HEIGHT[height]
                    used = DISPATCHES_BY_HEIGHT.get(current["height"], 0)
                    if used < MAX_DISPATCHES_PER_BLOCK:
                        DISPATCHES_BY_HEIGHT[current["height"]] = used + 1
                        release = False
                        return current, None
            finally:
                if release:
                    DISPATCH_PERMIT.release()
            time.sleep(min(POLL, max(0, deadline - time.monotonic())))
        return None, "admission_deadline_elapsed"

    def do_POST(self):
        record = {
            "admission_id": uuid.uuid4().hex,
            "arrival_at_ms": now_ms(),
            "arrival_height": None,
            "permit_at_ms": None,
            "permit_height": None,
            "dispatch_at_ms": None,
            "dispatch_height": None,
            "response_at_ms": None,
            "response_height": None,
            "safe_generation": None,
            "admission": "pre_dispatch_rejected",
            "upstream_http_status": 0,
            "error_class": "",
        }
        # Parse the deadline before *any* chain-state observation. The
        # request's original absolute budget applies to audit heights as well
        # as admission and the one allowed upstream connection.
        deadline_state = self.deadline()
        if deadline_state is None:
            self.reject(408, "admission_deadline_elapsed", record)
            return
        deadline_ms, deadline = deadline_state
        record["deadline_ms"] = deadline_ms
        if deadline <= time.monotonic():
            self.reject(408, "admission_deadline_elapsed", record, deadline=deadline)
            return
        record["arrival_height"] = self.current_height(deadline)
        if deadline <= time.monotonic():
            self.reject(408, "admission_deadline_elapsed", record, deadline=deadline)
            return
        if not COMPLETION_PATH.fullmatch(self.path.split("?", 1)[0]):
            self.reject(404, "not_found", record, deadline=deadline)
            return
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self.reject(400, "invalid_content_length", record, deadline=deadline)
            return
        if length < 0 or length > MAX_BODY:
            self.reject(413, "request_too_large", record, deadline=deadline)
            return
        body = self.rfile.read(length)
        # An unauthenticated request must not bypass the shared permit or open
        # an upstream connection. The public API contract remains HTTP 401.
        if not self.headers.get("Authorization"):
            self.reject(401, "authentication_required", record, deadline=deadline)
            return
        if deadline <= time.monotonic():
            self.reject(408, "admission_deadline_elapsed", record, deadline=deadline)
            return
        if not SLOTS.acquire(blocking=False):
            self.reject(429, "admission_queue_full", record, deadline=deadline)
            return
        try:
            previous = None
            last_state_reason = None
            rejection = None
            while time.monotonic() < deadline:
                if not self.connected():
                    self.reject(499, "client_disconnected", record, deadline=deadline)
                    return
                current, reason = safe_generation(deadline)
                # The same generation must be observed after the request was
                # queued; both observations are before the sole dispatch site.
                if current is not None and previous is not None and current["generation"] == previous["generation"]:
                    permitted, permit_reason = self.wait_for_permit(current["generation"], deadline)
                    if permitted is not None:
                        record.update({
                            "permit_at_ms": now_ms(),
                            "permit_height": permitted["height"],
                            "safe_generation": permitted["generation"],
                        })
                        self.dispatch_once(body, record, deadline_ms, deadline)
                        return
                    if permit_reason == "client_disconnected":
                        self.reject(499, permit_reason, record, deadline=deadline)
                        return
                    if permit_reason == "admission_deadline_elapsed":
                        self.reject(408, permit_reason, record, deadline=deadline)
                        return
                    rejection = "admission_%s" % permit_reason
                    # The permit sample was not usable. Require two new
                    # matching observations before another dispatch attempt.
                    previous = None
                    time.sleep(min(POLL, max(0, deadline - time.monotonic())))
                    continue
                if current is None:
                    if reason == "deadline_elapsed":
                        if last_state_reason is not None:
                            rejection = "admission_%s" % last_state_reason
                            break
                        # A deadline reached during a later sample must not
                        # erase a concrete unsafe generation already observed
                        # during this request's bounded wait window.
                        if rejection is None:
                            self.reject(408, "admission_deadline_elapsed", record, deadline=deadline)
                            return
                        break
                    last_state_reason = reason
                    rejection = "admission_%s" % reason
                elif previous is not None:
                    rejection = "admission_generation_unstable"
                previous = current
                time.sleep(min(POLL, max(0, deadline - time.monotonic())))
            self.reject(503, rejection or "admission_runtime_unavailable", record, deadline=deadline)
        finally:
            SLOTS.release()

    def dispatch_once(self, body, record, deadline_ms, deadline):
        if deadline <= time.monotonic():
            self.reject(408, "admission_deadline_elapsed", record, deadline=deadline)
            return
        headers = {key: value for key, value in self.headers.items()
                   if key.lower() not in {"host", "connection", "content-length"}}
        headers["Host"] = UPSTREAM.netloc
        headers["Content-Length"] = str(len(body))
        headers["X-Request-Deadline-Ms"] = str(deadline_ms)
        try:
            timeout = upstream_timeout(deadline)
        except TimeoutError:
            self.reject(408, "admission_deadline_elapsed", record, deadline=deadline)
            DISPATCH_PERMIT.release()
            return
        record["dispatch_at_ms"] = now_ms()
        record["dispatch_height"] = self.current_height(deadline)
        if deadline <= time.monotonic():
            self.reject(408, "admission_deadline_elapsed", record, deadline=deadline)
            DISPATCH_PERMIT.release()
            return
        connection = http.client.HTTPConnection(UPSTREAM.hostname, UPSTREAM.port or 80, timeout=timeout)
        try:
            # No code path retries after this connection is requested.
            connection.request("POST", self.path, body=body, headers=headers)
            response = connection.getresponse()
            payload = response.read()
            record.update({
                "admission": "dispatched_once",
                "upstream_http_status": response.status,
                "error_class": "" if 200 <= response.status < 300 else "upstream_http_%s" % response.status,
                "response_at_ms": now_ms(),
                "response_height": self.current_height(deadline),
            })
            record_audit(record)
            self.send_response(response.status, response.reason)
            self.response_headers(record, "dispatched_once")
            # Upstream headers are not a trusted response-header source.  The
            # proxy owns framing and exposes only an allowlisted media type.
            self.send_header("Content-Type", safe_upstream_content_type(
                response.getheader("Content-Type", "")))
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            try:
                self.wfile.write(payload)
            except (BrokenPipeError, ConnectionResetError):
                # The upstream response is already recorded. A downstream client
                # disconnect must not become a second dispatch failure.
                return
        except Exception as error:
            status, error_class = dispatch_failure(error)
            self.reject(status, error_class, record, "dispatch_attempt_failed", deadline)
        finally:
            connection.close()
            DISPATCH_PERMIT.release()


if __name__ == "__main__":
    try:
        PROTOCOL_CONTRACTS = load_protocol_contracts(
            env("GDC_GATEWAY_ADMISSION_PROTOCOLS_JSON", ""))
    except ValueError as error:
        raise SystemExit(str(error)) from error
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
