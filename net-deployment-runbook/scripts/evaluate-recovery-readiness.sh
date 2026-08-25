#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 1 ]] || {
  echo 'Usage: evaluate-recovery-readiness.sh MODEL_ID < recovery-sources.json' >&2
  exit 2
}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
model_id="$1"
input="$(cat)"

gateway_status_routable=false
if jq -e '.sources.gateway_status == true' <<<"$input" >/dev/null 2>&1 \
  && jq -c '.gateway_status' <<<"$input" \
    | "$ROOT/04-ops/gateway-status-routable.sh" >/dev/null 2>&1; then
  gateway_status_routable=true
fi

jq -c \
  --arg model_id "$model_id" \
  --argjson gateway_status_routable "$gateway_status_routable" '
  def number_or_zero: try tonumber catch 0;
  def model_capacity($model):
    (.gateway_status.capacity.models[$model].current_weight
      // .gateway_status.capacity.models[$model].total_weight
      // .gateway_status.capacity.total_weight
      // .gateway_status.capacity.effective_weight
      // 0 | number_or_zero);
  def active_inference_runtimes:
    [.gateway_status.devshards[]?
      | select(.active == true)
      | select((.runtime.phase // .phase // "") == "active")
      | select((.runtime.requests_blocked // .requests_blocked // false) != true)
      | select((.runtime.chain_phase // .chain_phase // "") == "Inference")];
  .expected_hosts as $expected_hosts
  | .participants as $participants
  | .validators as $validators
  | (.epoch_group.epoch_group_data // .epoch_group) as $epoch_group
  | [ $expected_hosts[] as $host
      | (($participants.participant[]? | select(.inference_url == ("https://" + $host))) // {}) as $participant
      | (($validators.result.validators[]? | select(.pub_key.value == $participant.validator_key)) // {}) as $validator
      | (($epoch_group.validation_weights[]? | select(.member_address == $participant.address)) // {}) as $member
      | {host:$host,
         participant_status:($participant.status // null),
         consensus_voting_power:(($validator.voting_power // "0") | number_or_zero),
         epoch_group_member:($member != {}),
         epoch_weight:(($member.weight // "0") | number_or_zero),
         epoch_voting_power:(($member.voting_power // "0") | number_or_zero)}
    ] as $hosts
  | (.expected_hosts | length) as $expected_count
  | (model_capacity($model_id)) as $model_capacity
  | (active_inference_runtimes) as $active_inference
  | ((.gateway_status.capacity.models[$model_id].routable // .gateway_status.routable // false)
      or ($model_capacity > 0 and $gateway_status_routable)) as $model_routable
  | {
      observed_at:(.observed_at // null),
      height:(.height // null),
      sources:.sources,
      expected_host_count:$expected_count,
      hosts:$hosts,
      gateway:{
        host_count:((.gateway_status.capacity.host_count // 0) | number_or_zero),
        available_host_count:((.gateway_status.capacity.available_host_count // 0) | number_or_zero),
        model_capacity:$model_capacity,
        model_routable:$model_routable,
        shared_status_routable:$gateway_status_routable,
        active_unblocked_inference_runtimes:($active_inference | length)
      },
      health:{state:(.public_health.state // null),reason:(.public_health.reason // null),http_status:(.public_health.http_status // null)},
      reserve:{state:(.reserve.state // null),reason:(.reserve.reason // null)},
      reconciliation:{state:(.reconciliation.state // null),reason:(.reconciliation.reason // null),last_confirmed_state:(.reconciliation.last_confirmed_state // null)},
      diagnostics:{
        all_epoch_group_members:($hosts | length == $expected_count and all(.[]; .epoch_group_member)),
        all_epoch_weights_positive:($hosts | length == $expected_count and all(.[]; .epoch_weight > 0)),
        all_epoch_voting_power_positive:($hosts | length == $expected_count and all(.[]; .epoch_voting_power > 0))
      },
      predicates:{
        all_sources_readable:([.sources[]] | length == 7 and all(.[]; . == true)),
        all_expected_participants_active:($hosts | length == $expected_count and all(.[]; .participant_status == "ACTIVE")),
        all_consensus_voting_power_positive:($hosts | length == $expected_count and all(.[]; .consensus_voting_power > 0)),
        gateway_host_count_expected:(((.gateway_status.capacity.host_count // 0) | number_or_zero) == $expected_count),
        gateway_available_host_count_expected:(((.gateway_status.capacity.available_host_count // 0) | number_or_zero) == $expected_count),
        model_capacity_positive:($model_capacity > 0),
        model_routable:$model_routable,
        gateway_status_routable:$gateway_status_routable,
        active_unblocked_inference_runtime:(($active_inference | length) > 0),
        public_health_ready:(.public_health.state == "READY" and .public_health.reason == "completion_succeeded" and .public_health.http_status == 200),
        reserve_ready:(.reserve.state == "READY" and ((.reserve.current_balance // 0) | number_or_zero) >= ((.reserve.low_watermark // 0) | number_or_zero)),
        reconciliation_ready:(.reconciliation.state == "READY" and .reconciliation.last_confirmed_state == "READY")
      }
    }
  | .failed_predicates = [.predicates | to_entries[] | select(.value != true) | .key]
  | .overall_ready = (.failed_predicates | length == 0)
' <<<"$input"
