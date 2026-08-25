#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=join-acceptance-state.sh
source "$ROOT/scripts/join-acceptance-state.sh"

temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
run="$temporary/join-acceptance-gdc-node1"
mkdir -p "$run"
genesis=0ecf4ca9cb54c84b6d4788cd161dad68f4b40e0bd8bcc6f7db270da9352fbfbc
participant=gonka1035nf0nt68sh752k40hqr274xyxr4nsq0fkx3a
runtime="qwen3-0.6b:$participant"
run_id=test-lifecycle-resume

# An old run predates acceptance-state.json but retains its first observation
# from epoch 40. The migration and later resume must retain deadline 43.
printf '%s\n' '[{"epoch":40,"weight_evidence":{"participant_eligible":false,"participant_weight":0,"accepted_weight_sum":0,"committed_total":0}},{"epoch":41,"weight_evidence":{"participant_eligible":true,"participant_weight":730,"accepted_weight_sum":730,"committed_total":730}}]' >"$run/poc-acceptance-observations.json"
read -r initial_epoch deadline_epoch < <(join_acceptance_state_initialize "$run" "$run_id" "$genesis" "$participant" "$runtime" 40 3)
[[ "$initial_epoch" == 40 && "$deadline_epoch" == 43 ]]
join_acceptance_state_epoch_within_deadline 43 "$deadline_epoch"
! join_acceptance_state_epoch_within_deadline 44 "$deadline_epoch"
strongest="$(join_acceptance_state_restore_strongest "$run")"
[[ "$(jq -r .epoch <<<"$strongest")" == 41 ]]
join_acceptance_state_record_strongest "$run" 41 730 730 730
join_acceptance_state_record_distribution "$run" 200 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 0

read -r initial_epoch deadline_epoch < <(join_acceptance_state_initialize "$run" "$run_id" "$genesis" "$participant" "$runtime" 67 4)
[[ "$initial_epoch" == 40 && "$deadline_epoch" == 43 ]]
jq -e --arg run_id "$run_id" '.run_id == $run_id and .initial_epoch == 40 and .deadline_epoch == 43 and .strongest_observed.epoch == 41 and .distribution_evidence.stage == 200 and .distribution_evidence.tx_code == 0' "$run/acceptance-state.json" >/dev/null
distribution="$(join_acceptance_state_restore_distribution "$run")"
[[ "$(jq -r .stage <<<"$distribution")" == 200 ]]
[[ "$(jq -r .tx_hash <<<"$distribution")" == AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA ]]
printf 'PASS interrupted epoch-40 acceptance resumes at epoch 67 with original deadline and canonical distribution evidence\n'
