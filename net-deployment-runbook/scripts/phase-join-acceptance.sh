#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"
# shellcheck source=join-acceptance-state.sh
source "$(dirname "$0")/join-acceptance-state.sh"
load_project

# This evidence phase is shared by a completed Genesis bootstrap and an
# independent Host join. `node_name` deliberately rejects the Genesis alias
# for the *join action* itself; applying that action-only restriction here
# made a healthy Genesis unable to prove its required PoC/validator gate.
NODE="${1:-}"
topology_contains_node "$NODE" || die "unknown SSH alias: $NODE"
ACCOUNT="$(node_account_file "$NODE")"
IDENTITY="$(node_identity_file "$NODE")"
[[ -s "$ACCOUNT" && -s "$IDENTITY" ]] || die "$NODE has no local public account/identity required for join acceptance"
ADDRESS="$(jq -er .address "$ACCOUNT")"
VALIDATOR_KEY="$(jq -er .consensus_pubkey "$IDENTITY")"
RUNTIME_ID="$(runtime_id_for_participant "$ADDRESS")"

EPOCHS="${GDC_JOIN_EFFECTIVE_EPOCHS:-}"
TIMEOUT="${GDC_JOIN_EFFECTIVE_TIMEOUT_SECONDS:-}"
[[ "$EPOCHS" =~ ^[1-9][0-9]*$ && "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] \
  || die 'release profile must define positive GDC_JOIN_EFFECTIVE_EPOCHS and GDC_JOIN_EFFECTIVE_TIMEOUT_SECONDS'
# An independent participant registered during the current epoch cannot be
# represented in that epoch's already-created group.  Two additional epochs
# cover the registration/ACTIVE transition and the first group that can
# contain its PoC evidence, then the profile's four complete effective epochs
# remain required on top of that. Genesis keeps the canonical four-epoch
# profile window because it exists before the first group is created.
acceptance_epochs="$EPOCHS"
[[ "$NODE" == "$GENESIS_NODE" ]] || acceptance_epochs=$((EPOCHS + 2))
record_phase_profile "join-acceptance-$NODE"
RUN="$GDC_HOME/runs/${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-manual}/join-acceptance-$NODE"
export EVIDENCE_PHASE_NAME="join-acceptance-$NODE"
mkdir -p "$RUN"
# The exit trap is installed before the first public-chain probe. Initialise
# receipt fields so an early transport failure itself remains diagnosable.
GENESIS_HASH=UNAVAILABLE
deadline_epoch=0
poc_accepted_once=false
poc_accepted_epoch=0
poc_participant_weight=0
poc_accepted_weight_sum=0
poc_committed_total=0
poc_distribution_tx_hash=''
poc_distribution_tx_code=-1
poc_distribution_stage=0
late_restored_evidence=false
[[ -s "$RUN/poc-acceptance-observations.json" ]] || printf '[]' >"$RUN/poc-acceptance-observations.json"

LAST_PUBLIC_FETCH_FAILURE=''

fetch_public_json() {
  local label="$1" url="$2" output="$3" stderr http_status rc detail curl_status
  stderr="$(mktemp "$RUN/.curl.XXXXXX")"
  if http_status="$(curl -sS --connect-timeout 5 --max-time 15 -o "$output" -w '%{http_code}' "$url" 2>"$stderr")"; then rc=0; else rc=$?; fi
  if (( rc == 0 )) && [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then rm -f "$stderr"; return 0; fi
  detail="$(tr '\n' ' ' <"$stderr" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  rm -f "$stderr"
  [[ "$http_status" =~ ^[0-9]{3}$ ]] || http_status=0
  curl_status="$(curl_exit_status "$rc")"
  LAST_PUBLIC_FETCH_FAILURE="request=$label url=$url http_status=$http_status curl_exit=$rc curl_status=$curl_status${detail:+ detail=$detail}"
  printf 'WAIT  %s unavailable url=%s http_status=%s curl_exit=%s curl_status=%s%s\n' "$label" "$url" "$http_status" "$rc" "$curl_status" "${detail:+ detail=$detail}"
  return 1
}

# Keep an evidence trail for the stage actually selected by the chain.  A
# participant can be ACTIVE and have a runtime while its DAPI/MLNode follows
# an old stage; accepting only the final epoch-group weight would conceal that
# class of failure (LIFE-012).
capture_poc_stage_trace() {
  local group="$1" epoch="$2" stage artifact_stage commits distributions validations artifact_local artifact_public artifact_public_status artifact_public_stderr artifact_public_rc artifact_public_detail tmp
  stage="$(jq -er '.epoch_group_data.poc_start_block_height | tonumber' <<<"$group")" || return 1
  [[ "$stage" =~ ^[1-9][0-9]*$ ]] || return 1
  artifact_stage=$((stage + EPOCH_LENGTH))

  cp "$RUN/epoch-group.json" "$RUN/canonical-epoch-group-$stage.json"
  fetch_public_json 'PoC commits' "$CHAIN_BASE/chain-api/productscience/inference/inference/all_poc_v2_store_commits/$stage" "$RUN/poc-commits-$stage.json" || printf '{"commits":[]}' >"$RUN/poc-commits-$stage.json"
  fetch_public_json 'PoC weight distributions' "$CHAIN_BASE/chain-api/productscience/inference/inference/all_mlnode_weight_distributions/$stage" "$RUN/poc-distributions-$stage.json" || printf '{"distributions":[]}' >"$RUN/poc-distributions-$stage.json"
  fetch_public_json 'PoC validations' "$CHAIN_BASE/chain-api/productscience/inference/inference/poc_v2_validations_for_stage/$stage" "$RUN/poc-validations-$stage.json" || printf '{"poc_validation":[]}' >"$RUN/poc-validations-$stage.json"

  # An epoch group records the completed PoC stage. DAPI retains the following
  # stage that validators fetch and prunes the completed stage at the boundary.
  artifact_public="https://$(node_public_host "$NODE")/v1/poc/artifacts/state?height=$artifact_stage&model_id=${MODEL_ID//\//%2F}"
  tmp="$(mktemp "$RUN/.poc-artifact-public.tmp.XXXXXX")"
  artifact_public_stderr="$(mktemp "$RUN/.poc-artifact-public.stderr.XXXXXX")"
  if artifact_public_status="$(curl -sS --connect-timeout 5 --max-time 15 -o "$tmp" -w '%{http_code}' "$artifact_public" 2>"$artifact_public_stderr")"; then
    artifact_public_rc=0
  else
    artifact_public_rc=$?
  fi
  if [[ "$artifact_public_status" == 200 ]] \
    && jq -e '(.root_hash | type == "string" and length > 0) and ((.count | tonumber) > 0)' "$tmp" >/dev/null 2>&1; then
    rm -f "$artifact_public_stderr"
    mv "$tmp" "$RUN/poc-artifact-public-$stage.json"
  else
    artifact_public_detail="$(tr '\n' ' ' <"$artifact_public_stderr" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
    if [[ "$artifact_public_status" == 200 && -z "$artifact_public_detail" ]]; then
      artifact_public_detail='artifact root is not populated yet'
    fi
    rm -f "$artifact_public_stderr"
    [[ "$artifact_public_status" =~ ^[0-9]{3}$ ]] || artifact_public_status=0
    printf 'WAIT  public PoC artifact unavailable canonical_stage=%s artifact_stage=%s url=%s http_status=%s curl_exit=%s curl_status=%s%s\n' \
      "$stage" "$artifact_stage" "$artifact_public" "$artifact_public_status" "$artifact_public_rc" "$(curl_exit_status "$artifact_public_rc")" "${artifact_public_detail:+ detail=$artifact_public_detail}"
    jq -n --argjson canonical_stage "$stage" --argjson artifact_stage "$artifact_stage" --argjson http_status "$artifact_public_status" --rawfile response "$tmp" \
      '{unavailable:true,canonical_stage:$canonical_stage,artifact_stage:$artifact_stage,http_status:$http_status,response:$response}' >"$RUN/poc-artifact-public-$stage.json"
    rm -f "$tmp"
  fi
  # The DAPI listens on 9000 inside the node deployment.  The host-local
  # public proxy is the same surface validators use and is exposed on 8000;
  # probing 9000 from the host produces a false unavailable result.
  artifact_local="http://127.0.0.1:8000/v1/poc/artifacts/state?height=$artifact_stage&model_id=${MODEL_ID//\//%2F}"
  ssh -T "$NODE" "curl -fsS --connect-timeout 5 --max-time 15 '$artifact_local'" \
    >"$RUN/poc-artifact-local-$stage.json" 2>/dev/null || printf '{"unavailable":true}' >"$RUN/poc-artifact-local-$stage.json"

  # node is the deployed DAPI/inferenced image. Retain only PoC lifecycle messages for
  # this canonical numeric stage; logs are diagnostic evidence, never a PASS
  # substitute.  The bounded tail avoids copying unrelated operator traffic.
  ssh -T "$NODE" "set -o pipefail; cd /srv/dai/$NODE && docker compose logs --no-color --tail=800 node 2>&1 | grep -E '$stage|poc(StageStartBlockHeight|Height)|PoC|artifact|commit|distribution|validation' | tail -n 240" \
    >"$RUN/dapi-stage-$stage.log" 2>&1 || true
  ssh -T "$NODE" "set -o pipefail; cd /srv/dai/$NODE && docker compose logs --no-color --tail=800 mlnode 2>&1 | grep -E '$stage|poc(StageStartBlockHeight|Height)|PoC|artifact|commit|distribution|validation' | tail -n 240" \
    >"$RUN/mlnode-stage-$stage.log" 2>&1 || true

  commits="$RUN/poc-commits-$stage.json"
  distributions="$RUN/poc-distributions-$stage.json"
  validations="$RUN/poc-validations-$stage.json"
  jq -n --argjson epoch "$epoch" --argjson canonical_poc_start_block_height "$stage" --argjson artifact_stage "$artifact_stage" \
    --arg participant "$ADDRESS" --arg runtime_id "$RUNTIME_ID" \
    --slurpfile commits "$commits" --slurpfile distributions "$distributions" \
    --slurpfile validations "$validations" --slurpfile artifact_local "$RUN/poc-artifact-local-$stage.json" \
    --slurpfile artifact_public "$RUN/poc-artifact-public-$stage.json" '
      def participant_commit:
        $commits[0].commits[]? | select(.participant_address == $participant);
      def participant_distribution:
        $distributions[0].distributions[]? | select(.participant_address == $participant);
      def participant_validations:
        [$validations[0].poc_validation[]?.poc_validation[]?
          | select(.participant_address == $participant)];
      {epoch:$epoch,canonical_poc_start_block_height:$canonical_poc_start_block_height,artifact_stage:$artifact_stage,
       participant_address:$participant,runtime_id:$runtime_id,
       commit:([participant_commit] | first // null),
       distribution:([participant_distribution] | first // null),
       validations:participant_validations,
       artifact_local:$artifact_local[0],artifact_public:$artifact_public[0],
       artifact_public_matches_local:(
         ($artifact_local[0].root_hash? // "") | length > 0 and
         (($artifact_local[0].count? // 0) | tonumber) > 0 and
         ($artifact_local[0].root_hash? == $artifact_public[0].root_hash?) and
         ($artifact_local[0].count? == $artifact_public[0].count?))}
    ' >"$RUN/poc-stage-trace-$stage.json"
  tmp="$(mktemp "$RUN/.poc-stage-traces.tmp.XXXXXX")"
  jq --slurpfile trace "$RUN/poc-stage-trace-$stage.json" \
    'if any(.[]; .canonical_poc_start_block_height == $trace[0].canonical_poc_start_block_height)
     then if $trace[0].artifact_public_matches_local == true
          then [.[] | select(.canonical_poc_start_block_height != $trace[0].canonical_poc_start_block_height)] + $trace
          else .
          end
     else . + $trace
     end' "$RUN/poc-stage-traces.json" \
    >"$tmp"
  mv "$tmp" "$RUN/poc-stage-traces.json"
}
[[ -s "$RUN/poc-stage-traces.json" ]] || printf '[]' >"$RUN/poc-stage-traces.json"

capture_poc_distribution_transactions() {
  local stage="$1" latest_height end_height height tx_b64 tx_hash tx_json tmp status_json block_json status_url block_url tx_url had_fetch_failure=false
  local max_blocks="${GDC_JOIN_TX_TRACE_BLOCKS:-180}"
  POC_DISTRIBUTION_READBACK_FAILURE=''
  [[ "$stage" =~ ^[1-9][0-9]*$ && "$max_blocks" =~ ^[1-9][0-9]*$ ]] || return 1
  # A second capture of the same canonical stage would only duplicate public
  # evidence and unnecessarily load the chain API.
  if [[ -s "$RUN/poc-distribution-transactions-$stage.json" ]] \
    && jq -e --argjson stage "$stage" --arg participant "$ADDRESS" '
      length > 0
      and any(.[]; .tx_code == 0 and .tx_height >= $stage and .scanned_height == .tx_height
        and any(.messages[]?; .creator == $participant))
    ' "$RUN/poc-distribution-transactions-$stage.json" >/dev/null 2>&1; then
    return 0
  fi
  status_url="$CHAIN_BASE/chain-rpc/status"
  status_json="$(mktemp "$RUN/.poc-distribution-status.XXXXXX")"
  if ! fetch_public_json 'canonical PoC distribution index' "$status_url" "$status_json"; then
    POC_DISTRIBUTION_READBACK_FAILURE="$LAST_PUBLIC_FETCH_FAILURE"
    rm -f "$status_json"
    return 1
  fi
  if ! latest_height="$(jq -er '.result.sync_info.latest_block_height | tonumber' "$status_json")"; then
    printf 'WAIT  canonical PoC distribution index is malformed stage=%s url=%s\n' "$stage" "$status_url"
    rm -f "$status_json"
    return 1
  fi
  rm -f "$status_json"
  end_height=$((stage + max_blocks))
  (( latest_height < end_height )) && end_height="$latest_height"
  printf '[]' >"$RUN/poc-distribution-transactions-$stage.json"
  for ((height = stage; height <= end_height; height++)); do
    block_url="$CHAIN_BASE/chain-rpc/block?height=$height"
    block_json="$(mktemp "$RUN/.poc-distribution-block.XXXXXX")"
    if ! fetch_public_json "canonical PoC distribution block stage=$stage height=$height" "$block_url" "$block_json"; then
      [[ -n "$POC_DISTRIBUTION_READBACK_FAILURE" ]] || POC_DISTRIBUTION_READBACK_FAILURE="$LAST_PUBLIC_FETCH_FAILURE"
      had_fetch_failure=true
      rm -f "$block_json"
      continue
    fi
    while IFS= read -r tx_b64; do
      [[ -n "$tx_b64" ]] || continue
      tx_hash="$(printf '%s' "$tx_b64" | base64 -d | sha256sum | awk '{print toupper($1)}')" || continue
      tx_url="$CHAIN_BASE/chain-api/cosmos/tx/v1beta1/txs/$tx_hash"
      tx_json="$(mktemp "$RUN/.poc-distribution-tx.XXXXXX")"
      if ! fetch_public_json "canonical PoC distribution transaction stage=$stage height=$height tx=$tx_hash" "$tx_url" "$tx_json"; then
        [[ -n "$POC_DISTRIBUTION_READBACK_FAILURE" ]] || POC_DISTRIBUTION_READBACK_FAILURE="$LAST_PUBLIC_FETCH_FAILURE"
        had_fetch_failure=true
        rm -f "$tx_json"
        continue
      fi
      jq -e --arg hash "$tx_hash" --argjson expected_height "$height" \
        --arg participant "$ADDRESS" --arg runtime_id "$RUNTIME_ID" --arg model "$MODEL_ID" '
          [.tx.body.messages[]? | .. | objects
           | select(."@type"? == "/inference.inference.MsgMLNodeWeightDistribution")
           | select(.creator == $participant)
           | select(any(.entries[]?; .model_id == $model
             and any(.weights[]?; .node_id == $runtime_id and (.weight | tonumber) > 0)))] as $messages
          | select($messages | length > 0)
          | {tx_hash:$hash,tx_code:(.tx_response.code | tonumber),
             tx_height:(.tx_response.height | tonumber),scanned_height:$expected_height,
             message_type:"/inference.inference.MsgMLNodeWeightDistribution",
             messages:$messages}
        ' "$tx_json" >"$RUN/poc-distribution-transaction-$stage-$tx_hash.json" 2>/dev/null || { rm -f "$tx_json"; continue; }
      rm -f "$tx_json"
      tmp="$(mktemp "$RUN/.poc-distribution-transactions.tmp.XXXXXX")"
      jq --slurpfile transaction "$RUN/poc-distribution-transaction-$stage-$tx_hash.json" \
        '. + $transaction' "$RUN/poc-distribution-transactions-$stage.json" \
        >"$tmp"
      mv "$tmp" "$RUN/poc-distribution-transactions-$stage.json"
    done < <(jq -r '.result.block.data.txs[]?' "$block_json")
    rm -f "$block_json"
  done
  if jq -e --argjson stage "$stage" --arg participant "$ADDRESS" '
    length > 0
    and any(.[]; .tx_code == 0 and .tx_height >= $stage and .scanned_height == .tx_height
      and any(.messages[]?; .creator == $participant))
  ' "$RUN/poc-distribution-transactions-$stage.json" >/dev/null; then
    return 0
  fi

  # A transient failure for an unrelated transaction must not stop this pass
  # before a later matching code=0 distribution can be read.  Retain the
  # first failure only when no successful distribution was found.
  [[ "$had_fetch_failure" == true ]] && return 1

  # A matching transaction can be visible before it is accepted.  Reporting
  # the public transaction result makes the wait actionable instead of
  # incorrectly looking like an unavailable readback.
  POC_DISTRIBUTION_READBACK_FAILURE="$(jq -r --arg participant "$ADDRESS" '
    [.[]
     | select(any(.messages[]?; .creator == $participant))
     | select(.tx_code != 0)
     | "tx_hash=\(.tx_hash) tx_code=\(.tx_code) tx_height=\(.tx_height)"
    ] | last // empty
  ' "$RUN/poc-distribution-transactions-$stage.json")"
  return 1
}

# A transport or parsing failure must still leave an honest, sanitized
# evidence verdict.  Expected negative outcomes below write their own more
# specific receipt before exiting.
on_exit() {
  local rc=$?
  if (( rc != 0 )) && [[ ! -s "$RUN/verdict.md" ]]; then
    if declare -F write_receipt >/dev/null; then
      write_receipt INCONCLUSIVE "join acceptance stopped with exit code $rc"
    else
      jq -n --arg verdict INCONCLUSIVE --arg reason "join acceptance stopped with exit code $rc before receipt initialization" \
        '{schema_version:1,verdict:$verdict,reason:$reason}' >"$RUN/receipt.json"
    fi
    cat >"$RUN/verdict.md" <<EOF
# Host join: INCONCLUSIVE

Join acceptance stopped with exit code $rc before its final verdict. Inspect
the run log and evidence bundle; no successful join is implied.
EOF
  fi
}
trap on_exit EXIT

CHAIN_BASE="https://${GENESIS_PUBLIC_HOST}"
capture_canonical_genesis "$CHAIN_BASE/chain-rpc/genesis" "$RUN/genesis.json" \
  || die 'cannot read canonical public Genesis for join acceptance'
GENESIS_HASH="$(genesis_sha256 "$RUN/genesis.json")"
CHAIN_ID="$(jq -er .chain_id "$RUN/genesis.json")"
write_phase_lineage "$RUN" "$CHAIN_ID" "$GENESIS_HASH"

params_endpoint="$CHAIN_BASE/chain-api/productscience/inference/inference/params"
fetch_public_json 'inference epoch parameters' "$params_endpoint" "$RUN/inference-params.json" \
  || die "cannot read inference epoch parameters from $params_endpoint"
EPOCH_LENGTH="$(jq -er '(.params // .).epoch_params.epoch_length | tonumber' "$RUN/inference-params.json")"
[[ "$EPOCH_LENGTH" =~ ^[1-9][0-9]*$ ]] || die 'inference epoch length is invalid'

group_endpoint="$CHAIN_BASE/chain-api/productscience/inference/inference/current_epoch_group_data"
hardware_endpoint="$CHAIN_BASE/chain-api/productscience/inference/inference/hardware_nodes/$ADDRESS"
participant_endpoint="$CHAIN_BASE/v2/participants/$ADDRESS"
validators_endpoint="$CHAIN_BASE/chain-rpc/validators?per_page=100"
fetch_public_json 'initial epoch group' "$group_endpoint" "$RUN/initial-epoch-group.json" || die "cannot read initial epoch group from $group_endpoint"
initial_group="$(<"$RUN/initial-epoch-group.json")"
current_epoch="$(jq -er '.epoch_group_data.epoch_index | tonumber' <<<"$initial_group")"
read -r initial_epoch deadline_epoch < <(
  join_acceptance_state_initialize "$RUN" "${GDC_RUN_ID:-manual}" "$GENESIS_HASH" "$ADDRESS" "$RUNTIME_ID" "$current_epoch" "$acceptance_epochs"
) || die 'join acceptance state is absent or bound to another Genesis, participant, or runtime'
[[ "$initial_epoch" =~ ^[1-9][0-9]*$ && "$deadline_epoch" =~ ^[1-9][0-9]*$ ]] \
  || die 'join acceptance state is absent or bound to another Genesis, participant, or runtime'
# A resumed process receives a fresh wall-clock allowance only to collect the
# already-bounded chain evidence. Its immutable epoch deadline never moves.
deadline_seconds=$((SECONDS + TIMEOUT))

if strongest_observed="$(join_acceptance_state_restore_strongest "$RUN" 2>/dev/null || true)"; then
  if [[ -n "$strongest_observed" ]]; then
    poc_accepted_once=true
    poc_accepted_epoch="$(jq -er '.epoch | tonumber' <<<"$strongest_observed")"
    poc_participant_weight="$(jq -er '.participant_weight | tonumber' <<<"$strongest_observed")"
    poc_accepted_weight_sum="$(jq -er '.accepted_weight_sum | tonumber' <<<"$strongest_observed")"
    poc_committed_total="$(jq -er '.committed_total | tonumber' <<<"$strongest_observed")"
    join_acceptance_state_epoch_within_deadline "$poc_accepted_epoch" "$deadline_epoch" \
      || late_restored_evidence=true
  fi
fi
if distribution_evidence="$(join_acceptance_state_restore_distribution "$RUN" 2>/dev/null || true)"; then
  if [[ -n "$distribution_evidence" ]]; then
    poc_distribution_stage="$(jq -er '.stage | tonumber' <<<"$distribution_evidence")"
    poc_distribution_tx_hash="$(jq -er .tx_hash <<<"$distribution_evidence")"
    poc_distribution_tx_code="$(jq -er '.tx_code | tonumber' <<<"$distribution_evidence")"
  fi
fi

write_receipt() {
  local verdict="$1" reason="$2"
  jq -n \
    --arg verdict "$verdict" --arg reason "$reason" --arg run_id "${GDC_RUN_ID:-manual}" \
    --arg chain_id "$CHAIN_ID" --arg genesis_sha256 "$GENESIS_HASH" \
    --arg participant_address "$ADDRESS" --arg validator_key "$VALIDATOR_KEY" \
    --arg runtime_id "$RUNTIME_ID" --arg public_host "$(node_public_host "$NODE")" \
    --arg runbook_commit "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || printf UNAVAILABLE)" \
    --arg profile_hash "$(profile_hash)" --arg operator_mode "independent-host" \
    --argjson deadline_epoch "$deadline_epoch" \
    --argjson poc_accepted_once "$poc_accepted_once" --argjson poc_accepted_epoch "$poc_accepted_epoch" \
    --argjson poc_participant_weight "$poc_participant_weight" --argjson poc_accepted_weight_sum "$poc_accepted_weight_sum" --argjson poc_committed_total "$poc_committed_total" \
    --arg poc_distribution_tx_hash "$poc_distribution_tx_hash" --argjson poc_distribution_tx_code "$poc_distribution_tx_code" \
    '{schema_version:1,verdict:$verdict,reason:$reason,run_id:$run_id,chain_id:$chain_id,genesis_sha256:$genesis_sha256,participant_address:$participant_address,validator_key:$validator_key,runtime_id:$runtime_id,public_host:$public_host,runbook_commit:$runbook_commit,profile_hash:$profile_hash,operator_mode:$operator_mode,deadline_epoch:$deadline_epoch,poc_accepted_once:$poc_accepted_once,poc_accepted_epoch:$poc_accepted_epoch,poc_participant_weight:$poc_participant_weight,poc_accepted_weight_sum:$poc_accepted_weight_sum,poc_committed_total:$poc_committed_total,poc_distribution_tx_hash:$poc_distribution_tx_hash,poc_distribution_tx_code:$poc_distribution_tx_code}' \
    >"$RUN/receipt.json"
}

inconclusive() {
  local reason="$1"
  write_receipt INCONCLUSIVE "$reason"
  cat >"$RUN/verdict.md" <<EOF
# Host join: INCONCLUSIVE

$NODE reached PARTICIPANT_ACTIVE but did not prove every JOIN_PASS state before
epoch $deadline_epoch: $reason

Preserve the evidence bundle and use a separately validated procedure for any
subsequent diagnosis or recovery. The existing account, consensus identity and
runtime identity are retained; no successful join is implied.
EOF
  printf 'INCONCLUSIVE %s; evidence: %s\n' "$reason" "$RUN" >&2
  exit 2
}

fail() {
  local reason="$1"
  write_receipt FAIL "$reason"
  cat >"$RUN/verdict.md" <<EOF
# Host join: FAIL

$NODE violated a required post-ACTIVE join invariant: $reason

The existing account and identity are retained for diagnosis, but this run
must not be treated as a successful join.
EOF
  printf 'FAIL %s; evidence: %s\n' "$reason" "$RUN" >&2
  exit 1
}

blocked() {
  local reason="$1"
  write_receipt BLOCKED "$reason"
  cat >"$RUN/verdict.md" <<EOF
# Host join: BLOCKED

$NODE cannot complete the required join proof: $reason

Preserve this evidence and follow a separately validated procedure after the
named safe precondition is available. The existing account and identity are
retained; no successful join is implied.
EOF
  printf 'BLOCKED %s; evidence: %s\n' "$reason" "$RUN" >&2
  exit 3
}

[[ "$late_restored_evidence" == false ]] \
  || inconclusive "stored positive PoC evidence is later than immutable deadline_epoch=$deadline_epoch"

step "Wait for $NODE PoC eligibility and effective validator membership through epoch $deadline_epoch"
while (( SECONDS < deadline_seconds )); do
  participant=''
  group=''
  hardware=''
  if fetch_public_json 'participant state' "$participant_endpoint" "$RUN/probe-participant.json"; then
    participant="$(<"$RUN/probe-participant.json")"
  fi
  if fetch_public_json 'current epoch group' "$group_endpoint" "$RUN/probe-epoch-group.json"; then
    group="$(<"$RUN/probe-epoch-group.json")"
  fi
  if fetch_public_json 'participant hardware nodes' "$hardware_endpoint" "$RUN/probe-hardware-nodes.json"; then
    hardware="$(<"$RUN/probe-hardware-nodes.json")"
  fi
  validators=''
  for _ in 1 2 3 4; do
    if fetch_public_json 'consensus validator set' "$validators_endpoint" "$RUN/probe-validators.json"; then
      validators="$(<"$RUN/probe-validators.json")"
    else
      validators=''
    fi
    if jq -e '.result.validators | type == "array"' <<<"$validators" >/dev/null 2>&1; then
      break
    fi
    validators=''
    sleep 2
  done
  epoch="$(jq -r '.epoch_group_data.epoch_index // empty' <<<"$group" 2>/dev/null || true)"
  [[ "$epoch" =~ ^[0-9]+$ ]] || { printf 'WAIT  join acceptance cannot read epoch state from url=%s; retrying\n' "$group_endpoint"; sleep 5; continue; }
  join_acceptance_state_epoch_within_deadline "$epoch" "$deadline_epoch" \
    || inconclusive "current epoch=$epoch is later than immutable deadline_epoch=$deadline_epoch"
  if [[ -z "$validators" ]]; then
    printf 'WAIT  validator readback is temporarily unavailable\n'
    sleep 5
    continue
  fi
  printf '%s\n' "$participant" >"$RUN/participant.json"
  printf '%s\n' "$group" >"$RUN/epoch-group.json"
  printf '%s\n' "$hardware" >"$RUN/hardware-nodes.json"
  printf '%s\n' "$validators" >"$RUN/validators.json"
  capture_poc_stage_trace "$group" "$epoch" \
    || fail 'cannot capture the canonical PoC-stage trace required for join diagnosis'

  participant_active=false
  if ! jq -e '.participant.status != null' "$RUN/participant.json" >/dev/null 2>&1; then
    printf 'WAIT  participant state endpoint is temporarily unavailable\n'
    sleep 5
    continue
  fi
  jq -e '.participant.status == "ACTIVE" or .participant.status == "PARTICIPANT_STATUS_ACTIVE" or .participant.status == "1" or .participant.status == 1' \
    "$RUN/participant.json" >/dev/null 2>&1 && participant_active=true
  runtime_ready=false
  jq -e --arg runtime_id "$RUNTIME_ID" --arg model "$MODEL_ID" '
    .nodes.hardware_nodes
    | any(.[]; .local_id == $runtime_id and (.models | index($model) != null) and (.status == "INFERENCE" or .status == "POC"))
  ' "$RUN/hardware-nodes.json" >/dev/null 2>&1 && runtime_ready=true
  weight_evidence="$RUN/validation-weight-evidence.json"
  "$ROOT/scripts/check-validation-weight-evidence.sh" "$RUN/epoch-group.json" "$ADDRESS" >"$weight_evidence" \
    || fail 'validation-weight evidence is malformed or cannot be reconciled'
  distribution_integrity="$(jq -r .distribution_integrity "$weight_evidence")"
  participant_weight="$(jq -er '.participant_weight | tonumber' "$weight_evidence")"
  accepted_weight_sum="$(jq -er '.accepted_weight_sum | tonumber' "$weight_evidence")"
  committed_total="$(jq -er '.committed_total | tonumber' "$weight_evidence")"
  observation_tmp="$(mktemp "$RUN/.poc-acceptance-observations.tmp.XXXXXX")"
  jq --argjson epoch "$epoch" --argjson canonical_poc_start_block_height "$(jq -er '.epoch_group_data.poc_start_block_height | tonumber' "$RUN/epoch-group.json")" --slurpfile weight "$weight_evidence" \
    '. + [{epoch:$epoch,canonical_poc_start_block_height:$canonical_poc_start_block_height,weight_evidence:$weight[0]}]' "$RUN/poc-acceptance-observations.json" \
    >"$observation_tmp"
  mv "$observation_tmp" "$RUN/poc-acceptance-observations.json"
  if [[ "$distribution_integrity" != true && "$accepted_weight_sum" -gt 0 ]]; then
    fail "validation-weight distribution is rejected (accepted_sum=$accepted_weight_sum committed_total=$committed_total participant_weight=$participant_weight)"
  fi
  poc_accepted=false
  jq -e '.participant_eligible == true' "$weight_evidence" >/dev/null && poc_accepted=true
  if [[ "$poc_accepted" == true ]]; then
    poc_accepted_once=true
    poc_accepted_epoch="$epoch"
    poc_participant_weight="$participant_weight"
    poc_accepted_weight_sum="$accepted_weight_sum"
    poc_committed_total="$committed_total"
    join_acceptance_state_record_strongest "$RUN" "$epoch" "$participant_weight" "$accepted_weight_sum" "$committed_total"
    canonical_stage="$(jq -er '.epoch_group_data.poc_start_block_height | tonumber' "$RUN/epoch-group.json")"
    if [[ -z "$poc_distribution_tx_hash" ]]; then
      distribution_captured=false
      for _ in $(seq 1 "${GDC_JOIN_TX_TRACE_RETRIES:-12}"); do
        if capture_poc_distribution_transactions "$canonical_stage"; then
          distribution_captured=true
          break
        fi
        rm -f "$RUN/poc-distribution-transactions-$canonical_stage.json"
        printf 'WAIT  canonical PoC distribution readback unavailable canonical_stage=%s%s\n' \
          "$canonical_stage" "${POC_DISTRIBUTION_READBACK_FAILURE:+ $POC_DISTRIBUTION_READBACK_FAILURE}"
        sleep 5
      done
      if [[ "$distribution_captured" == true ]]; then
        poc_distribution_stage="$canonical_stage"
        poc_distribution_tx_hash="$(jq -er '[.[] | select(.tx_code == 0)] | last.tx_hash' "$RUN/poc-distribution-transactions-$canonical_stage.json")"
        poc_distribution_tx_code="$(jq -er '[.[] | select(.tx_code == 0)] | last.tx_code | tonumber' "$RUN/poc-distribution-transactions-$canonical_stage.json")"
        join_acceptance_state_record_distribution "$RUN" "$poc_distribution_stage" "$poc_distribution_tx_hash" "$poc_distribution_tx_code"
      fi
    fi
  fi
  validator_effective=false
  jq -e --arg key "$VALIDATOR_KEY" '
    .result.validators
    | any(.[]; .pub_key.value == $key and (.voting_power | tonumber) > 0)
  ' "$RUN/validators.json" >/dev/null 2>&1 && validator_effective=true

  [[ "$participant_active" == true ]] || fail 'participant is no longer ACTIVE'
  if [[ "$poc_accepted_once" == true && "$runtime_ready" == true ]]; then
    record_join_state "$NODE" POC_ACCEPTED "$ADDRESS"
  fi
  if [[ "$validator_effective" == true ]]; then
    record_join_state "$NODE" VALIDATOR_EFFECTIVE "$ADDRESS"
  fi
  # Requiring the deadline epoch even when all conditions appear early proves
  # the documented six-epoch transition and evidence window after ACTIVE.
  if (( epoch >= deadline_epoch )) \
    && [[ "$poc_accepted_once" == true && "$runtime_ready" == true && "$validator_effective" == true ]]; then
    break
  fi
  if (( epoch >= deadline_epoch )); then
    deadline_detail=''
    if [[ "$poc_accepted_once" != true ]]; then
      # The current group has only just begun.  Its predecessor is the last
      # completed stage and can already contain an on-chain rejection that
      # explains why this participant never received a positive weight.
      canonical_stage="$(jq -er '.epoch_group_data.poc_start_block_height | tonumber' "$RUN/epoch-group.json")"
      previous_stage=$((canonical_stage - EPOCH_LENGTH))
      if (( previous_stage > 0 )); then
        capture_poc_distribution_transactions "$previous_stage" || true
        deadline_detail="$POC_DISTRIBUTION_READBACK_FAILURE"
      fi
    fi
    inconclusive "eligibility deadline reached (runtime=$runtime_ready poc_accepted_once=$poc_accepted_once validator_effective=$validator_effective)${deadline_detail:+ $deadline_detail}"
  fi
  if [[ "$poc_accepted_once" == true && "$runtime_ready" == true && "$validator_effective" == true ]]; then
    printf 'WAIT  join evidence is positive at epoch=%s/%s; retaining it through the stability window (remaining_epochs=%s participant_weight=%s accepted_sum=%s committed_total=%s)\n' \
      "$epoch" "$deadline_epoch" "$((deadline_epoch - epoch))" "$participant_weight" "$accepted_weight_sum" "$committed_total"
  else
    printf 'WAIT  join state epoch=%s/%s runtime=%s poc_accepted_once=%s validator_effective=%s participant_weight=%s accepted_sum=%s committed_total=%s\n' \
      "$epoch" "$deadline_epoch" "$runtime_ready" "$poc_accepted_once" "$validator_effective" \
      "$participant_weight" "$accepted_weight_sum" "$committed_total"
  fi
  sleep 5
done
(( SECONDS < deadline_seconds )) || inconclusive 'wall-clock deadline reached before eligibility evidence'
[[ -n "$poc_distribution_tx_hash" && "$poc_distribution_tx_code" == 0 ]] \
  || inconclusive 'positive accepted PoC weight was observed but no canonical code=0 distribution transaction became readable before the eligibility deadline'

KEY_FILE="$SECRETS/gateway.join-client-key"
[[ -f "$KEY_FILE" ]] \
  || blocked 'the verified public bootstrap did not provide the scoped gateway client credential required for the final authenticated gateway regression'
[[ "$(stat -c %a "$KEY_FILE")" == 600 ]] \
  || blocked 'the runbook-managed scoped gateway client credential must have mode 0600'
case "${KEY_FILE##*/}" in
  gateway.admin-key|gateway.client-keys|gateway.telegram-client-key|operator.keyring|*.keyring)
    blocked 'the runbook-managed gateway credential must be a separately scoped join client credential, not an administrative or consumer credential'
    ;;
esac
CLIENT_KEY="$(cut -d, -f1 <"$KEY_FILE")"
[[ -n "$CLIENT_KEY" ]] || blocked 'the runbook-managed scoped gateway client credential is empty'
[[ "$CLIENT_KEY" != sk-admin-* ]] \
  || blocked 'the runbook-managed scoped gateway client credential is administrative, not a client credential'
inference_timeout="${GDC_JOIN_INFERENCE_TIMEOUT_SECONDS:-900}"
[[ "$inference_timeout" =~ ^[1-9][0-9]*$ ]] \
  || fail 'GDC_JOIN_INFERENCE_TIMEOUT_SECONDS must be a positive integer'
step 'Run one authenticated gateway regression (routing through the new Host is not required)'
if ! "$ROOT/04-ops/test-inference-until-ready.sh" \
  "https://$API_HOST" "$CLIENT_KEY" "$RUN/gateway-regression" \
  "$RUN/gateway-regression/completion.json" "$inference_timeout"; then
  gateway_reason="$(jq -r '.reason // "evidence_unavailable"' "$RUN/gateway-regression/inference-verdict.json" 2>/dev/null || printf 'evidence_unavailable')"
  inconclusive "authenticated gateway regression did not complete: $gateway_reason"
fi

record_join_state "$NODE" COMPLETE "$ADDRESS"
write_receipt PASS 'active participant, exact chain runtime, positive accepted PoC weight in the bounded window, effective validator, and authenticated gateway regression proved'
cat >"$RUN/verdict.md" <<EOF
# Host join: PASS

- participant: $ADDRESS ACTIVE;
- runtime: $RUNTIME_ID is chain-recorded;
- PoC: positive accepted validation weight observed in epoch $poc_accepted_epoch with participant weight $poc_participant_weight and accepted sum $poc_accepted_weight_sum matching committed total $poc_committed_total; distribution transaction $poc_distribution_tx_hash committed with chain code $poc_distribution_tx_code;
- validator: $VALIDATOR_KEY has positive live consensus voting power;
- gateway: authenticated regression succeeded.
EOF
printf 'PASS %s JOIN_PASS evidence: %s\n' "$NODE" "$RUN"
