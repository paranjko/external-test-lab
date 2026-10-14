"""Port of inference-chain/x/inference/calculations/slots.go: weighted slot draws with replacement."""

import hashlib

SLOTS_GO = "inference-chain/x/inference/calculations/slots.go"
SLOTS_GO_COMMIT = "4d687ed6782bcea3931d2d9135bf322f84e190ab"
SLOTS_GO_SHA256 = "fe00d98a9d7acfe17e3dd5df5c324029685ee65c748b9c94c2419c79f58cde83"


def sorted_entries(weights):
    """PrepareSortedEntries: addresses in byte order, non-positive weights dropped."""
    entries = [(address, int(weight)) for address, weight in sorted(weights.items(), key=lambda kv: kv[0].encode())
               if int(weight) > 0]
    return entries, sum(weight for _address, weight in entries)


def slot_value(app_hash, owner, model, index, total):
    digest = hashlib.sha256(("%s%s%s%d" % (app_hash, owner, model, index)).encode()).digest()
    return int.from_bytes(digest[:8], "big") % total


def select_slots(app_hash, owner, model, entries, total, count):
    """GetSlotsFromSorted: one independent draw per slot, owner by cumulative weight."""
    if count <= 0 or total <= 0:
        return []
    draws = sorted((slot_value(app_hash, owner, model, index, total), index) for index in range(count))
    slots = [None] * count
    cumulative, cursor = 0, 0
    for address, weight in entries:
        cumulative += weight
        while cursor < count and draws[cursor][0] < cumulative:
            slots[draws[cursor][1]] = address
            cursor += 1
    return slots


def escrow_owner(escrow_id):
    return "devshard_escrow:%d" % escrow_id


def synthetic_app_hash(index):
    """Seed of simulated escrow `index`: the same for every group size, so runs for different G are paired."""
    return hashlib.sha256(("block-%d" % index).encode()).hexdigest()
