"""HTTP without redirects; the API key travels only on completion POSTs."""

import http.client
import json
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit

from . import __version__
from .target import check_url, gateway_url


GDC_HEADERS = {
    "X-GDC-Admission": "admission",
    "X-GDC-Admission-ID": "admission_id",
    "X-GDC-Arrival-Height": "arrival_height",
    "X-GDC-Permit-Height": "permit_height",
    "X-GDC-Dispatch-Height": "dispatch_height",
    "X-GDC-Response-Height": "response_height",
    "X-GDC-Safe-Generation": "safe_generation",
}
KEEP_BODY_BYTES = 32768


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


class Reply:
    def __init__(self, method, url):
        self.method = method
        self.url = url
        self.status = None
        self.gdc = {}
        self.json = None
        self.body_bytes = 0
        self.error_code = None
        self.error_message = None
        self.transport_error = None
        self.elapsed_ms = None
        self.seq = None
        self.send_seq = None

    @property
    def ok(self):
        return self.status is not None and 200 <= self.status < 300

    def to_record(self):
        return {
            "method": self.method,
            "path": urlsplit(self.url).path,
            "status": self.status,
            "gdc": self.gdc,
            "error_code": self.error_code,
            "error_message": self.error_message,
            "transport_error": self.transport_error,
            "elapsed_ms": self.elapsed_ms,
            "body": self.json if self.body_bytes <= KEEP_BODY_BYTES else None,
        }


def _parse_gdc(headers):
    found = {}
    for header, name in GDC_HEADERS.items():
        value = headers.get(header) if headers is not None else None
        if value is None:
            continue
        if name.endswith("_height"):
            try:
                value = int(value)
            except ValueError:
                pass
        found[name] = value
    return found


def _parse_error(payload):
    if not isinstance(payload, dict) or "error" not in payload:
        return None, None
    error = payload["error"]
    if isinstance(error, dict):
        code, message = error.get("code"), error.get("message")
    else:
        code, message = None, error
    if message is not None:
        message = str(message)[:300]
    return (str(code) if code is not None else None), message


class Client:
    def __init__(self, preset, recorder):
        self.preset = preset
        self.recorder = recorder
        self.posts = 0

    def get(self, url, timeout=15):
        reply = self._send("GET", url, None, None, timeout, None)
        if self.recorder is not None:
            reply.seq = self.recorder.write("http", **reply.to_record())
        return reply

    def post_completion(self, payload, key, check):
        url = gateway_url(self.preset) + "/v1/chat/completions"
        body = json.dumps(payload).encode()
        deadline_ms = int((time.time() + self.preset["deadline_s"]) * 1000)
        send_seq = self.recorder.write(
            "send", check=check, path=urlsplit(url).path, deadline_ms=deadline_ms, payload=payload)
        self.posts += 1
        reply = self._send("POST", url, body, key, self.preset["socket_timeout_s"], deadline_ms)
        reply.seq = self.recorder.write("reply", check=check, send_seq=send_seq, **reply.to_record())
        reply.send_seq = send_seq
        return reply

    def _send(self, method, url, body, key, timeout, deadline_ms):
        check_url(self.preset, url)
        if key is not None and method != "POST":
            raise ValueError("the API key is sent only with a completion POST")
        request = urllib.request.Request(url, data=body, method=method)
        request.add_header("User-Agent", "gonka-check/%s" % __version__)
        request.add_header("Accept", "application/json")
        if body is not None:
            request.add_header("Content-Type", "application/json")
        if deadline_ms is not None:
            request.add_header("X-Request-Deadline-Ms", str(deadline_ms))
        if key is not None:
            request.add_unredirected_header("Authorization", "Bearer " + key)
        reply = Reply(method, url)
        started = time.monotonic()
        headers, data = None, b""
        try:
            with _OPENER.open(request, timeout=timeout) as response:
                reply.status, headers, data = response.status, response.headers, response.read()
        except urllib.error.HTTPError as error:
            reply.status, headers = error.code, error.headers
            try:
                data = error.read()
            except (OSError, http.client.HTTPException):
                data = b""
        except (OSError, http.client.HTTPException) as error:
            reason = getattr(error, "reason", error)
            reply.transport_error = "%s: %s" % (type(reason).__name__, str(reason)[:200])
        reply.elapsed_ms = int((time.monotonic() - started) * 1000)
        reply.gdc = _parse_gdc(headers)
        reply.body_bytes = len(data)
        if data:
            try:
                reply.json = json.loads(data)
            except ValueError:
                reply.json = None
        reply.error_code, reply.error_message = _parse_error(reply.json)
        return reply
