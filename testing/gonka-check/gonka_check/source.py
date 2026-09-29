"""Read-only chain source: GET under /chain-api/ and /chain-rpc/ of one fixed origin, paced, no API key."""

import time
from urllib.parse import urlsplit

from .target import TargetRefused, is_loopback
from .transport import Client

# A public source is paced below the rate at which it starts to answer 503.
SOURCES = {
    "mainnet": {"origin": "https://node3.gonka.ai", "interval_s": 1.0},
    "devnet": {"origin": "https://api.gonka-dev.net", "interval_s": 2.0},
}
PATHS = ("/chain-api/", "/chain-rpc/")
RETRY_STATUS = {429, 502, 503, 504}
BACKOFF_S = (2, 4, 8, 16)


class SourceError(Exception):
    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


class RequestCapReached(SourceError):
    pass


def resolve(source):
    """Return (name, origin, interval) for a source name, or a loopback URL used by tests."""
    if source in SOURCES:
        return source, SOURCES[source]["origin"], SOURCES[source]["interval_s"]
    parts = urlsplit(source)
    if is_loopback(source) and parts.path in ("", "/") and not parts.username and not parts.query:
        return "loopback", "%s://%s" % (parts.scheme, parts.netloc), 0.0
    raise TargetRefused("source %s is not one of %s or a loopback URL" % (source, ", ".join(sorted(SOURCES))))


def _detail(reply):
    """The node's own words for a failure: JSON-RPC error.data or a REST message."""
    body = reply.json if isinstance(reply.json, dict) else {}
    error = body.get("error")
    text = error.get("data") or error.get("message") if isinstance(error, dict) else error or body.get("message")
    return (": %s" % str(text)[:200]) if text else ""


class SourceClient:
    def __init__(self, origin, interval_s, recorder, max_requests, backoff_s=None):
        self.origin = origin
        self.interval_s = interval_s
        self.max_requests = max_requests
        self.backoff_s = BACKOFF_S if backoff_s is None else backoff_s
        self.requests = 0
        self.retries = 0
        self._last = None
        # The transport's own origin check stays in force; forbid_paths is empty because PATHS is narrower.
        self._client = Client({"base_url": origin, "health_url": origin + "/", "forbid_paths": [], "node_rpcs": []},
                              recorder)

    def url(self, path):
        url = self.origin + path
        parts = urlsplit(url)
        if "%s://%s" % (parts.scheme, parts.netloc) != self.origin or parts.username or parts.password:
            raise TargetRefused("url %s leaves %s" % (url, self.origin))
        if not parts.path.startswith(PATHS) or ".." in parts.path.split("/") or "%" in parts.path:
            raise TargetRefused("path %s is outside %s" % (parts.path, " and ".join(PATHS)))
        return url

    def get(self, path):
        """GET one document; retry busy answers with backoff; return the Reply (any final status)."""
        url = self.url(path)
        attempt = 0
        while True:
            if self.requests >= self.max_requests:
                raise RequestCapReached("request cap %d reached" % self.max_requests)
            if self._last is not None:
                pause = self.interval_s - (time.monotonic() - self._last)
                if pause > 0:
                    time.sleep(pause)
            self._last = time.monotonic()
            self.requests += 1
            reply = self._client.get(url, timeout=20)
            error = reply.transport_error or ""
            busy = reply.status in RETRY_STATUS or (error and "CERTIFICATE_VERIFY_FAILED" not in error)
            if not busy or attempt == len(self.backoff_s):
                return reply
            self.retries += 1
            time.sleep(self.backoff_s[attempt])
            attempt += 1

    def get_json(self, path, what):
        reply = self.get(path)
        if not reply.ok or not isinstance(reply.json, dict):
            raise SourceError("%s: HTTP %s%s" % (what, reply.status or reply.transport_error, _detail(reply)))
        return reply.json
