#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/consensus-signer-recovery.sh"
account=gonka1y36qy55u9tup0sr20373qrk2mnfjeml3j20ag4
operator=gonkavaloper1y36qy55u9tup0sr20373qrk2mnfjeml3w276lc
[[ "$(recovery_address_payload "$account" gonka)" == "$(recovery_address_payload "$operator" gonkavaloper)" ]]
for invalid in "${account%?}q" "${account^^}" "gonkavaloper${account#gonka}"; do
  if recovery_address_payload "$invalid" gonka >/dev/null 2>&1; then
    echo 'FAIL accepted corrupt address or substituted prefix' >&2; exit 1
  fi
done
[[ "$(recovery_consensus_address 'fRPxc49iPe/FAFd/uV/rbXGREP5Csxmu42Ui0gAiCGY=')" == B6288C8773399CB566C25521BF308BCB6FD02E9C ]]
[[ "$(recovery_address_payload gonkavalcons1kc5gepmn8xwt2ekz25sm7vytedhaqt5uk8nmwv gonkavalcons)" == b6288c8773399cb566c25521bf308bcb6fd02e9c ]]
echo 'PASS Bash address checks validate checksums and consensus key derivation'
for prefix in gonka gonkavaloper gonkavalcons; do
  case "$prefix" in
    gonka) zero_address=gonka1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqrk8pql ;;
    gonkavaloper) zero_address=gonkavaloper1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqlkkxhj ;;
    gonkavalcons) zero_address=gonkavalcons1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqt996mn ;;
  esac
  [[ "$(recovery_address_payload "$zero_address" "$prefix")" == "$(printf '%040d' 0)" ]]
done
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
key='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
address="$(printf '%s' "$key" | base64 -d | sha256sum | cut -c1-40 | tr '[:lower:]' '[:upper:]')"
jq -n --arg key "$key" --arg address "$address" '{result:{block_height:"100",count:"1",total:"1",
  validators:[{address:$address,pub_key:{type:"tendermint/PubKeyEd25519",value:$key},voting_power:"18"}]}}' >"$temporary/set.json"
[[ "$(recovery_effective_power "$temporary/set.json" 100 "$key")" == 18 ]]
for expression in \
  '.result.block_height="99"' \
  '.result.total="2"' \
  '.result.count="0"' \
  '.result.validators[0].voting_power="0"' \
  '.result.validators[0].voting_power="-1"' \
  '.result.validators[0].pub_key.type="unknown"' \
  '.result.validators[0].address="WRONG"' \
  '.result.validators += .result.validators | .result.total="2" | .result.count="2"'; do
  jq "$expression" "$temporary/set.json" >"$temporary/invalid.json"
  if recovery_effective_power "$temporary/invalid.json" 100 "$key" >/dev/null 2>&1; then
    echo "FAIL accepted invalid validator set: $expression" >&2; exit 1
  fi
done
if recovery_effective_power "$temporary/set.json" 100 invalid >/dev/null 2>&1; then
  echo 'FAIL accepted invalid consensus key' >&2; exit 1
fi
printf '%s\n' '{"validators":[],"pagination":{"next_key":"another-page"}}' >"$temporary/list.json"
if recovery_complete_list "$temporary/list.json" validators >/dev/null; then
  echo 'FAIL accepted partial staking list' >&2; exit 1
fi
printf '%s\n' '{"validators":[],"pagination":{"next_key":null}}' >"$temporary/list.json"
[[ "$(recovery_complete_list "$temporary/list.json" validators)" == '[]' ]]
echo 'PASS Bash recovery checks reject incomplete sets, wrong keys/heights and nonpositive power'

mkdir "$temporary/binding"
target_key='fRPxc49iPe/FAFd/uV/rbXGREP5Csxmu42Ui0gAiCGY='
jq -n --arg account "$account" --arg key "$key" \
  '{state:"COMPLETE",signer_ever_started:true,run_id:"parent",node_name:"node5",
    identity_fingerprints:{participant_address:$account,consensus_pubkey:$key,p2p_node_id:"p2p",warm_address:"warm"}}' >"$temporary/binding/parent.json"
jq -n --arg account "$account" --arg key "$target_key" \
  '{node_name:"node5",participant_address:$account,identity:{consensus_pubkey:$key}}' >"$temporary/binding/archive.json"
jq -n --arg account "$account" --arg key "$key" \
  '{participant:{address:$account,validator_key:$key}}' >"$temporary/binding/participant.json"
jq -n --arg operator "$operator" --arg key "$target_key" \
  '{validator:{operator_address:$operator,jailed:true,consensus_pubkey:{"@type":"/cosmos.crypto.ed25519.PubKey",key:$key}}}' >"$temporary/binding/staking.json"
jq -n '{val_signing_info:{address:"gonkavalcons1kc5gepmn8xwt2ekz25sm7vytedhaqt5uk8nmwv",tombstoned:false}}' >"$temporary/binding/signing.json"
check_binding() {
  recovery_verify_intent "$temporary/binding/parent.json" "$temporary/binding/archive.json" \
    "$temporary/binding/participant.json" "$temporary/binding/staking.json" "$temporary/binding/signing.json"
}
cp -a "$temporary/binding" "$temporary/binding-before"
check_binding | jq -e '.jailed and .participant_rebind_required and (.activation_authorized == false) and .preserve_p2p_node_id == "p2p" and .preserve_warm_address == "warm"' >/dev/null
for file in parent archive participant staking signing; do cmp "$temporary/binding/$file.json" "$temporary/binding-before/$file.json"; done
jq --arg key "$target_key" '.participant.validator_key=$key' "$temporary/binding-before/participant.json" >"$temporary/binding/participant.json"
check_binding | jq -e '.participant_rebind_required == false' >/dev/null
cp "$temporary/binding-before/participant.json" "$temporary/binding/participant.json"
for mutation in \
  'parent:.state="RUN_CREATED"' \
  'parent:.signer_ever_started=false' \
  'archive:.node_name="another-host"' \
  'archive:.participant_address="gonka1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqrk8pql"' \
  'archive:.identity.consensus_pubkey="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="' \
  'archive:.identity.consensus_pubkey="invalid"' \
  'participant:.participant.address="another-owner"' \
  'participant:.participant.address="gonka1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqrk8pql"' \
  'participant:.participant.validator_key="another-key"' \
  'staking:.validator.consensus_pubkey.key="another-key"' \
  'staking:.validator.operator_address="gonkavaloper1invalid"' \
  'staking:.validator.operator_address="gonkavaloper1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqlkkxhj"' \
  'staking:.validator.jailed="false"' \
  'staking:.validator.consensus_pubkey["@type"]="unknown"' \
  'signing:.val_signing_info.tombstoned=true' \
  'signing:.val_signing_info.tombstoned=null' \
  'signing:del(.val_signing_info.tombstoned)' \
  'signing:.val_signing_info.address="gonkavalcons1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqt996mn"' \
  'signing:.val_signing_info.address="gonkavalcons1invalid"'; do
  file="$temporary/binding/${mutation%%:*}.json"
  cp "$file" "$temporary/original.json"
  jq "${mutation#*:}" "$temporary/original.json" >"$file"
  if check_binding >/dev/null 2>&1; then
    echo "FAIL accepted invalid recovery binding: $mutation" >&2; exit 1
  fi
  cp "$temporary/original.json" "$file"
done
echo 'PASS Bash ownership checks reject mismatched identities and tombstoned validators'

(
  mkdir "$temporary/checkpoint"
  recovery_verify_commit() {
    [[ "$2" == chain && "$3" == 100 && "$4" == "$key" && "$5" == - ]] || return 1
    printf '%s\n' "${1##*/}" >>"$temporary/checkpoint/verified-files"
    jq -e 'select(.valid == true) | {header_hash:.hash}' "$1"
  }
  for observer in rpc0 rpc1 local; do
    jq -n --arg stamp "$(date -u +%FT%TZ)" \
      '{valid:true,hash:("A"*64),result:{signed_header:{header:{time:$stamp}}}}' >"$temporary/checkpoint/$observer.json"
  done
  check_checkpoint() {
    recovery_verify_checkpoint chain 100 "$key" "$temporary/checkpoint/rpc0.json" \
      "$temporary/checkpoint/rpc1.json" "$temporary/checkpoint/local.json"
  }
  check_checkpoint | jq -e '.height == "100" and (.activation_authorized == false)' >/dev/null
  [[ "$(cat "$temporary/checkpoint/verified-files")" == $'rpc0.json\nrpc1.json\nlocal.json' ]]
  if recovery_verify_checkpoint chain 100 "$key" "$temporary/checkpoint/rpc0.json" >/dev/null 2>&1; then
    echo 'FAIL accepted only one observer' >&2; exit 1
  fi
  cp "$temporary/checkpoint/local.json" "$temporary/checkpoint/original.json"
  for mutation in '.valid=false' '.hash=("B"*64)' '.result.signed_header.header.time="2000-01-01T00:00:00Z"' \
    '.result.signed_header.header.time="2100-01-01T00:00:00Z"' '.result.signed_header.header.time=null'; do
    jq "$mutation" "$temporary/checkpoint/original.json" >"$temporary/checkpoint/local.json"
    if check_checkpoint >/dev/null 2>&1; then
      echo "FAIL accepted invalid checkpoint: $mutation" >&2; exit 1
    fi
  done
  cp "$temporary/checkpoint/original.json" "$temporary/checkpoint/local.json"
  recovery_verify_commit() {
    jq -e 'select(.valid == true) | {header_hash:.hash}' "$1"
    printf '\n' >>"$1"
  }
  if check_checkpoint >/dev/null 2>&1; then
    echo 'FAIL accepted checkpoint changed during verification' >&2; exit 1
  fi
)
echo 'PASS Bash checkpoint rejects invalid commits, disagreement and stale timestamps'

jq -n '{kind:"gdc-consensus-signer-recovery-checkpoint",chain_id:"chain",height:"100",activation_authorized:false}' >"$temporary/boundary-checkpoint.json"
jq -n '{height:"99",round:"0",step:2}' >"$temporary/archive-state.json"
recovery_write_boundary "$temporary/boundary-checkpoint.json" "$temporary/archive-state.json" chain "$temporary/boundary.json"
jq -e '. == {height:"100",round:"2147483647",step:127,block_id:null}' "$temporary/boundary.json" >/dev/null
if recovery_write_boundary "$temporary/boundary-checkpoint.json" "$temporary/archive-state.json" chain "$temporary/boundary.json" >/dev/null 2>&1; then
  echo 'FAIL overwrote a retained boundary' >&2; exit 1
fi
for height in 100 101 9999999999999999999999 invalid; do
  jq -n --arg height "$height" '{height:$height}' >"$temporary/archive-state.json"
  if recovery_write_boundary "$temporary/boundary-checkpoint.json" "$temporary/archive-state.json" chain "$temporary/invalid-boundary.json" >/dev/null 2>&1; then
    echo 'FAIL lowered or accepted invalid archived signing height' >&2; exit 1
  fi
  [[ ! -e "$temporary/invalid-boundary.json" ]]
done
echo 'PASS recovery boundary is exclusive and strictly above archived signing height'

(
  mkdir "$temporary/preparation" "$temporary/preparation-observation"
  jq -n '{run_id:"recover",spec:{target:{node_name:"node5"},network:{chain_id:"chain"}}}' >"$temporary/preparation/join-profile.v1.json"
  jq -n '{run_id:"recover"}' >"$temporary/preparation/recovery-parent.json"
  jq -n '{node_name:"node5",restore_consensus_pubkey:"target",previous_consensus_pubkey:"source",preserve_p2p_node_id:"p2p"}' >"$temporary/preparation-observation/intent.json"
  jq -n '{height:"100"}' >"$temporary/preparation-observation/checkpoint.json"
  recovery_verify_checkpoint() { [[ "${bad_checkpoint:-false}" == false ]]; }
  recovery_local_request() {
    jq -n --arg key "${observed_key:-source}" '{result:{node_info:{network:"chain",id:"p2p"},sync_info:{catching_up:false},validator_info:{pub_key:{value:$key}}}}'
  }
  ssh() {
    printf '%s\n' "${*: -1}" >>"$temporary/preparation-ssh.log"
    case "${*: -1}" in
      *sha256sum*) printf '%064d  key\n' 0 ;;
      *'sudo bash -c'*) cat >/dev/null; [[ "${stop_failed:-false}" == false ]] ;;
      *'sudo cat'*) jq -n '{kind:"gdc-consensus-recovery-preparation",run_id:"recover",previous_softsign_sha256:("0"*64),consensus_processes_stopped:true,restart_disabled:true,activation_authorized:false}' ;;
      *) return 1 ;;
    esac
  }
  bad_checkpoint=true
  if recovery_prepare_host "$temporary/preparation" "$temporary/preparation-observation" >/dev/null 2>&1; then
    echo 'FAIL prepared Host without checkpoint' >&2; exit 1
  fi
  [[ ! -e "$temporary/preparation-ssh.log" ]]
  bad_checkpoint=false; observed_key=changed
  if recovery_prepare_host "$temporary/preparation" "$temporary/preparation-observation" >/dev/null 2>&1; then
    echo 'FAIL prepared Host with changed consensus identity' >&2; exit 1
  fi
  [[ ! -e "$temporary/preparation-ssh.log" ]]
  observed_key=source; stop_failed=true
  if recovery_prepare_host "$temporary/preparation" "$temporary/preparation-observation" >/dev/null 2>&1; then
    echo 'FAIL accepted failed remote stop' >&2; exit 1
  fi
  [[ ! -e "$temporary/preparation/host-prepared.json" ]]
  stop_failed=false
  recovery_prepare_host "$temporary/preparation" "$temporary/preparation-observation" >/dev/null
  jq -e '.consensus_processes_stopped and (.activation_authorized == false)' "$temporary/preparation/host-prepared.json" >/dev/null
)
echo 'PASS Host preparation fails before mutation on checkpoint or identity mismatch'

(
  mkdir "$temporary/authorize" "$temporary/authorize-observation"
  jq -n '{run_id:"recovery",archive_sha256:"archive"}' >"$temporary/authorize/recovery-parent.json"
  jq -n '{spec:{target:{node_name:"node5"},network:{chain_id:"chain"}}}' >"$temporary/authorize/join-profile.v1.json"
  jq -n '{run_id:"recovery",node_name:"node5",archive_sha256:"archive",exclusive_signer_confirmed:true}' >"$temporary/authorize/owner-authority.json"
  jq -n '{height:"90"}' >"$temporary/authorize/recovery-boundary.json"
  jq -n --arg key "$key" '{kind:"gdc-consensus-containers-recreated",run_id:"recovery",consensus_pubkey:$key,images:{node:"image",tmkms:"image"},activation_authorized:false}' >"$temporary/authorize/host-recreated.json"
  printf '%s\n' https://one.example https://two.example >"$temporary/authorize-observation/rpc-origins.txt"
  fixture_consensus_key="$key"
  recovery_observe_membership() {
    mkdir "$3" || return 1
    jq -n --arg key "$fixture_consensus_key" --argjson jailed "${jailed:-false}" --argjson rebind "${rebind:-false}" \
      '{restore_consensus_pubkey:$key,jailed:$jailed,participant_rebind_required:$rebind}' >"$3/intent.json"
  }
  recovery_verify_commit() { jq '{header_hash:.hash}' "$1"; }
  recovery_request() {
    case "$1" in
      */status) jq -n '{result:{node_info:{network:"chain"},sync_info:{catching_up:false,latest_block_height:"101"}}}' ;;
      */commit*)
        [[ "$1" == */commit?height=100 ]] || return 1
        local hash=A stamp
        [[ "${disagree:-false}" != true || "$1" != https://two.example/* ]] || hash=B
        stamp="$(date -u +%FT%TZ)"
        [[ "${stale:-false}" != true ]] || stamp=2000-01-01T00:00:00Z
        jq -n --arg hash "$hash" --arg stamp "$stamp" '{hash:($hash*64),result:{signed_header:{header:{time:$stamp}}}}' ;;
      */validators*) jq --arg power "${fixture_power:-18}" '.result.validators[0].voting_power=$power' "$temporary/set.json" ;;
      *) return 1 ;;
    esac
  }
  recovery_authorize_activation "$temporary/authorize" "$temporary/authorize-observation" unused "$temporary/authorization-pass"
  jq -e '.activation_authorized == true and .checkpoint_height == "100"' "$temporary/authorization-pass/activation.json" >/dev/null
  fixture_power=0
  recovery_authorize_activation "$temporary/authorize" "$temporary/authorize-observation" unused "$temporary/authorization-pending"
  jq -e '.effective_voting_power == 0 and .validation_pending == true' "$temporary/authorization-pending/activation.json" >/dev/null
  for failure in jailed rebind disagree stale; do
    jailed=false; rebind=false; disagree=false; stale=false; fixture_power=18
    case "$failure" in
      jailed) jailed=true ;; rebind) rebind=true ;; disagree) disagree=true ;; stale) stale=true ;;
    esac
    if recovery_authorize_activation "$temporary/authorize" "$temporary/authorize-observation" unused "$temporary/authorization-$failure" >/dev/null 2>&1; then
      echo "FAIL authorized unsafe activation: $failure" >&2; exit 1
    fi
    [[ ! -s "$temporary/authorization-$failure/activation.json" ]]
  done
  jq '.exclusive_signer_confirmed=false' "$temporary/authorize/owner-authority.json" >"$temporary/authority.tmp"
  mv "$temporary/authority.tmp" "$temporary/authorize/owner-authority.json"
  if recovery_authorize_activation "$temporary/authorize" "$temporary/authorize-observation" unused "$temporary/authorization-no-owner" >/dev/null 2>&1; then
    echo 'FAIL authorized activation without exclusive signer confirmation' >&2; exit 1
  fi
  [[ ! -e "$temporary/authorization-no-owner" ]]
)
echo 'PASS activation rejects unsafe identity/checkpoints; zero power remains validation pending'

(
  mkdir "$temporary/sequence"
  jq -n '{run_id:"recovery",archive_sha256:"archive"}' >"$temporary/sequence/recovery-parent.json"
  jq -n '{spec:{target:{node_name:"node5"}}}' >"$temporary/sequence/join-profile.v1.json"
  jq -n '{run_id:"recovery",archive_sha256:"archive",node_name:"node5",exclusive_signer_confirmed:true}' >"$temporary/sequence/owner-authority.json"
  recovery_stage() {
    printf '%s\n' "$1" >>"$temporary/sequence-calls"
    [[ "$(wc -l <"$temporary/sequence-calls")" != "${fail_at:-0}" ]] || return 1
    printf '{}\n'
  }
  for fail_at in 1 2 3 4 5 6 7 8; do
    : >"$temporary/sequence-calls"
    if recovery_execute "$temporary/sequence" unused unused unused >/dev/null 2>&1; then
      echo "FAIL recovery continued after failed stage $fail_at" >&2; exit 1
    fi
    [[ "$(wc -l <"$temporary/sequence-calls")" -eq "$fail_at" ]]
  done
  fail_at=0
  : >"$temporary/sequence-calls"
  recovery_execute "$temporary/sequence" unused unused unused >/dev/null
  [[ "$(wc -l <"$temporary/sequence-calls")" -eq 8 ]]
)
echo 'PASS recovery controller stops the sequence after every failed stage'

(
  mkdir "$temporary/validation-run"
  recovery_stage() {
    [[ "$1" == recovery_validation_sample ]] || return 1
    local attempt_index height epoch
    attempt_index="${4##*-}"
    case "$attempt_index" in
      1) height=101; epoch=1 ;;
      2) height=101; epoch=1 ;;
      3) height=102; epoch=2 ;;
      4) height=103; epoch=2 ;;
      5) height=104; epoch=2 ;;
      6) height=105; epoch=3 ;;
      *) echo 'FAIL validation did not finish after sufficient evidence' >&2; exit 1 ;;
    esac
    jq -n --arg height "$height" --arg epoch "$epoch" \
      '{height:$height,epoch:$epoch,consensus_pubkey:"fixture",block_hash:"fixture",voting_power:18,signature_verified:true}'
  }
  sleep() { :; }
  recovery_wait_validating "$temporary/validation-run" unused >/dev/null
  jq -e '.verdict == "VALIDATING" and .epoch_transition_verified and
    (.signed_blocks | length) == 5 and
    ([.signed_blocks[] | select(.epoch == "2")] | length) == 3 and
    any(.signed_blocks[]; .epoch == "3")' "$temporary/validation-run/validation/result.json" >/dev/null
)
echo 'PASS VALIDATING counts unique blocks and requires continued signing in a later epoch'

(
  mkdir "$temporary/operator-update" "$temporary/operator-update/observation"
  jq -n '{node_name:"node5",preserve_p2p_node_id:"current-p2p",preserve_warm_address:"current-warm",
    previous_consensus_pubkey:"previous",restore_consensus_pubkey:"restored"}' \
    >"$temporary/operator-update/observation/intent.json"
  jq -n '{node_name:"node5",node_id:"current-p2p",warm_address:"current-warm",warm_pubkey_b64:"current-warm-key",
    consensus_pubkey:"previous"}' >"$temporary/operator-update/identity.json"
  recovery_update_operator_identity "$temporary/operator-update" "$temporary/operator-update/identity.json" \
    "$temporary/operator-update/observation"
  jq -e '.consensus_pubkey == "restored" and .node_id == "current-p2p" and
    .warm_address == "current-warm" and .warm_pubkey_b64 == "current-warm-key"' \
    "$temporary/operator-update/identity.json" >/dev/null
  recovery_update_operator_identity "$temporary/operator-update" "$temporary/operator-update/identity.json" \
    "$temporary/operator-update/observation"
  jq -e '.consensus_pubkey == "previous"' "$temporary/operator-update/operator-identity-before.json" >/dev/null
  for field in node_name node_id warm_address consensus_pubkey; do
    jq --arg field "$field" '.[$field]="conflicting"' "$temporary/operator-update/identity.json" >"$temporary/operator-update/conflict.json"
    before="$(sha256sum "$temporary/operator-update/conflict.json")"
    if recovery_update_operator_identity "$temporary/operator-update" "$temporary/operator-update/conflict.json" \
        "$temporary/operator-update/observation" >/dev/null 2>&1; then
      echo "FAIL replaced conflicting operator identity: $field" >&2; exit 1
    fi
    [[ "$(sha256sum "$temporary/operator-update/conflict.json")" == "$before" ]]
  done
)
echo 'PASS operator identity update preserves warm/P2P identity and the original backup on replay'

mkdir "$temporary/run" "$temporary/observation"
jq -n '{spec:{target:{node_name:"node5",public_host:"node5.example"},network:{chain_id:"chain"}}}' >"$temporary/run/join-profile.v1.json"
jq -n '{node_name:"node5",participant_address:"gonka1fixture",restore_consensus_pubkey:"target",previous_consensus_pubkey:"previous"}' >"$temporary/observation/intent.json"
jq -n '{api:"https://seed.example",rpc:["https://seed.example/rpc"]}' >"$temporary/observation/origins.json"
printf '%s\n' 'synthetic-password' >"$temporary/password"
chmod 600 "$temporary/password"
recovery_request() {
  local key=previous
  [[ ! -f "$temporary/sent" ]] || key=target
  jq -cn --arg key "$key" '{participant:{address:"gonka1fixture",validator_key:$key,inference_url:"https://node5.example"}}'
}
recovery_cli() {
  printf '%s\n' "$*" >>"$temporary/argv"
  local input
  case "$1" in
    keys)
      IFS= read -r input; [[ "$input" == synthetic-password ]] || return 1
      printf '%s\n' gonka1fixture ;;
    tx)
      IFS= read -r input; [[ "$input" == synthetic-password ]] || return 1
      [[ "${simulate_failure:-false}" == false ]] || return 1
      touch "$temporary/sent"
      jq -cn '{code:0,txhash:("A"*64)}' ;;
    query) jq -cn '{code:0,height:"123"}' ;;
    *) return 1 ;;
  esac
}
recovery_reconcile_participant "$temporary/run" "$temporary/observation" "$temporary/operator" "$temporary/password" >"$temporary/rebound.json"
jq -e '.broadcast == true and .height == "123"' "$temporary/rebound.json" >/dev/null
if grep -q synthetic-password "$temporary/argv"; then
  echo 'FAIL password leaked into process arguments' >&2; exit 1
fi
calls="$(wc -l <"$temporary/argv")"
recovery_reconcile_participant "$temporary/run" "$temporary/observation" "$temporary/operator" "$temporary/password" >"$temporary/rebound-again.json"
[[ "$(wc -l <"$temporary/argv")" == "$calls" ]]
jq -e '.broadcast == false' "$temporary/rebound-again.json" >/dev/null
rm "$temporary/sent"
mkdir "$temporary/failed-run"
cp "$temporary/run/join-profile.v1.json" "$temporary/failed-run/join-profile.v1.json"
simulate_failure=true
if recovery_reconcile_participant "$temporary/failed-run" "$temporary/observation" "$temporary/operator" "$temporary/password" >/dev/null 2>&1; then
  echo 'FAIL ambiguous broadcast reported success' >&2; exit 1
fi
[[ -s "$temporary/failed-run/participant-rebind-attempt.json" ]]
calls="$(wc -l <"$temporary/argv")"
if recovery_reconcile_participant "$temporary/failed-run" "$temporary/observation" "$temporary/operator" "$temporary/password" >/dev/null 2>&1; then
  echo 'FAIL unknown broadcast was retried' >&2; exit 1
fi
[[ "$(wc -l <"$temporary/argv")" == "$calls" ]]
echo 'PASS Bash rebind uses stdin, verifies committed readback and never resubmits an ambiguous broadcast'
