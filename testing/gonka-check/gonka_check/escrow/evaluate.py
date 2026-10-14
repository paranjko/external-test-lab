"""Offline evaluation of a snapshot: weight and escrow checks, replay of real escrows, simulation and its checks."""

import hashlib
import math
from collections import Counter

from ..checks import MAPS, verdict
from .slots import SLOTS_GO_SHA256, escrow_owner, select_slots, sorted_entries, synthetic_app_hash
from .snapshot import escrows_of

ESCROW_CHECKS = ("weights", "escrows", "slots_replay", "slots_source", "slot_share", "inclusion")
MAPS.update({check: [] for check in ESCROW_CHECKS})
# Wide on purpose: a miss means a bug in the code, not bad luck of a fixed seed.
BAND_SIGMAS = 5


def drawable(snap):
    """Models with at least one positive weight; the chain refuses escrows for the others."""
    return [model for model, data in snap["models"].items() if sorted_entries(data["weights"])[1] > 0]


def check_weights(snap):
    if not snap["models"]:
        return verdict("weights", "INCONCLUSIVE", "the epoch group lists no models")
    wrong = ["%s: sum %d, total_weight %d" % (model, sum(data["weights"].values()), data["total_weight"])
             for model, data in snap["models"].items() if sum(data["weights"].values()) != data["total_weight"]]
    if wrong:
        return verdict("weights", "FAIL", "; ".join(wrong))
    if not drawable(snap):
        return verdict("weights", "INCONCLUSIVE", "no model of epoch %d has a member with a positive weight"
                       % snap["epoch"])
    if snap.get("epoch_end") is None and snap.get("stopped"):
        return verdict("weights", "INCONCLUSIVE", "snapshot stopped before the end check: %s" % snap["stopped"])
    if snap.get("epoch_end", snap["epoch"]) != snap["epoch"]:
        return verdict("weights", "INCONCLUSIVE", "effective epoch changed from %d to %s during the snapshot; "
                       "take it again" % (snap["epoch"], snap["epoch_end"]))
    members = ", ".join("%s %d" % (model, len(data["weights"])) for model, data in snap["models"].items())
    notes = ["%d zero weights skipped as the chain does" % sum(data.get("dropped_non_positive", 0)
                                                              for data in snap["models"].values())]
    notes += ["%s has no member with a positive weight" % model
              for model in snap["models"] if model not in drawable(snap)]
    notes = [note for note in notes if not note.startswith("0 ")]
    return verdict("weights", "PASS", "epoch %d, weights sum to total_weight in every model (%s)%s"
                   % (snap["epoch"], members, "".join("; " + note for note in notes)))


def check_escrows(snap):
    """Every id of the epoch's range was read: ids are consecutive, so a gap means a read problem."""
    read = sum(len(items) for items in snap["escrows"].values())
    problems = []
    if snap.get("stopped"):
        problems.append("stopped at id %s: %s" % ((snap.get("escrow_range") or ["?", "?"])[1], snap["stopped"]))
    if snap.get("escrows_failed"):
        problems.append("%d reads failed, first ids %s" % (len(snap["escrows_failed"]), snap["escrows_failed"][:5]))
    if snap.get("escrows_missing") and not snap.get("escrow_ids_given"):
        problems.append("%d ids of the indexed range not found, first %s" % (
            len(snap["escrows_missing"]), snap["escrows_missing"][:5]))
    indexed, span = snap.get("escrows_indexed"), snap.get("escrow_range")
    if indexed is not None and span and not snap.get("stopped") and indexed < span[1] - span[0] + 1:
        problems.append("the tx index lists %d escrows for %d ids" % (indexed, span[1] - span[0] + 1))
    if problems:
        return verdict("escrows", "INCONCLUSIVE", "; ".join(problems))
    if not read:
        return verdict("escrows", "INCONCLUSIVE", "no real escrow of epoch %d was read" % snap["epoch"])
    return verdict("escrows", "PASS", "%d escrows of epoch %d read, ids %d..%d" % (
        read, snap["epoch"], snap["escrow_range"][0], snap["escrow_range"][1]))


def replay(snap, min_escrows):
    counts, wrong = {}, []
    for model, data in snap["models"].items():
        entries, total = sorted_entries(data["weights"])
        counts[model] = 0
        for escrow_id, app_hash, slots in escrows_of(snap, model):
            counts[model] += 1
            if select_slots(app_hash, escrow_owner(escrow_id), model, entries, total, len(slots)) != slots:
                wrong.append(escrow_id)
    done = sum(counts.values())
    per_model = ", ".join("%s %d" % item for item in counts.items())
    if wrong:
        return verdict("slots_replay", "FAIL", "%d of %d real escrows differ from the port, first ids %s"
                       % (len(wrong), done, ", ".join(map(str, wrong[:10])))), counts
    if done < min_escrows:
        return verdict("slots_replay", "INCONCLUSIVE", "only %d real escrows (%s), need %d"
                       % (done, per_model, min_escrows)), counts
    return verdict("slots_replay", "PASS", "all %d real escrows match slot by slot (%s)" % (done, per_model)), counts


def check_source(path):
    with open(path, "rb") as handle:
        digest = hashlib.sha256(handle.read()).hexdigest()
    if digest == SLOTS_GO_SHA256:
        return verdict("slots_source", "PASS", "slots.go sha256 %s… equals the ported file" % digest[:12])
    return verdict("slots_source", "FAIL", "slots.go sha256 %s… differs from the ported %s…"
                   % (digest[:12], SLOTS_GO_SHA256[:12]))


def simulate(snap, groups, runs):
    """One row per model, group size and member with a positive weight."""
    rows = []
    for model, data in snap["models"].items():
        entries, total = sorted_entries(data["weights"])
        if not total:
            continue
        for size in groups:
            slots, included, peak = Counter(), Counter(), Counter()
            for index in range(1, runs + 1):
                drawn = Counter(select_slots(synthetic_app_hash(index), escrow_owner(index), model, entries, total,
                                             size))
                for address, count in drawn.items():
                    slots[address] += count
                    included[address] += 1
                    peak[address] = max(peak[address], count)
            for address, weight in entries:
                rows.append(_row(model, size, runs, address, weight, weight / total,
                                 slots[address], included[address], peak[address]))
    return rows


def _row(model, size, runs, address, weight, share, slots, included, peak):
    reach = 1 - (1 - share) ** size
    when = slots / included if included else None
    return {
        "model": model, "G": size, "address": address, "weight": weight, "weight_share": share,
        "slots": slots, "slots_expected": runs * size * share,
        "slots_sd": math.sqrt(runs * size * share * (1 - share)),
        "slot_share_ratio": slots / (runs * size) / share,
        "included": included, "included_expected": runs * reach,
        "included_sd": math.sqrt(runs * reach * (1 - reach)),
        "slots_when_included": when,
        "work_share_when_included": when / size if when else None,
        "overload_when_included": when / size / share if when else None,
        "max_slots_in_one_escrow": peak,
    }


def _in_band(observed, expected, sd):
    return abs(observed - expected) <= BAND_SIGMAS * sd + 1


def check_simulation(rows, runs, replay_verdict):
    if replay_verdict["verdict"] != "PASS":
        reason = "not evaluated: slots_replay is %s" % replay_verdict["verdict"]
        return [verdict("slot_share", "INCONCLUSIVE", reason), verdict("inclusion", "INCONCLUSIVE", reason)]
    totals = Counter()
    for row in rows:
        totals[(row["model"], row["G"])] += row["slots"]
    lost = ["%s G=%d: %d slots" % (model, size, count) for (model, size), count in totals.items()
            if count != runs * size]
    share_out = [row for row in rows if not _in_band(row["slots"], row["slots_expected"], row["slots_sd"])]
    reach_out = [row for row in rows if not _in_band(row["included"], row["included_expected"], row["included_sd"])]
    band = "within %d sigma + 1 of the formula" % BAND_SIGMAS

    def outliers(found):
        return "; ".join("%s …%s G=%d" % (row["model"], row["address"][-6:], row["G"]) for row in found[:5])
    if lost:
        share = verdict("slot_share", "FAIL", "slot totals wrong: " + "; ".join(lost))
    elif share_out:
        share = verdict("slot_share", "FAIL", "%d rows outside the band: %s" % (len(share_out), outliers(share_out)))
    else:
        share = verdict("slot_share", "PASS", "every member's slots %s runs x G x share; %d rows" % (band, len(rows)))
    if reach_out:
        reach = verdict("inclusion", "FAIL", "%d rows outside the band: %s" % (len(reach_out), outliers(reach_out)))
    else:
        reach = verdict("inclusion", "PASS", "every member's escrow count %s 1-(1-p)^G" % band)
    return [share, reach]


def real_inclusion(snap, model):
    """Real escrows of the snapshot: how many include each member, against the formula at their group size."""
    entries, total = sorted_entries(snap["models"][model]["weights"])
    escrows = list(escrows_of(snap, model))
    counts = Counter(address for _id, _hash, slots in escrows for address in set(slots))
    sizes = Counter(len(slots) for _id, _hash, slots in escrows)
    size = sizes.most_common(1)[0][0] if sizes else snap["group_size"]
    return size, len(escrows), [{"address": address, "weight_share": weight / total, "included": counts[address],
                                 "expected": len(escrows) * (1 - (1 - weight / total) ** size)}
                                for address, weight in entries]


def model_mix(counts):
    """Share of each model among the real escrows of the epoch; equal shares when none were read."""
    total = sum(counts.values())
    if not total:
        return {model: 1 / len(counts) for model in counts}, False
    return {model: count / total for model, count in counts.items()}, True


def by_address(snap, rows, runs, mix):
    """Share of all slots of the epoch per address, summed over models with the escrow mix."""
    excluded = {item["address"] for item in snap["excluded"]}
    members = set(snap["root"]["members"])
    for data in snap["models"].values():
        members.update(data["weights"])
    out = []
    for size in sorted({row["G"] for row in rows}):
        found = {}
        for row in rows:
            if row["G"] != size:
                continue
            entry = found.setdefault(row["address"], {"share": 0.0, "expected": 0.0, "models": []})
            entry["share"] += mix[row["model"]] * row["slots"] / (runs * size)
            entry["expected"] += mix[row["model"]] * row["weight_share"]
            entry["models"].append(row["model"])
        for address in sorted(members, key=str.encode):
            entry = found.get(address, {"share": 0.0, "expected": 0.0, "models": []})
            out.append({"G": size, "address": address, "models": entry["models"], "share_of_slots": entry["share"],
                        "expected_share": entry["expected"], "excluded": address in excluded})
    return out


def lightest(rows, model, size):
    """The lightest quarter of a model's members, lightest first."""
    found = sorted((row for row in rows if row["model"] == model and row["G"] == size),
                   key=lambda row: (row["weight"], row["address"].encode()))
    return found[:math.ceil(len(found) / 4)]


def correlations(rows, model, size):
    """Pearson of weight share with slots and with escrows that include the member, and Spearman of the latter."""
    found = [row for row in rows if row["model"] == model and row["G"] == size]
    xs = [row["weight_share"] for row in found]
    included = [row["included"] for row in found]
    return (_pearson(xs, [row["slots"] for row in found]), _pearson(xs, included),
            _pearson(_ranks(xs), _ranks(included)))


def _pearson(xs, ys):
    n = len(xs)
    mx, my = sum(xs) / n, sum(ys) / n
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    sxx, syy = sum((x - mx) ** 2 for x in xs), sum((y - my) ** 2 for y in ys)
    return sxy / math.sqrt(sxx * syy) if sxx and syy else None


def _ranks(values):
    order = sorted(range(len(values)), key=values.__getitem__)
    ranks = [0.0] * len(values)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and values[order[j + 1]] == values[order[i]]:
            j += 1
        for k in range(i, j + 1):
            ranks[order[k]] = (i + j) / 2
        i = j + 1
    return ranks


def evaluate(snap, groups, runs, min_escrows, slots_go=None):
    verdicts = [check_weights(snap), check_escrows(snap)]
    replay_verdict, counts = replay(snap, min_escrows)
    verdicts.append(replay_verdict)
    if slots_go:
        verdicts.append(check_source(slots_go))
    rows = simulate(snap, groups, runs)
    verdicts += check_simulation(rows, runs, replay_verdict)
    mix, from_escrows = model_mix({model: counts[model] for model in drawable(snap)})
    return {"verdicts": verdicts, "rows": rows, "groups": list(groups), "runs": runs, "escrows_per_model": counts,
            "mix": mix, "mix_from_escrows": from_escrows, "addresses": by_address(snap, rows, runs, mix)}
