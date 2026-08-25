#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL='Qwen/Qwen3-0.6B'
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ready_fixture() {
  jq -nc --arg model "$MODEL" '{
    observed_at:"2026-08-23T00:00:00Z",height:100,
    sources:{participants:true,validators:true,epoch_group:true,gateway_status:true,public_health:true,reserve:true,reconciliation:true},
    expected_hosts:["node0.example","node1.example","node2.example","node3.example","node4.example"],
    participants:{participant:[range(0;5) as $n | {inference_url:("https://node"+($n|tostring)+".example"),status:"ACTIVE",validator_key:("key"+($n|tostring)),address:("addr"+($n|tostring))}]},
    validators:{result:{validators:[range(0;5) as $n | {pub_key:{value:("key"+($n|tostring))},voting_power:"100"}]}},
    epoch_group:{epoch_group_data:{validation_weights:[range(0;5) as $n | {member_address:("addr"+($n|tostring)),weight:"100",voting_power:"100"}]}},
    gateway_status:{capacity:{host_count:5,available_host_count:5,total_weight:500,models:{($model):{current_weight:500,routable:true}}},devshards:[{active:true,runtime:{phase:"active",chain_phase:"Inference",requests_blocked:false}}]},
    public_health:{state:"READY",reason:"completion_succeeded",http_status:200},
    reserve:{state:"READY",reason:"within_policy",current_balance:"10",low_watermark:"5"},
    reconciliation:{state:"READY",reason:"confirmed",last_confirmed_state:"READY"}
  }'
}

ready_fixture | "$ROOT/scripts/evaluate-recovery-readiness.sh" "$MODEL" >"$WORK/ready.json"
jq -e '.overall_ready == true and (.failed_predicates | length) == 0 and .gateway.shared_status_routable == true' "$WORK/ready.json" >/dev/null

ready_fixture | jq --arg model "$MODEL" 'del(.gateway_status.capacity.models[$model].routable)' \
  | "$ROOT/scripts/evaluate-recovery-readiness.sh" "$MODEL" >"$WORK/pooled-v3.json"
jq -e '.overall_ready == true and .gateway.model_routable == true and .gateway.shared_status_routable == true' "$WORK/pooled-v3.json" >/dev/null

ready_fixture | jq '.participants.participant[3].status="ACTIVE" | .validators.result.validators[3].voting_power="0" | .epoch_group.epoch_group_data.validation_weights |= del(.[3])' \
  | "$ROOT/scripts/evaluate-recovery-readiness.sh" "$MODEL" >"$WORK/node3.json"
jq -e '.overall_ready == false
  and .failed_predicates == ["all_consensus_voting_power_positive"]
  and .hosts[3].participant_status == "ACTIVE"
  and .hosts[3].consensus_voting_power == 0
  and .hosts[3].epoch_group_member == false' "$WORK/node3.json" >/dev/null

ready_fixture | jq --arg model "$MODEL" '.gateway_status.capacity.host_count=4 | .gateway_status.capacity.available_host_count=4 | .gateway_status.capacity.models[$model].current_weight=0 | .gateway_status.capacity.models[$model].routable=false | .gateway_status.capacity.total_weight=0' \
  | "$ROOT/scripts/evaluate-recovery-readiness.sh" "$MODEL" >"$WORK/capacity.json"
jq -e '.failed_predicates | index("gateway_host_count_expected") and index("gateway_available_host_count_expected") and index("model_capacity_positive") and index("model_routable") and index("gateway_status_routable")' "$WORK/capacity.json" >/dev/null

ready_fixture | jq '.gateway_status.devshards[0].runtime.chain_phase="PoCValidate"' \
  | "$ROOT/scripts/evaluate-recovery-readiness.sh" "$MODEL" >"$WORK/phase.json"
jq -e '.failed_predicates | index("active_unblocked_inference_runtime") and index("gateway_status_routable")' "$WORK/phase.json" >/dev/null

printf 'PASS recovery readiness predicate\n'
