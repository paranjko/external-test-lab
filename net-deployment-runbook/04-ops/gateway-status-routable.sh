#!/bin/sh
set -eu

# Read one official gateway /v1/status JSON document from stdin. The official
# Single-runtime responses may expose either `routable` or only the exact
# escrow lifecycle. Pooled responses expose capacity plus runtime state.
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
  def normal_confirmation:
    ([.confirmation_poc_phase?, (.devshards[]? | .confirmation_poc_phase?)]
      | map(select(type == "string"
          and . != ""
          and . != "NORMAL_OPERATION"
          and . != "CONFIRMATION_POC_COMPLETED"))
      | length) == 0;
  def single_runtime_ready:
    ((.escrow_id // "") | tostring | test("^[1-9][0-9]*$"))
    and (.phase // "") == "active"
    and (.chain_phase // "") == "Inference"
    and (.requests_blocked == false)
    and ((.balance // 0) | tonumber) > 0;
  normal_confirmation and (
    ((.routable == true) and (([.devshards[]?] | length) == 0 or active_unblocked))
    or (positive_capacity and active_unblocked)
    or single_runtime_ready
  )
' >/dev/null
