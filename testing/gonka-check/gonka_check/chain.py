"""Chain height, epoch parameters and the admission fence."""

import time


BLOCKING_CONFIRMATION_PHASES = {
    "CONFIRMATION_POC_GRACE_PERIOD",
    "CONFIRMATION_POC_GENERATION",
    "CONFIRMATION_POC_VALIDATION",
}
SAFE_START_PARAMS = (
    "poc_stage_duration", "poc_exchange_duration", "poc_validation_delay",
    "poc_validation_duration", "set_new_validators_delay",
)
FENCE_GUARD_BLOCKS = 10


class ChainError(Exception):
    def __init__(self, reason, seq=None):
        super().__init__(reason)
        self.reason = reason
        self.seq = seq


class Chain:
    def __init__(self, client, preset):
        self.client = client
        self.rpc = preset["chain_rpc"].rstrip("/")
        self.api = preset["chain_api"].rstrip("/")
        self.poll = float(preset["chain_poll_s"])
        self._last_height_at = None

    def _get(self, url, reason):
        reply = self.client.get(url)
        if not reply.ok or not isinstance(reply.json, dict):
            raise ChainError("%s (%s)" % (reason, reply.status or reply.transport_error), reply.seq)
        return reply

    def height(self):
        # The public chain RPC is rate limited; keep polls a few seconds apart.
        if self._last_height_at is not None:
            pause = self.poll - (time.monotonic() - self._last_height_at)
            if pause > 0:
                time.sleep(pause)
        self._last_height_at = time.monotonic()
        reply = self._get(self.rpc + "/status", "chain_unreachable")
        try:
            return int(reply.json["result"]["sync_info"]["latest_block_height"]), reply.seq
        except (KeyError, TypeError, ValueError):
            raise ChainError("chain_status_invalid", reply.seq)

    def epoch_params(self):
        reply = self._get(self.api + "/params", "params_unreachable")
        root = reply.json.get("params", reply.json)
        try:
            params = root["epoch_params"]
            length = int(params["epoch_length"])
            safe_start = sum(int(params[name]) for name in SAFE_START_PARAMS) + 1
            approved = root["devshard_escrow_params"].get("approved_versions") or self.approved_versions()
        except (KeyError, TypeError, ValueError, AttributeError):
            raise ChainError("params_invalid", reply.seq)
        if length <= 0 or not approved:
            raise ChainError("params_invalid", reply.seq)
        return {"epoch_length": length, "safe_start": safe_start, "seq": reply.seq}

    def approved_versions(self):
        # Since chain v0.2.16 the approved DevShard versions have their own store, outside the params.
        reply = self.client.get(self.api + "/devshard_approved_versions")
        return reply.json.get("versions") if reply.ok and isinstance(reply.json, dict) else []

    def epoch_index(self):
        reply = self._get(self.api + "/current_epoch_group_data", "epoch_unreachable")
        try:
            return int(reply.json["epoch_group_data"]["epoch_index"]), reply.seq
        except (KeyError, TypeError, ValueError):
            raise ChainError("epoch_invalid", reply.seq)

    def epoch_cycle(self):
        """Index and first block of the running PoC cycle."""
        reply = self._get(self.api + "/epoch_info", "epoch_unreachable")
        try:
            latest = reply.json["latest_epoch"]
            return int(latest["index"]), int(latest["poc_start_block_height"]), reply.seq
        except (KeyError, TypeError, ValueError):
            raise ChainError("epoch_invalid", reply.seq)

    def epoch_start(self):
        """First block of the running PoC cycle."""
        _index, start, seq = self.epoch_cycle()
        return start, seq

    def epoch_group(self):
        reply = self._get(self.api + "/current_epoch_group_data", "epoch_unreachable")
        try:
            data = reply.json["epoch_group_data"]
            return {"epoch": int(data["epoch_index"]), "start": int(data["poc_start_block_height"])}
        except (KeyError, TypeError, ValueError):
            raise ChainError("epoch_invalid", reply.seq)

    def confirmation_phases(self):
        reply = self._get(self.api + "/active_confirmation_poc_event", "confirmation_unreachable")
        return sorted(set(_strings_under(reply.json, "phase"))), reply.seq

    def confirmation_event(self):
        reply = self._get(self.api + "/active_confirmation_poc_event", "confirmation_unreachable")
        event = reply.json.get("event") if isinstance(reply.json.get("event"), dict) else {}
        found = {"active": reply.json.get("is_active") is True, "phase": event.get("phase")}
        for key in ("epoch_index", "trigger_height", "generation_start_height"):
            try:
                found[key] = int(event[key])
            except (KeyError, TypeError, ValueError):
                found[key] = None
        return found

    def node_height(self, rpc):
        """(height, catching_up) of one public node, or ChainError."""
        reply = self._get(rpc.rstrip("/") + "/status", "node_unreachable")
        try:
            info = reply.json["result"]["sync_info"]
            return int(info["latest_block_height"]), info.get("catching_up") is True
        except (KeyError, TypeError, ValueError):
            raise ChainError("node_status_invalid", reply.seq)


def _strings_under(node, key):
    if isinstance(node, dict):
        for name, value in node.items():
            if name == key and isinstance(value, str):
                yield value
            else:
                yield from _strings_under(value, key)
    elif isinstance(node, list):
        for item in node:
            yield from _strings_under(item, key)


def epoch_offset(chain, height):
    """Blocks since the PoC start, as the admission proxy counts them; the cycle stops being
    height-aligned once epoch_length changes. Outside the cycle the offset stays outside
    0..length-1, so no send window matches it."""
    start, _ = chain.epoch_start()
    return height - start


def in_fence(offset, params):
    """The admission proxy's own rule for opening a dispatch, by blocks since the PoC start."""
    return params["safe_start"] <= offset <= params["epoch_length"] - FENCE_GUARD_BLOCKS


def send_window(params, preset):
    window = preset["send_window"]
    low = params["safe_start"] + int(window["from_offset"])
    high = params["epoch_length"] - int(window["stop_before_end"])
    return low, high
