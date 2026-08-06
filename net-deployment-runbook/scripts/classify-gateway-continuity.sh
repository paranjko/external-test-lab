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

preserved_nodes="$(jq -er --arg model "$model" '
  if .found != true then 0
  else
    [.snapshot.model_preserved_nodes[]?
      | select(.model_id == $model)
      | .participants[]?.node_ids[]?]
    | unique | length
  end
' "$snapshot")"

request_summary="$(jq -sc '
  {
    total:length,
    before:([.[] | select(.window == "before")] | length),
    poc:([.[] | select(.window == "poc")] | length),
    after:([.[] | select(.window == "after")] | length),
    failures:([.[] | select((.http_code | tonumber) < 200 or (.http_code | tonumber) >= 300)] | length),
    first_height:([.[].height] | min),
    last_height:([.[].height] | max)
  }
' "$requests")"

total="$(jq -r .total <<<"$request_summary")"
before="$(jq -r .before <<<"$request_summary")"
poc="$(jq -r .poc <<<"$request_summary")"
after="$(jq -r .after <<<"$request_summary")"
failures="$(jq -r .failures <<<"$request_summary")"
first_height="$(jq -r .first_height <<<"$request_summary")"
last_height="$(jq -r .last_height <<<"$request_summary")"

if (( before == 0 || poc == 0 || after == 0 )); then
  cat >"$verdict" <<EOF
# Gateway continuity: INCONCLUSIVE

The evidence does not span all required windows around one PoC boundary.

- Before-PoC observations: $before
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
- PoC observations: $poc
- After-PoC observations: $after
- Preserved model runtimes: $preserved_nodes
- Failed requests: 0
EOF
