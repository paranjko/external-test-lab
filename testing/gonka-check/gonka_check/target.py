"""Preset, API key, local directories and the target guard."""

import hashlib
import json
import os
import posixpath
import re
import stat
from urllib.parse import unquote, urlsplit


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PRESET_DIR = os.path.join(ROOT, "presets")
PROFILES = ("smoke", "chain")
PUBLIC_TARGETS = {
    "https://api.gonka-dev.net": "https://gonka-dev.net/status/gateway-health",
}
# DevShard gateways reached directly under a path of the public API: no admission proxy, no health receipt.
PUBLIC_GATEWAY_PATHS = {"https://api.gonka-dev.net": ("/a", "/b")}
GATEWAY_PATH = re.compile(r"^(/[a-z0-9][a-z0-9-]*)?$")
# Gateway admin paths as devshardctl sees them, also one segment deep (/a, /b) and under /devshard/<id>.
ADMIN_PATH = re.compile(r"^(/[^/]+)?(/devshard/[^/]+)?(/v1/(admin|debug|finalize|state)|/debug/pprof)(/|$)")
LOOPBACK = {"127.0.0.1", "localhost", "::1"}
PUBLIC_NODE_RPC = re.compile(r"^https://node[0-9]+\.gonka-dev\.net/chain-rpc$")
REQUIRED = (
    "name", "base_url", "model", "health_url", "chain_rpc", "chain_api",
    "send_window", "min_blocks_between_sends", "deadline_s", "socket_timeout_s",
    "chain_poll_s", "health_poll_s", "health_max_age_s", "budget",
    "profiles_allowed", "forbid_paths",
)


class TargetRefused(Exception):
    pass


def config_dir():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "gonka-check")


def data_dir():
    base = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    return os.path.join(base, "gonka-check")


def load_preset(name_or_path):
    path = name_or_path
    if os.sep not in name_or_path and not name_or_path.endswith(".json"):
        path = os.path.join(PRESET_DIR, name_or_path + ".json")
    try:
        with open(path, encoding="utf-8") as handle:
            preset = json.load(handle)
    except (OSError, ValueError) as error:
        raise TargetRefused("preset %s is unreadable: %s" % (name_or_path, error))
    missing = [key for key in REQUIRED if key not in preset]
    if missing:
        raise TargetRefused("preset %s lacks %s" % (name_or_path, ", ".join(missing)))
    check_target(preset)
    return preset


def is_loopback(url):
    parts = urlsplit(url)
    return parts.scheme == "http" and parts.hostname in LOOPBACK


def gateway_path(preset):
    return preset.get("gateway_path") or ""


def gateway_url(preset):
    return preset["base_url"].rstrip("/") + gateway_path(preset)


def is_direct(preset):
    """A gateway without the admission proxy: no health receipt, no GDC headers, no fence."""
    return bool(gateway_path(preset))


def check_target(preset):
    """Refuse any target other than the public DevNet API or a local fake."""
    base = preset["base_url"].rstrip("/")
    path = gateway_path(preset)
    if not GATEWAY_PATH.fullmatch(path):
        raise TargetRefused("gateway path %r is malformed" % path)
    if (preset["health_url"] is None) != bool(path):
        raise TargetRefused("a gateway path goes without a health receipt, the admission point with one")
    if is_loopback(base):
        urls = [url for url in (preset["health_url"], preset["chain_rpc"], preset["chain_api"]) if url]
        if not all(is_loopback(url) for url in urls):
            raise TargetRefused("a loopback target must keep every URL on loopback")
    elif path:
        if path not in PUBLIC_GATEWAY_PATHS.get(base, ()):
            raise TargetRefused("gateway %s%s is not an allowed DevNet gateway" % (base, path))
    elif PUBLIC_TARGETS.get(base) != preset["health_url"]:
        raise TargetRefused("target %s is not an allowed public gateway" % base)
    for key in ("chain_rpc", "chain_api"):
        if not preset[key].startswith(base + "/"):
            raise TargetRefused("%s must live under %s" % (key, base))
    for url in preset.get("node_rpcs", []):
        if not (is_loopback(url) if is_loopback(base) else PUBLIC_NODE_RPC.fullmatch(url)):
            raise TargetRefused("node RPC %s is not an allowed DevNet node" % url)
    if not is_loopback(base):
        # The public chain RPC is rate limited; refuse presets that would poll it harder.
        if float(preset["chain_poll_s"]) < 2 or float(preset.get("watch_interval_s", 10)) < 5:
            raise TargetRefused("a public target needs chain_poll_s >= 2 and watch_interval_s >= 5")
    for profile in preset["profiles_allowed"]:
        if profile not in PROFILES:
            raise TargetRefused("profile %s is not implemented" % profile)


def check_profile(preset, profile):
    if profile not in preset["profiles_allowed"]:
        raise TargetRefused("profile %s is not allowed for %s" % (profile, preset["name"]))


def check_url(preset, url):
    parts = urlsplit(url)
    path = posixpath.normpath("/" + unquote(parts.path).lstrip("/"))
    for prefix in preset["forbid_paths"]:
        if path.startswith(prefix):
            raise TargetRefused("path %s is forbidden" % parts.path)
    if ADMIN_PATH.match(path):
        raise TargetRefused("path %s is a gateway admin path" % parts.path)
    origin = "%s://%s" % (parts.scheme, parts.netloc)
    allowed = {preset["base_url"].rstrip("/")}
    if preset["health_url"]:
        allowed.add("%s://%s" % urlsplit(preset["health_url"])[:2])
    if origin in allowed:
        return
    # A node origin is allowed only under its own chain RPC path.
    for node in preset.get("node_rpcs", []):
        node_parts = urlsplit(node)
        if origin == "%s://%s" % node_parts[:2] and path.startswith(node_parts.path.rstrip("/") + "/"):
            return
    raise TargetRefused("origin %s is outside the preset" % origin)


def key_path(preset, override=None):
    return override or os.path.join(config_dir(), preset["name"] + ".key")


def load_key(path):
    """Return (key, problem); the key never leaves this process except in POST."""
    try:
        info = os.stat(path)
    except FileNotFoundError:
        return None, "key_missing"
    if not stat.S_ISREG(info.st_mode):
        return None, "key_not_a_file"
    if info.st_mode & 0o077:
        return None, "key_permissions"
    with open(path, encoding="utf-8") as handle:
        key = handle.read().strip()
    if not key or any(ch.isspace() for ch in key):
        return None, "key_malformed"
    return key, None


def key_fingerprint(key):
    return hashlib.sha256(key.encode()).hexdigest()[:12] if key else None
