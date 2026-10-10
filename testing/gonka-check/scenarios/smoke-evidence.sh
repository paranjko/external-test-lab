#!/usr/bin/env bash
# Evidence that the checks of this commit ran on DevNet: a dry run and the smoke profile on each gateway preset,
# then the chain profile, collected key-free in one directory with evidence.md and evidence.json.
# Reads only public DevNet endpoints, so it runs the same from the bastion and from a CI runner.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
GCHECK=${GCHECK:-$here/bin/gcheck}
out="" key_dir="" wait=420 allow_dirty=0
smoke_presets="devnet-a devnet-b" chain_preset=devnet

usage() {
  echo "usage: $0 --out DIR [--key-dir DIR] [--smoke 'PRESET ...'] [--chain PRESET|none] [--wait S] [--allow-dirty]" >&2
  exit 2
}
while [ $# -gt 0 ]; do
  case $1 in
    --out) out=${2:-}; shift ;;
    --key-dir) key_dir=${2:-}; shift ;;
    --smoke) smoke_presets=${2:-}; shift ;;
    --chain) chain_preset=${2:-}; shift ;;
    --wait) wait=${2:-}; shift ;;
    --allow-dirty) allow_dirty=1 ;;
    *) usage ;;
  esac
  shift
done
[ -n "$out" ] || usage
[ ! -e "$out" ] || { echo "$out exists; give a new directory" >&2; exit 2; }
command -v python3 >/dev/null || { echo "missing: python3" >&2; exit 2; }

commit=$(git -C "$here" rev-parse HEAD 2>/dev/null || echo unknown)
dirty=$(git -C "$here" status --porcelain -- . 2>/dev/null | head -n 1)
if [ -n "$dirty" ] && [ "$allow_dirty" != 1 ]; then
  echo "local changes in $here: commit or stash them, or add --allow-dirty" >&2
  exit 2
fi
mkdir -p "$out/runs"
runs="$out/runs.tsv"
: > "$runs"

# preset_name PRESET: the name gcheck gives the preset, also for a path to a preset file.
preset_name() {
  python3 - "$1" "$here" <<'PY'
import json, os, sys
arg, root = sys.argv[1:]
path = arg if os.path.isfile(arg) else os.path.join(root, "presets", arg + ".json")
with open(path, encoding="utf-8") as handle:
    print(json.load(handle)["name"])
PY
}

# run_gcheck PRESET PROFILE ARGS...: one gcheck run; its records are copied and listed in runs.tsv.
run_gcheck() {
  local preset=$1 profile=$2 name log code dir
  shift 2
  name=$(preset_name "$preset")
  log="$out/$name-$profile.log"
  set +e
  "$GCHECK" run --preset "$preset" "$@" 2>&1 | tee "$log"
  code=${PIPESTATUS[0]}
  set -e
  dir=$(sed -n 's/^records  //p' "$log" | tail -n 1)
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    cp -R "$dir" "$out/runs/"
    printf '%s\t%s\t%s\t%s\n' "$name" "$profile" "$code" "$(basename "$dir")" >> "$runs"
  else
    printf '%s\t%s\t%s\t-\n' "$name" "$profile" "$code" >> "$runs"
  fi
  return "$code"
}

for preset in $smoke_presets; do
  key_args=()
  [ -z "$key_dir" ] || key_args=(--key-file "$key_dir/$(preset_name "$preset").key")
  if run_gcheck "$preset" dry-run --dry-run --wait "$wait" ${key_args[@]+"${key_args[@]}"}; then
    run_gcheck "$preset" smoke --profile smoke --wait "$wait" ${key_args[@]+"${key_args[@]}"} || true
  fi
done
[ "$chain_preset" = none ] || run_gcheck "$chain_preset" chain --profile chain || true

python3 - "$out" "$commit" "${dirty:+dirty}" <<'PY'
import json, os, sys
out, commit, dirty = sys.argv[1:]
rows = []
with open(os.path.join(out, "runs.tsv"), encoding="utf-8") as handle:
    for line in handle:
        preset, profile, code, run_id = line.rstrip("\n").split("\t")
        summary = {}
        path = os.path.join(out, "runs", run_id, "summary.json")
        if os.path.isfile(path):
            with open(path, encoding="utf-8") as stream:
                summary = json.load(stream)
        rows.append({"preset": preset, "profile": profile, "exit_code": int(code), "run_id": run_id,
                     "target": summary.get("target", "-"), "overall": summary.get("overall", "NO SUMMARY"),
                     "verdicts": [{"check": v.get("check"), "maps": v.get("maps") or [], "verdict": v.get("verdict"),
                                   "reason": v.get("reason")} for v in summary.get("verdicts", [])]})
smoke = [row for row in rows if row["profile"] in ("dry-run", "smoke")]
evidence = {"commit": commit, "dirty": bool(dirty), "runs": rows,
            "exit_code": max([row["exit_code"] for row in smoke] or [3])}
with open(os.path.join(out, "evidence.json"), "w", encoding="utf-8") as handle:
    json.dump(evidence, handle, indent=2, sort_keys=True)
lines = ["## gcheck on DevNet at `%s`%s" % (commit[:12], " (local changes)" if dirty else ""), "",
         "| preset | target | profile | run | result |", "|---|---|---|---|---|"]
lines += ["| %s | %s | %s | `%s` | %s (exit %d) |" % (r["preset"], r["target"], r["profile"], r["run_id"], r["overall"],
                                                    r["exit_code"]) for r in rows]
for row in rows:
    if row["verdicts"]:
        lines += ["", "**%s, %s**" % (row["preset"], row["profile"]), ""]
        lines += ["- %s `%s` %s: %s" % (v["verdict"], v["check"], ",".join(v["maps"]), v["reason"])
                  for v in row["verdicts"]]
with open(os.path.join(out, "evidence.md"), "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")
PY

# No key may reach the evidence: compare every key used with every file collected, without printing it.
pattern=$(mktemp)
trap 'rm -f "$pattern"' EXIT
for preset in $smoke_presets; do
  key="${key_dir:+$key_dir/}$(preset_name "$preset").key"
  [ -n "$key_dir" ] || key="${XDG_CONFIG_HOME:-$HOME/.config}/gonka-check/$key"
  [ -s "$key" ] || continue
  tr -d ' \r\n' < "$key" > "$pattern"
  if [ -s "$pattern" ] && grep -rqF -f "$pattern" "$out"; then
    echo "a key was found in $out; do not publish it" >&2
    exit 4
  fi
done

cat "$out/evidence.md"
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || cat "$out/evidence.md" >> "$GITHUB_STEP_SUMMARY"
exit "$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["exit_code"])' "$out/evidence.json")"
