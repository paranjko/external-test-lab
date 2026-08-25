#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 4 ]] || {
  echo 'Usage: classify-gateway-continuity.sh MODEL SNAPSHOT_JSON REQUESTS_JSONL VERDICT_MD' >&2
  exit 2
}

model="$1"
snapshot="$2"
requests="$3"
verdict="$4"

[[ -s "$snapshot" ]] || {
  printf '# Gateway continuity: INCONCLUSIVE\n\nNo PoC preserved-runtime snapshot was captured.\n' >"$verdict"
  exit 2
}
[[ -s "$requests" ]] || {
  printf '# Gateway continuity: INCONCLUSIVE\n\nNo authenticated request observations were captured.\n' >"$verdict"
  exit 2
}
if ! jq -e '.found == true and (.snapshot | type == "object")' "$snapshot" >/dev/null 2>&1; then
  cat >"$verdict" <<EOF
# Gateway continuity: INCONCLUSIVE

No authoritative PoC preserved-runtime snapshot was captured. A missing
snapshot is not evidence that the model had zero preserved runtimes.
EOF
  exit 2
fi

preserved_nodes="$(jq -er --arg model "$model" '
  [.snapshot.model_preserved_nodes[]?
    | select(.model_id == $model)
    | .participants[]?.node_ids[]?]
  | unique | length
' "$snapshot")"

request_summary="$(jq -sc '
  {
    total:length,
    before:([.[] | select(.window == "before")] | length),
    immediate_before:([.[] | select(.coverage == "immediate-before" and (.target_anchor | type) == "number" and .height == (.target_anchor - 1))] | length),
    at_anchor:([.[] | select(.coverage == "at-anchor" and (.target_anchor | type) == "number" and .height == .target_anchor)] | length),
    poc:([.[] | select(.window == "poc")] | length),
    after:([.[] | select(.window == "after")] | length),
    failures:([.[] | select((.http_code | tonumber) < 200 or (.http_code | tonumber) >= 300)] | length),
    first_height:([.[].height] | min),
    last_height:([.[].height] | max)
  }
' "$requests")"

total="$(jq -r .total <<<"$request_summary")"
before="$(jq -r .before <<<"$request_summary")"
immediate_before="$(jq -r .immediate_before <<<"$request_summary")"
at_anchor="$(jq -r .at_anchor <<<"$request_summary")"
poc="$(jq -r .poc <<<"$request_summary")"
after="$(jq -r .after <<<"$request_summary")"
failures="$(jq -r .failures <<<"$request_summary")"
first_height="$(jq -r .first_height <<<"$request_summary")"
last_height="$(jq -r .last_height <<<"$request_summary")"

if (( before == 0 || immediate_before != 1 || at_anchor != 1 || poc == 0 || after == 0 )); then
  cat >"$verdict" <<EOF
# Gateway continuity: INCONCLUSIVE

The evidence does not span all required windows around one PoC boundary.

- Before-PoC observations: $before
- Immediate-before-anchor observations: $immediate_before
- At-anchor observations: $at_anchor
- PoC observations: $poc
- After-PoC observations: $after
- Total authenticated requests: $total

No continuity PASS is implied.
EOF
  exit 2
fi

if (( preserved_nodes == 0 )); then
  cat >"$verdict" <<EOF
# Gateway continuity: BLOCKED

The live PoC snapshot contains no preserved runtime for $model. The current
validator/model topology cannot provide chain-accounted inference throughout
this PoC boundary.

- Evidence heights: $first_height-$last_height
- Authenticated requests: $total
- Failed requests: $failures
- Preserved model runtimes: 0

Add eligible non-guardian model capacity through the independent-operator join
flow, then rerun this command. Gateway limit changes and direct MLNode routing
do not satisfy this gate.
EOF
  exit 3
fi

if (( failures > 0 )); then
  cat >"$verdict" <<EOF
# Gateway continuity: FAIL

The chain exposed $preserved_nodes preserved runtime(s) for $model, but
$failures of $total authenticated requests failed across the PoC boundary at
heights $first_height-$last_height. Inspect requests.jsonl, gateway status and
the preserved snapshot before changing capacity or request limits.
EOF
  exit 1
fi

cat >"$verdict" <<EOF
# Gateway continuity: PASS

Authenticated chain-accounted inference remained successful before, during,
and after one live PoC boundary.

- Evidence heights: $first_height-$last_height
- Authenticated requests: $total
- Before-PoC observations: $before
- Immediate-before-anchor observations: $immediate_before
- At-anchor observations: $at_anchor
- PoC observations: $poc
- After-PoC observations: $after
- Preserved model runtimes: $preserved_nodes
- Failed requests: 0
EOF
