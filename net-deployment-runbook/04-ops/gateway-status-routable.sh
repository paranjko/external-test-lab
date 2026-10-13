#!/bin/sh
set -eu

# Read one official gateway /v1/status JSON document from stdin. Legacy
# gateways expose `routable`, pooled gateways expose capacity plus runtime
# state, and a single-session DevShard v5 exposes its escrow lifecycle only.
jq -e '
  def active_unblocked:
    [.devshards[]?
      | select(.active == true)
      | select((.runtime.phase // .phase // "") == "active")
      | select((.runtime.requests_blocked // .requests_blocked // false) != true)
      | select((.runtime.chain_phase // .chain_phase // "Inference") == "Inference")]
    | length > 0;
  def positive_capacity:
    (.capacity.total_weight // .capacity.effective_weight
      // ([.capacity.models[]?.current_weight // .capacity.models[]?.total_weight] | add)
      // 0 | tonumber) > 0;
  # Runtimes remain visible during confirmation PoC, but user inference is
  # intentionally suspended. A positive snapshot is not safely routable then.
  def confirmation_allows_inference:
    ([.confirmation_poc_phase?, (.devshards[]? | .confirmation_poc_phase?)]
      | map(select(type == "string" and . != ""))
      | all(. == "NORMAL_OPERATION"
        or . == "CONFIRMATION_POC_INACTIVE"
        or . == "CONFIRMATION_POC_COMPLETED"));
  # DevShard v5 publishes the cold-start height seed gate separately from
  # requests_blocked. When present, only `ok` is safe for a completion.
  # Older status contracts omit height_seed and remain compatible.
  def height_seed_allows_inference:
    . == null
    or ((type == "object") and (.state? == "ok"));
  def single_session_routable:
    ((.escrow_id? | type) == "string")
    and ((.escrow_id | length) > 0)
    and (.phase? == "active")
    and (.requests_blocked? == false)
    and (.chain_phase? == "Inference")
    and ((.height_seed? // null) | height_seed_allows_inference);
  confirmation_allows_inference and (
    ((.routable? == true) and (([.devshards[]?] | length) == 0 or active_unblocked))
    or (positive_capacity and active_unblocked)
    or single_session_routable
  )
' >/dev/null
