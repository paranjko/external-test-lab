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
if join_acceptance_state_epoch_within_deadline 44 "$deadline_epoch"; then
  exit 1
fi
strongest="$(join_acceptance_state_restore_strongest "$run")"
[[ "$(jq -r .epoch <<<"$strongest")" == 41 ]]
join_acceptance_state_record_strongest "$run" 41 730 730 730
join_acceptance_state_record_distribution "$run" 200 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 0
join_acceptance_state_record_eligibility "$run" 43 validator-key-1

read -r initial_epoch deadline_epoch < <(join_acceptance_state_initialize "$run" "$run_id" "$genesis" "$participant" "$runtime" 67 4)
[[ "$initial_epoch" == 40 && "$deadline_epoch" == 43 ]]
jq -e --arg run_id "$run_id" '.run_id == $run_id and .initial_epoch == 40 and .deadline_epoch == 43 and .strongest_observed.epoch == 41 and .distribution_evidence.stage == 200 and .distribution_evidence.tx_code == 0' "$run/acceptance-state.json" >/dev/null
distribution="$(join_acceptance_state_restore_distribution "$run")"
[[ "$(jq -r .stage <<<"$distribution")" == 200 ]]
[[ "$(jq -r .tx_hash <<<"$distribution")" == AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA ]]
eligibility="$(join_acceptance_state_restore_eligibility "$run" validator-key-1)"
[[ "$(jq -r .epoch <<<"$eligibility")" == 43 ]]
[[ "$(jq -r .accepted_weight_sum <<<"$eligibility")" == 730 ]]
if join_acceptance_state_restore_eligibility "$run" validator-key-2 >/dev/null 2>&1; then
  exit 1
fi

# A pre-checkpoint run that stopped only because the operator gateway key was
# unavailable can safely adopt its fully bound BLOCKED receipt after the epoch
# deadline has passed.
legacy="$temporary/join-acceptance-gdc-node2"
mkdir -p "$legacy"
printf '[]\n' >"$legacy/poc-acceptance-observations.json"
read -r legacy_initial legacy_deadline < <(join_acceptance_state_initialize "$legacy" legacy-run "$genesis" "$participant" "$runtime" 50 3)
[[ "$legacy_initial" == 50 && "$legacy_deadline" == 53 ]]
join_acceptance_state_record_strongest "$legacy" 53 26 420 420
join_acceptance_state_record_distribution "$legacy" 350 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA 0
jq -n --arg genesis "$genesis" --arg participant "$participant" --arg runtime "$runtime" '
  {schema_version:1,verdict:"BLOCKED",reason:"the verified public bootstrap did not provide the scoped gateway client credential required for the final authenticated gateway regression",
   run_id:"legacy-run",genesis_sha256:$genesis,participant_address:$participant,validator_key:"validator-key-2",runtime_id:$runtime,
   profile_hash:"profile-hash",deadline_epoch:53,poc_accepted_once:true,poc_accepted_epoch:53,poc_participant_weight:26,
   poc_accepted_weight_sum:420,poc_committed_total:420,poc_distribution_tx_hash:"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
   poc_distribution_tx_code:0}' >"$legacy/receipt.json"
join_acceptance_state_adopt_gateway_blocked_receipt "$legacy" validator-key-2 profile-hash
legacy_eligibility="$(join_acceptance_state_restore_eligibility "$legacy" validator-key-2)"
[[ "$(jq -r .epoch <<<"$legacy_eligibility")" == 53 ]]
if join_acceptance_state_adopt_gateway_blocked_receipt "$legacy" validator-key-2 wrong-profile >/dev/null 2>&1; then
  exit 1
fi
printf 'PASS interrupted acceptance retains its deadline and resumes completed eligibility without extending the epoch window\n'
