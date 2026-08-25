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
  def dispatched_lifecycle:
    (.admission == "dispatched_once") and
    (.safe_generation | type == "string" and length > 0) and
    ([.arrival_at_ms,.permit_at_ms,.dispatch_at_ms,.response_at_ms] | all(type == "number")) and
    (.arrival_at_ms <= .permit_at_ms and .permit_at_ms <= .dispatch_at_ms and .dispatch_at_ms <= .response_at_ms) and
    ([.arrival_height,.permit_height,.dispatch_height,.response_height] | all(type == "number")) and
    (.arrival_height <= .permit_height and .permit_height <= .dispatch_height and .dispatch_height <= .response_height);
  def lifecycle:
    dispatched_lifecycle and
    (.response_id | type == "string" and length > 0);
  def exact_boundary:
    (.target_anchor | type) == "number" and
    ((.coverage == "immediate-before" and .arrival_height == (.target_anchor - 1)) or
     (.coverage == "at-anchor" and .arrival_height == .target_anchor) or
     (.coverage == "immediate-after-anchor" and .arrival_height == (.target_anchor + 1)));
  def audit_deadline:
    (.admission_record.deadline_ms | type == "number") and
    (.admission_record.response_at_ms | type == "number") and
    (.admission_record.response_at_ms >= .admission_record.deadline_ms);
  # A dispatch-attempt failure is a terminal outcome after the sole permitted
  # upstream connection was started. The gateway emitted no upstream response;
  # it must not be mistaken for upstream HTTP 504 or downgraded to coverage.
  def terminal_dispatch_timeout:
    exact_boundary and
    (.admission == "dispatch_attempt_failed") and
    (.error_class == "gateway_dispatch_timeout") and
    ((.upstream_http_status | tonumber) == 0) and
    ([.arrival_at_ms,.permit_at_ms,.dispatch_at_ms,.response_at_ms] | all(type == "number")) and
    (.arrival_at_ms <= .permit_at_ms and .permit_at_ms <= .dispatch_at_ms and .dispatch_at_ms <= .response_at_ms) and
    audit_deadline;
  # A PoC fence can hold a request until its original absolute deadline. This
  # is a terminal exact-boundary failure, not a harmless early fence reject.
  def terminal_fence_deadline:
    exact_boundary and
    (.admission == "pre_dispatch_rejected") and
    (.error_class == "admission_poc_fence") and
    ((.upstream_http_status | tonumber) == 0) and
    ((.permit_at_ms | tonumber) == 0) and
    ((.dispatch_at_ms | tonumber) == 0) and
    audit_deadline;
  {
    total:length,
    before:([.[] | select(.window == "before")] | length),
    immediate_before:([.[] | select(.coverage == "immediate-before" and (.target_anchor | type) == "number" and .arrival_height == (.target_anchor - 1) and lifecycle)] | length),
    at_anchor:([.[] | select(.coverage == "at-anchor" and (.target_anchor | type) == "number" and .arrival_height == .target_anchor and lifecycle)] | length),
    poc:([.[] | select(.window == "poc")] | length),
    after:([.[] | select(.window == "after")] | length),
    invalid:([.[] | select(lifecycle | not)] | length),
    duplicate_ids:([.[] | select(.response_id | type == "string" and length > 0) | .response_id] | group_by(.) | map(select(length > 1)) | length),
    failures:([.[] | select((.http_code | tonumber) < 200 or (.http_code | tonumber) >= 300)] | length),
    decisive_failures:([.[] | select(exact_boundary and dispatched_lifecycle and
      ((.upstream_http_status | tonumber) < 200 or (.upstream_http_status | tonumber) >= 300))] | length),
    terminal_dispatch_timeouts:([.[] | select(terminal_dispatch_timeout)] | length),
    terminal_fence_deadlines:([.[] | select(terminal_fence_deadline)] | length),
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
decisive_failures="$(jq -r .decisive_failures <<<"$request_summary")"
terminal_dispatch_timeouts="$(jq -r .terminal_dispatch_timeouts <<<"$request_summary")"
terminal_fence_deadlines="$(jq -r .terminal_fence_deadlines <<<"$request_summary")"
invalid="$(jq -r .invalid <<<"$request_summary")"
duplicate_ids="$(jq -r .duplicate_ids <<<"$request_summary")"
first_height="$(jq -r .first_height <<<"$request_summary")"
last_height="$(jq -r .last_height <<<"$request_summary")"

if (( preserved_nodes > 0 && (decisive_failures > 0 || terminal_dispatch_timeouts > 0 || terminal_fence_deadlines > 0) )); then
  cat >"$verdict" <<EOF
# Gateway continuity: FAIL

The chain exposed $preserved_nodes preserved runtime(s) for $model, but
$decisive_failures exact-boundary request(s) returned a non-success upstream
response, $terminal_dispatch_timeouts began their sole upstream attempt but
received no upstream response before the original deadline, and
$terminal_fence_deadlines expired before dispatch while held by the PoC fence.
This is observed continuity failure, not missing coverage.

- Evidence heights: $first_height-$last_height
- Authenticated requests: $total
- Exact-boundary non-success upstream responses: $decisive_failures
- Terminal dispatch-attempt timeouts: $terminal_dispatch_timeouts
- Terminal PoC-fence deadline expirations: $terminal_fence_deadlines
- Preserved model runtimes: $preserved_nodes

Inspect requests.jsonl, the matching admission records, gateway status and the
preserved snapshot before changing capacity or request limits.
EOF
  exit 1
fi

if (( before == 0 || immediate_before != 1 || at_anchor != 1 || poc == 0 || after == 0 || invalid > 0 || duplicate_ids > 0 )); then
  cat >"$verdict" <<EOF
# Gateway continuity: INCONCLUSIVE

The evidence does not span all required windows around one PoC boundary.

- Before-PoC observations: $before
- Immediate-before-anchor observations: $immediate_before
- At-anchor observations: $at_anchor
- PoC observations: $poc
- After-PoC observations: $after
- Total authenticated requests: $total
- Invalid lifecycle observations: $invalid
- Duplicate response IDs: $duplicate_ids

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
