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
            approved = root["devshard_escrow_params"]["approved_versions"]
        except (KeyError, TypeError, ValueError):
            raise ChainError("params_invalid", reply.seq)
        if length <= 0 or not approved:
            raise ChainError("params_invalid", reply.seq)
        return {"epoch_length": length, "safe_start": safe_start, "seq": reply.seq}

    def epoch_index(self):
        reply = self._get(self.api + "/current_epoch_group_data", "epoch_unreachable")
        try:
            return int(reply.json["epoch_group_data"]["epoch_index"]), reply.seq
        except (KeyError, TypeError, ValueError):
            raise ChainError("epoch_invalid", reply.seq)

    def confirmation_phases(self):
        reply = self._get(self.api + "/active_confirmation_poc_event", "confirmation_unreachable")
        return sorted(set(_strings_under(reply.json, "phase"))), reply.seq


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


def in_fence(height, params):
    """The admission proxy's own rule for opening a dispatch."""
    length = params["epoch_length"]
    return params["safe_start"] <= height % length <= length - FENCE_GUARD_BLOCKS


def send_window(params, preset):
    window = preset["send_window"]
    low = params["safe_start"] + int(window["from_offset"])
    high = params["epoch_length"] - int(window["stop_before_end"])
    return low, high
