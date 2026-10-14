"""report.md, one SVG chart per model and CSV files; no timestamps, so a rerun gives the same bytes."""

import csv
import io
import math
import os
import re
from xml.sax.saxutils import escape

from ..summary import overall
from .evaluate import BAND_SIGMAS, correlations, drawable, lightest, real_inclusion
from .slots import SLOTS_GO, SLOTS_GO_COMMIT

COLORS = ("#2a78d6", "#eb6834", "#1baf7a", "#4a3aa7")
SELECTION_FIELDS = ("model", "G", "address", "weight", "weight_share", "slots", "slots_expected", "slots_sd",
                    "slot_share_ratio", "included", "included_expected", "included_sd", "slots_when_included",
                    "work_share_when_included", "overload_when_included", "max_slots_in_one_escrow", "excluded")
ADDRESS_FIELDS = ("G", "address", "models", "share_of_slots", "expected_share", "excluded")
MIN_HOSTS_FOR_CORRELATION = 10


def slug(model):
    return re.sub(r"[^a-z0-9]+", "-", model.lower()).strip("-")


def short(address):
    return "…" + address[-6:]


def pct(value, digits=3):
    """Percent with significant digits, so a share of 0.08 % keeps its precision."""
    return "–" if value is None else "%.*g %%" % (digits, 100 * value)


def commit_text(chain):
    return chain["commit"][:12] if chain.get("commit") else "commit unknown"


def _number(value):
    if isinstance(value, float):
        return "%.6g" % value
    return "" if value is None else value


def selection_csv(result, excluded):
    out = io.StringIO()
    writer = csv.writer(out, lineterminator="\n")
    writer.writerow(SELECTION_FIELDS)
    for row in result["rows"]:
        values = dict(row, excluded=int(row["address"] in excluded))
        writer.writerow([_number(values[field]) for field in SELECTION_FIELDS])
    return out.getvalue()


def address_csv(result):
    out = io.StringIO()
    writer = csv.writer(out, lineterminator="\n")
    writer.writerow(ADDRESS_FIELDS)
    for entry in result["addresses"]:
        writer.writerow([entry["G"], entry["address"], " ".join(entry["models"]), _number(entry["share_of_slots"]),
                         _number(entry["expected_share"]), int(entry["excluded"])])
    return out.getvalue()


def chart(result, model):
    """Share of escrows that include a member against its weight share; dots simulated, lines 1-(1-p)^G."""
    rows = [row for row in result["rows"] if row["model"] == model]
    runs = result["runs"]
    W, H, ml, mr, mt, mb = 760, 390, 64, 24, 52, 56
    pw, ph = W - ml - mr, H - mt - mb
    lo = math.floor(math.log10(min(row["weight_share"] for row in rows)) * 2) / 2 - 0.2
    hi = 0.0

    def sx(share):
        return ml + (math.log10(share) - lo) / (hi - lo) * pw

    def sy(value):
        return mt + (1 - value) * ph

    out = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" '
           'font-family="Helvetica, Arial, sans-serif" font-size="12">' % (W, H, W, H),
           '<title>%s: share of escrows that include a member, by weight share</title>' % escape(model),
           '<rect width="%d" height="%d" fill="#ffffff"/>' % (W, H),
           '<text x="%d" y="20" font-size="14" font-weight="bold" fill="#111111">%s: how often a member is in an '
           'escrow</text>' % (ml, escape(model))]
    for value in (0, 0.25, 0.5, 0.75, 1):
        out.append('<line x1="%d" x2="%d" y1="%.1f" y2="%.1f" stroke="#e3e3e3"/>' % (ml, W - mr, sy(value), sy(value)))
        out.append('<text x="%d" y="%.1f" text-anchor="end" fill="#555555">%d%%</text>'
                   % (ml - 6, sy(value) + 4, value * 100))
    for exponent in range(math.ceil(lo), 1):
        for mantissa in (1, 3):
            share = mantissa * 10 ** (exponent - 1)
            if lo <= math.log10(share) <= hi:
                out.append('<line x1="%.1f" x2="%.1f" y1="%d" y2="%d" stroke="#e3e3e3"/>'
                           % (sx(share), sx(share), mt, mt + ph))
                out.append('<text x="%.1f" y="%d" text-anchor="middle" fill="#555555">%g%%</text>'
                           % (sx(share), mt + ph + 16, share * 100))
    out.append('<text x="%.0f" y="%d" text-anchor="middle" fill="#333333">weight share in the model (log scale)</text>'
               % (ml + pw / 2, H - 12))
    out.append('<text x="16" y="%.0f" text-anchor="middle" fill="#333333" transform="rotate(-90 16 %.0f)">'
               'escrows that include the member</text>' % (mt + ph / 2, mt + ph / 2))
    for i, size in enumerate(result["groups"]):
        color = COLORS[i % len(COLORS)]
        path = []
        for k in range(121):
            share = 10 ** (lo + (hi - lo) * k / 120)
            path.append("%s%.1f,%.1f" % ("M" if k == 0 else "L", sx(share), sy(1 - (1 - share) ** size)))
        out.append('<path d="%s" fill="none" stroke="%s" stroke-width="1.5" stroke-opacity="0.8"/>'
                   % ("".join(path), color))
        for row in rows:
            if row["G"] == size:
                out.append('<circle cx="%.1f" cy="%.1f" r="4" fill="%s" stroke="#ffffff" stroke-width="1.2">'
                           '<title>%s share %s, G=%d: %d of %d escrows (formula %.0f)</title></circle>'
                           % (sx(row["weight_share"]), sy(row["included"] / runs), color, short(row["address"]),
                              pct(row["weight_share"]), size, row["included"], runs, row["included_expected"]))
        out.append('<rect x="%d" y="28" width="10" height="10" fill="%s"/>'
                   '<text x="%d" y="37" fill="#333333">G=%d</text>' % (ml + 70 * i, color, ml + 14 + 70 * i, size))
    out.append('<text x="%d" y="37" text-anchor="end" fill="#555555">dots: %d simulated escrows; lines: 1-(1-p)^G'
               '</text>' % (W - mr, runs))
    out.append("</svg>")
    return "\n".join(out) + "\n"


def _table(header, rows, numeric=True):
    lines = ["| " + " | ".join(header) + " |",
             "|" + "|".join("---:" if numeric and i else "---" for i in range(len(header))) + "|"]
    lines += ["| " + " | ".join(str(cell) for cell in row) + " |" for row in rows]
    return "\n".join(lines)


def _ratio(row):
    return "%.2f ±%.2f" % (row["slot_share_ratio"], row["slots_sd"] / row["slots_expected"])


def _header(snap, result):
    chain, runs = snap["chain"], result["runs"]
    heights = "height %d to %s" % (snap["height_start"], snap["height_end"] if snap.get("height_end") else "?")
    lines = ["# Escrow slot distribution, epoch %d" % snap["epoch"], "",
             "Chain %s (%s), %s, current group size %d. Taken %s." % (
                 chain.get("version") or "version unknown", commit_text(chain), heights, snap["group_size"],
                 snap["taken_at"]), ""]
    if chain.get("commit") and not SLOTS_GO_COMMIT.startswith(chain["commit"][:7]):
        lines += ["The chain runs %s, not %s; `slots_replay` shows whether the port still matches." % (
            commit_text(chain), SLOTS_GO_COMMIT[:12]), ""]
    return lines + [
        "Each escrow draws its G slots from the members of its own model, not from all %d members of the epoch; "
        "each slot is an independent draw weighted by the member's share, so one member can hold several slots. "
        "The per-address section adds the models back up." % len(snap["root"]["members"]), "",
        "Selection is replayed with a port of `%s` at `%s`: %d synthetic escrows per model and group size. "
        "Simulated escrow i uses app hash sha256(\"block-i\") and id i, the same for every group size, "
        "so runs for different group sizes are paired: the first 32 slots at G=64 are the slots at G=32." % (
            SLOTS_GO, SLOTS_GO_COMMIT[:12], runs), "",
        "This measures who gets selected, not misses: a slot is an upper bound of the work a member receives.", "",
        "## Checks", "", _table(("check", "verdict", "reason"),
                                [(v["check"], v["verdict"], v["reason"]) for v in result["verdicts"]], numeric=False),
        "", "Overall: **%s**." % overall(result["verdicts"]), ""]


def _model_section(snap, result, model, excluded):
    groups, data = result["groups"], snap["models"][model]
    rows = [row for row in result["rows"] if row["model"] == model]

    def mark(address):
        return short(address) + (" (excluded)" if address in excluded else "")
    lines = ["## %s" % model, "", "%d members, total weight %d, %d real escrows in the snapshot." % (
        len({row["address"] for row in rows}), data["total_weight"], result["escrows_per_model"].get(model, 0)), "",
        "![%s](chart-%s.svg)" % (model, slug(model)), "", "### Every member", ""]
    header = (["member", "weight share"] + ["in escrows, G=%d (formula)" % size for size in groups]
              + ["slot share / weight share, G=%d" % size for size in groups])
    body = []
    for address in sorted({row["address"] for row in rows}, key=lambda a: (-data["weights"][a], a.encode())):
        by_size = {row["G"]: row for row in rows if row["address"] == address}
        body.append([mark(address), pct(by_size[groups[0]]["weight_share"])]
                    + ["%d (%.0f)" % (by_size[size]["included"], by_size[size]["included_expected"]) for size in groups]
                    + [_ratio(by_size[size]) for size in groups])
    lines += [_table(header, body), "", "In escrows: of %d simulated. Slot share / weight share is about 1 for every "
              "member; ± is one sigma of the simulation." % result["runs"], "", "### Lightest quarter", ""]
    header = (["member", "weight share"] + ["in escrows, G=%d" % size for size in groups]
              + ["work share when in, G=%d" % size for size in groups]
              + ["times weight share, G=%d" % size for size in groups])
    body = []
    for light in lightest(result["rows"], model, groups[0]):
        by_size = {row["G"]: row for row in rows if row["address"] == light["address"]}
        body.append([mark(light["address"]), pct(light["weight_share"])]
                    + [by_size[size]["included"] for size in groups]
                    + [pct(by_size[size]["work_share_when_included"]) for size in groups]
                    + ["–" if by_size[size]["overload_when_included"] is None else
                       "%.1f" % by_size[size]["overload_when_included"] for size in groups])
    size, count, real = real_inclusion(snap, model)
    lines += [_table(header, body), "", "Work share when in: slots of the member in an escrow that includes it, "
              "divided by G. Times weight share: that work share divided by the weight share.", ""]
    if count:
        body = [[mark(item["address"]), pct(item["weight_share"]), item["included"], "%.1f" % item["expected"]]
                for item in sorted(real, key=lambda item: (-item["weight_share"], item["address"].encode()))]
        lines += ["### Real escrows of the snapshot, G=%d" % size, "",
                  _table(("member", "weight share", "in escrows", "formula"), body), "",
                  "Of %d real escrows; counts below about 10 say little." % count, ""]
    return lines


def markdown(snap, result):
    groups = result["groups"]
    excluded = {item["address"] for item in snap["excluded"]}
    lines = _header(snap, result)
    for model in snap["models"]:
        if model in drawable(snap):
            lines += _model_section(snap, result, model, excluded)
        else:
            lines += ["## %s" % model, "", "No member with a positive weight: the chain refuses escrows for it.", ""]
    lines += ["## Per address", "",
              "Share of all slots of the epoch, models mixed as among the real escrows of the snapshot (%s)." % (
                  ", ".join("%s %s" % (model.split("/")[-1], pct(share, 2)) for model, share in result["mix"].items()))
              if result["mix_from_escrows"] else
              "Share of all slots of the epoch; no real escrows were read, so every model counts equally.", ""]
    body = []
    by_address = {}
    for entry in result["addresses"]:
        by_address.setdefault(entry["address"], {})[entry["G"]] = entry
    for address, entries in sorted(by_address.items(),
                                   key=lambda kv: (-kv[1][groups[0]]["expected_share"], kv[0].encode())):
        first = entries[groups[0]]
        body.append([short(address) + (" (excluded)" if first["excluded"] else ""), len(first["models"])]
                    + [pct(entries[size]["share_of_slots"]) for size in groups] + [pct(first["expected_share"])])
    lines += [_table(["address", "models"] + ["share, G=%d" % size for size in groups] + ["expected"], body), "",
              "## Appendix: correlation", "",
              "Pearson of weight share with slots, and Pearson and Spearman of weight share with escrows that include "
              "the member. The second falls as G grows because heavy members saturate at every escrow; the slot share "
              "ratio above is the main measure. Shown for models with at least %d members." % MIN_HOSTS_FOR_CORRELATION,
              ""]
    body = []
    for model in drawable(snap):
        if len({row["address"] for row in result["rows"] if row["model"] == model}) < MIN_HOSTS_FOR_CORRELATION:
            continue
        for size in groups:
            body.append([model, size] + ["–" if value is None else "%.3f" % value
                                         for value in correlations(result["rows"], model, size)])
    lines += [_table(("model", "G", "Pearson, slots", "Pearson, in escrows", "Spearman, in escrows"), body)
              if body else "No model has enough members.", "",
              "Checks `slot_share` and `inclusion` accept each count within %d sigma + 1 of the formula." % BAND_SIGMAS,
              ""]
    if excluded:
        lines += ["Excluded mid-epoch: %s. The chain keeps their weights, so they still get slots." % ", ".join(
            "%s (%s)" % (short(item["address"]), item["reason"]) for item in snap["excluded"]), ""]
    return "\n".join(lines)


def write(out_dir, snap, result):
    os.makedirs(out_dir, exist_ok=True)
    excluded = {item["address"] for item in snap["excluded"]}
    files = {"report.md": markdown(snap, result), "selection.csv": selection_csv(result, excluded),
             "addresses.csv": address_csv(result)}
    for model in drawable(snap):
        files["chart-%s.svg" % slug(model)] = chart(result, model)
    for name, text in files.items():
        with open(os.path.join(out_dir, name), "w", encoding="utf-8") as handle:
            handle.write(text)
    return sorted(files)
