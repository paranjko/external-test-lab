#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
NODE="$(node_name "${1:-}")"
[[ "${GDC_JOIN_ROLE_INPUT:-false}" == true ]] || die 'JOIN requires a generated one-host role input'
[[ -r "${GDC_JOIN_BOOTSTRAP_FILE:-}" ]] || die 'JOIN role input lacks a validated bootstrap file'
[[ "${GDC_JOIN_BOOTSTRAP_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || die 'JOIN role input lacks a valid bootstrap digest'
[[ "${GDC_JOIN_BOOTSTRAP_SCHEMA:-}" == https://gonka-dev.net/v1.bootstrap.schema.json ]] || die 'JOIN role input has an unsupported bootstrap schema'
step 'Stage validated one-file network bootstrap before Host preparation'
"$ROOT/scripts/stage-network-bootstrap.sh" --bootstrap-file "$GDC_JOIN_BOOTSTRAP_FILE" --genesis-dir "$GENESIS" --state-dir "$STATE" --secrets-dir "$SECRETS"
record_phase_profile "join-${NODE}"
RUN="$GDC_HOME/runs/${GDC_RUN_ID:-manual}/join-$NODE"
export EVIDENCE_PHASE_NAME="join-$NODE"
mkdir -p "$RUN"
install_evidence_exit_trap 'Host JOIN'
JOIN_RECEIPT_DIR="$RUN/receipts"
JOIN_OBSERVATION="${GDC_JOIN_OBSERVATION:-$STATE/network-observation.v1.json}"
[[ -r "${GDC_JOIN_PROFILE:-}" && -r "$JOIN_OBSERVATION" ]] \
  || die 'JOIN lacks a generated profile or observed network required for transition receipts'
join_profile_sha256="$(sha256sum "$GDC_JOIN_PROFILE" | awk '{print $1}')"
join_observation_sha256="$(sha256sum "$JOIN_OBSERVATION" | awk '{print $1}')"
join_operation=new
[[ -n "${GDC_RESTORE_VALIDATOR_BACKUP_ARCHIVE:-}" ]] && join_operation=restore

# The initial lineage decision is intentionally made before any Host mutation,
# but host preparation, model qualification and image installation can take
# longer than its short trust TTL. Refresh only the state-sync decision after
# that work completes and immediately before the signerless canary consumes
# it. The immutable Join Profile and network observation stay unchanged.
refresh_lineage_for_canary() {
  local receipt="$STATE/lineage-preflight.json" env="$STATE/lineage-preflight.env"
  local -a args=(--bootstrap-file "$GDC_JOIN_BOOTSTRAP_FILE" --observation "$JOIN_OBSERVATION" --receipt "$receipt" --env "$env")
  [[ -z "${GDC_JOIN_OPERATOR_SOURCE_RPC:-}" ]] || args+=(--source-rpc "$GDC_JOIN_OPERATOR_SOURCE_RPC")
  step "Refresh lineage trust immediately before signerless canary for $NODE"
  GDC_JOIN_LINEAGE_FAILURE_FILE="$RUN/lineage-preflight-canary.failure"
  export GDC_JOIN_LINEAGE_FAILURE_FILE
  rm -f "$GDC_JOIN_LINEAGE_FAILURE_FILE"
  "$ROOT/scripts/preflight-join-lineage.sh" "${args[@]}"
  # The preflight writes this environment atomically after binding both RPC
  # observations, P2P providers and the new trust tuple.
  # shellcheck disable=SC1090
  source "$env"
  export GDC_JOIN_BOOTSTRAP_MODE GDC_JOIN_TRUST_HEIGHT GDC_JOIN_TRUST_HASH GDC_JOIN_SNAPSHOT_PEERS
  export GDC_JOIN_RPC_SERVER_1 GDC_JOIN_RPC_SERVER_2 GDC_JOIN_TRUSTED_BLOCK_PERIOD GDC_JOIN_LINEAGE_RECEIPT
  export GDC_JOIN_GATEWAY_ADMISSION_PROTOCOLS_JSON
  GDC_JOIN_LINEAGE_RECEIPT_SHA256="$(sha256sum "$GDC_JOIN_LINEAGE_RECEIPT" | awk '{print $1}')"
  export GDC_JOIN_LINEAGE_RECEIPT_SHA256
  install -m 0600 "$receipt" "$RUN/lineage-preflight-canary.v1.json"
  install -m 0600 "$env" "$RUN/lineage-preflight-canary.env"
}

record_join_transition() {
  local state="$1" signer_ever_started="${2:-false}" input participant consensus p2p warm evidence
  local outcome=in_progress resume_policy=resume_same_run
  [[ "$state" != REFUSED ]] || { outcome=refused; resume_policy=new_profile; }
  [[ "$signer_ever_started" == true || "$signer_ever_started" == false ]] \
    || die 'invalid JOIN transition signer state'
  input="$(mktemp "$RUN/.join-transition.XXXXXX")"
  participant="${ADDRESS:-}"; consensus=''; p2p=''; warm=''
  if [[ -r "${IDENTITY:-}" ]]; then
    consensus="$(jq -r '.consensus_pubkey // empty' "$IDENTITY")"
    p2p="$(jq -r '.node_id // empty' "$IDENTITY")"
    warm="$(jq -r '.warm_address // empty' "$IDENTITY")"
  fi
  evidence="$(jq -cn --arg profile "$join_profile_sha256" --arg observation "$join_observation_sha256" '[{kind:"join_profile",sha256:$profile},{kind:"network_observation",sha256:$observation}]')"
  if [[ "$join_operation" == restore && -r "$RUN/restore-tmkms-signing-state.json" ]]; then
    evidence="$(jq -c --arg sha "$(sha256sum "$RUN/restore-tmkms-signing-state.json" | awk '{print $1}')" '. + [{kind:"restore_tmkms_state",sha256:$sha}]' <<<"$evidence")"
  fi
  if [[ "$state" == SIGNER_FENCE_VERIFIED ]]; then
    [[ -r "$RUN/signer-fence-receipt.v1.json" ]] || die 'JOIN signer fence transition lacks its verified receipt'
    evidence="$(jq -c --arg sha "$(sha256sum "$RUN/signer-fence-receipt.v1.json" | awk '{print $1}')" '. + [{kind:"signer_fence",sha256:$sha}]' <<<"$evidence")"
    if [[ "$join_operation" == restore ]]; then
      evidence="$(jq -c --arg sha "$(sha256sum "$RUN/same-host-reset-before-enable.json" | awk '{print $1}')" '. + [{kind:"same_host_reset",sha256:$sha}]' <<<"$evidence")"
    fi
  fi
  jq -cn \
    --arg run_id "${GDC_RUN_ID:-manual}" --arg operation "$join_operation" --arg node "$NODE" --arg state "$state" \
    --arg profile "$join_profile_sha256" --arg observation "$join_observation_sha256" --arg generation "${GDC_RUN_ID:-manual}" \
    --arg participant "$participant" --arg consensus "$consensus" --arg p2p "$p2p" --arg warm "$warm" \
    --argjson signer_ever_started "$signer_ever_started" --argjson evidence "$evidence" \
    --arg outcome "$outcome" --arg resume_policy "$resume_policy" \
    '{schema_version:2,kind:"gdc-host-join-receipt",run_id:$run_id,operation:$operation,node_name:$node,state:$state,join_profile_sha256:$profile,network_observation_sha256:$observation,generation_id:$generation,identity_fingerprints:{participant_address:$participant,consensus_pubkey:$consensus,p2p_node_id:$p2p,warm_address:$warm},signer_ever_started:$signer_ever_started,tmkms_state:{height:0,round:0,step:0,block_id:""},evidence:$evidence,outcome:$outcome,resume_policy:$resume_policy}' >"$input"
  "$ROOT/scripts/record-join-receipt.sh" --receipt-dir "$JOIN_RECEIPT_DIR" --input "$input" >/dev/null
  rm -f "$input"
}
record_restore_fence_refusal() {
  local input
  [[ -n "${GDC_JOIN_RESULT_OUTPUT:-}" ]] || return 0
  input="$(mktemp "$RUN/.restore-fence-result.XXXXXX")"
  chmod 600 "$input"
  jq -cn --arg profile "$join_profile_sha256" \
    '{schema_version:1,kind:"gdc-host-join-result",outcome:"manual_recovery_required",phase:"signer",category:"signer",reason:"old_signer_fence_unprovable",exit_code:1,mutation:"canonical_signer_off",signer_state:"disabled",resume:"automatic_retry_forbidden",join_profile_sha256:$profile,evidence:[]}' >"$input"
  "$ROOT/scripts/record-join-result.sh" --output "$GDC_JOIN_RESULT_OUTPUT" --input "$input" >/dev/null
  rm -f "$input"
}
record_signer_activation_guard() {
  local input
  [[ -n "${GDC_JOIN_RESULT_OUTPUT:-}" ]] || return 0
  input="$(mktemp "$RUN/.signer-activation-result.XXXXXX")"
  chmod 600 "$input"
  jq -cn --arg profile "$join_profile_sha256" \
    '{schema_version:1,kind:"gdc-host-join-result",outcome:"manual_recovery_required",phase:"signer",category:"signer",reason:"signer_activation_readback_required",exit_code:1,mutation:"signer_may_be_on",signer_state:"unknown",resume:"automatic_retry_forbidden",join_profile_sha256:$profile,evidence:[]}' >"$input"
  "$ROOT/scripts/record-join-result.sh" --output "$GDC_JOIN_RESULT_OUTPUT" --input "$input" >/dev/null
  rm -f "$input"
}
# A stop before the first Host change is a refusal, not a failure. Record it
# as one: a REFUSED receipt closes the chain, the terminal result carries
# mutation=none so the next invocation may classify the Host afresh, and the
# typed envelope states the prerequisite instead of the launcher's
# conservative signer_may_be_on fallback. The verdict keeps the evidence exit
# trap from replacing that envelope with the generic adapter.
refuse_before_mutation() {
  local reason="$1" summary="$2" message="$3" result_category envelope_category resume decision token input
  case "$reason" in
    partial_identity|identity_conflict)
      result_category=identity envelope_category=identity resume=manual_recovery decision=manual_action_required token=none ;;
    host_unreachable)
      result_category=host envelope_category=network resume=new_profile decision=safe token=join-repeat ;;
    *) die "unsupported Host JOIN refusal reason: $reason" ;;
  esac
  record_join_transition REFUSED
  # The writers below fail closed explicitly: a refusal that cannot retain
  # its evidence must not leave a half-written record for the launcher.
  "$ROOT/scripts/diagnostic-envelope.sh" write "$RUN/diagnostic-envelope.v1.json" \
    join "join-$NODE" classification refused "$envelope_category" classify-join-state 1 "$decision" "$token" "$summary" \
    || die 'Host JOIN refusal could not retain its diagnostic envelope'
  if [[ -n "${GDC_JOIN_RESULT_OUTPUT:-}" ]]; then
    input="$(mktemp "$RUN/.refusal-result.XXXXXX")"
    chmod 600 "$input"
    jq -cn --arg reason "$reason" --arg category "$result_category" --arg resume "$resume" --arg profile "$join_profile_sha256" \
      '{schema_version:1,kind:"gdc-host-join-result",outcome:"refused",phase:"identity",category:$category,reason:$reason,exit_code:1,mutation:"none",signer_state:"absent",resume:$resume,join_profile_sha256:$profile,evidence:[]}' >"$input"
    "$ROOT/scripts/record-join-result.sh" --output "$GDC_JOIN_RESULT_OUTPUT" --input "$input" >/dev/null \
      || { rm -f "$input"; die 'Host JOIN refusal could not retain its terminal result'; }
    rm -f "$input"
  fi
  printf '# Host JOIN: REFUSED\n\n%s\n' "$summary" >"$RUN/verdict.md"
  die "$message"
}
record_join_transition RUN_CREATED
record_join_state "$NODE" BOOTSTRAP_IMPORTED
record_join_transition BOOTSTRAP_VERIFIED
record_join_transition NETWORK_OBSERVED
record_join_transition JOIN_PROFILE_READY
ML_TARGET="$(node_ml_host "$NODE" || printf '%s' "$NODE")"
URL="$(node_url "$NODE")"
PUBLIC_HOST="${URL#https://}"
getent ahostsv4 "$PUBLIC_HOST" | grep -q . || die "$PUBLIC_HOST does not resolve to IPv4"
ACCOUNT="$ACCOUNTS/$NODE-cold.json"
IDENTITY="$IDENTITIES/$NODE.json"
JOIN_CLASSIFICATION="$("$ROOT/scripts/classify-join-state.sh" "$IDENTITY" "$ACCOUNT" "$STATE/joined/$NODE" "${GDC_RESTORE_VALIDATOR_BACKUP_ARCHIVE:-}")"
JOIN_CLASS="$(jq -er .classification <<<"$JOIN_CLASSIFICATION")"
join_local_state="$(jq -r '"identity record \(if .identity_present then "present" else "absent" end), cold account \(if .account_present then "present" else "absent" end), joined marker \(if .joined_present then "present" else "absent" end)"' <<<"$JOIN_CLASSIFICATION")"
case "$JOIN_CLASS" in
  new|restore_empty)
    printf 'READY Host JOIN classification=%s before mutation\n' "$JOIN_CLASS"
    ;;
  running_matched)
    printf 'READY Host JOIN classification=running_matched; preserving existing local identity for chain readback\n'
    ;;
  partial_identity)
    # Refused below, after the read-only Host identity preflight, so the
    # refusal can state whether the Host still holds a validator identity.
    ;;
  *)
    die 'Host JOIN classification is unsupported or ambiguous; refuse mutation'
    ;;
esac
# Do not allow a first-time local state to overwrite, adopt, or obscure an
# already deployed validator. This is a read-only SSH preflight; the fuller
# PR #51 backup verifier remains authoritative when --restore is supplied.
remote_identity_state=absent
if ssh -T "$NODE" "test -s '/srv/dai/identity/$NODE/p2p/node_key.json' && test -d '/srv/dai/identity/$NODE/warm/keyring-file' && test -d '/srv/dai/signer/$NODE/tmkms'"; then
  remote_identity_state=present
else
  remote_identity_rc=$?
  if (( remote_identity_rc == 255 )); then
    refuse_before_mutation host_unreachable \
      'Host JOIN stopped before any change: the remote identity preflight could not open an SSH session to the Host. Repeat the same command once the Host is reachable.' \
      'Host JOIN classification=unreachable; remote identity preflight could not establish an SSH session'
  fi
fi
if [[ "$remote_identity_state" == present && "$JOIN_CLASS" == new && -z "${GDC_RESTORE_VALIDATOR_BACKUP_ARCHIVE:-}" ]]; then
  refuse_before_mutation identity_conflict \
    'Host JOIN stopped before any change: the Host holds a validator identity that the operator state does not know. Restore it from the matching validator archive or follow the documented recovery path.' \
    'Host JOIN classification=identity_conflict; a remote validator identity exists without matching local operator state'
fi
if [[ "$JOIN_CLASS" == partial_identity ]]; then
  if [[ "$remote_identity_state" == present ]]; then
    refuse_before_mutation partial_identity \
      "Host JOIN stopped before any change: $join_local_state; the Host holds a validator identity. Restore from the matching archive or follow the documented recovery path." \
      'Host JOIN classification=partial_identity; remote identity cannot be adopted from incomplete local state'
  else
    refuse_before_mutation partial_identity \
      "Host JOIN stopped before any change: $join_local_state; the Host holds no validator identity. Resolve the incomplete operator state through the documented recovery path." \
      'Host JOIN classification=partial_identity; refuse mutation until the incomplete local identity is resolved through the documented recovery path'
  fi
fi
record_join_transition TARGET_CLASSIFIED
[[ -s "$GENESIS/genesis.json" && -s "$GENESIS/genesis-seeds.txt" ]] || die 'run genesis first'
GENESIS_SHA256="$(genesis_sha256 "$GENESIS/genesis.json")"
GENESIS_CHAIN_ID="$(jq -er .chain_id "$GENESIS/genesis.json")"
write_phase_lineage "$RUN" "$GENESIS_CHAIN_ID" "$GENESIS_SHA256"
record_join_state "$NODE" PREPARED

if [[ -n "${GDC_RESTORE_VALIDATOR_BACKUP_ARCHIVE:-}" ]]; then
  step "Validate $NODE validator identity from operator backup"
  restore_archive="$RUN/restore-validator-backup.tar"
  install -m 0600 -- "$GDC_RESTORE_VALIDATOR_BACKUP_ARCHIVE" "$restore_archive" \
    || die 'cannot retain validator backup inside the private JOIN run directory'
  restore_archive_sha256="$(sha256sum "$restore_archive" | awk '{print $1}')"
  expected_restore_archive_sha256="$(jq -er '.spec.identity.restore_archive_sha256' "$GDC_JOIN_PROFILE" 2>/dev/null)" \
    || die 'restore JOIN profile lacks its archive digest binding'
  [[ "$restore_archive_sha256" == "$expected_restore_archive_sha256" ]] \
    || die 'validator backup archive changed after the JOIN profile was resolved'
  GDC_RESTORE_VALIDATOR_BACKUP_ARCHIVE="$restore_archive" \
    "$ROOT/scripts/validator-backup.sh" restore "$NODE" "$restore_archive"
  export GDC_RESTORE_VALIDATOR_BACKUP=true
  export GDC_RESTORE_IDENTITY_FILE="$STATE/restore/$NODE/identity.json"
  export GDC_RESTORE_TMKMS_STATE_FILE="$STATE/restore/$NODE/tmkms-signing-state.json"
  [[ -r "$GDC_RESTORE_TMKMS_STATE_FILE" ]] || die 'validator backup restore did not retain its TMKMS signing state'
  install -m 0600 "$GDC_RESTORE_TMKMS_STATE_FILE" "$RUN/restore-tmkms-signing-state.json"
  if [[ "$(<"$STATE/restore/$NODE/mode")" == existing ]]; then
    [[ "${GDC_JOIN_PREVIOUS_RUN_ID:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] \
      || die 'existing Host recovery lacks the prior completed run authority'
    "$ROOT/scripts/recover-running-host-state.sh" "$NODE" "$GDC_RESTORE_VALIDATOR_BACKUP_ARCHIVE"
    # Recovery validates and repairs the deployment in place.  Keep node
    # restart authority bound to the prior completed run, whose profile and
    # terminal result describe the live deployment.
    printf '%s\n' "$GDC_JOIN_PREVIOUS_RUN_ID" >"$STATE/active-run-id"
    : >"$RUN/preserve-prior-run"
    exit 0
  fi
  # A reset receipt is acquired from the very machine being restored, before
  # any state-sync or signer activation. A backup alone cannot authorize moving
  # its key to another Host. Keep the latest pre-reset HRS even with an older archive.
  if ! bash "$ROOT/scripts/same-host-restore.sh" bind "$NODE" "$GDC_RESTORE_IDENTITY_FILE" "$GENESIS_CHAIN_ID" "$RUN/same-host-reset.json"; then
    record_restore_fence_refusal
    die 'old_signer_fence_unprovable: same-Host reset evidence is missing or does not match'
  fi
  ssh -T "$NODE" "sudo -n cat '/srv/dai/signer/$NODE/tmkms/state/priv_validator_state.json'" >"$GDC_RESTORE_TMKMS_STATE_FILE"
  install -m 0600 "$GDC_RESTORE_TMKMS_STATE_FILE" "$RUN/restore-tmkms-signing-state.json"
fi

# An independent operator may be the first person to use this Host.  In a
# split deployment the ML runtime must be able to reach the network Host's
# DAPI callback port; that ingress rule belongs to host preparation, not to a
# later PoC retry.  Prepare only this joining topology (and its declared ML
# Host, which phase-prepare derives) so unrelated Hosts are never touched.
step "Prepare $NODE for independent join"
if GDC_PREPARE_HOSTS="$NODE" "$ROOT/scripts/phase-prepare.sh"; then
  :
else
  prepare_rc=$?
  # The phase has reached TARGET_CLASSIFIED but has not created an identity,
  # rendered a deployment, or started a signer. Host preparation is
  # idempotent, so any failure here may be retried through a new JOIN run.
  # Leave a typed marker for the launcher instead of classifying it as an
  # unknown post-signer failure.
  : >"$RUN/prepare-failed-before-identity"
  chmod 0600 "$RUN/prepare-failed-before-identity"
  if (( prepare_rc == 194 )); then
    # No identity, deployment, or signer has been created at this point.
    # Record the typed, recoverable stop for the launcher and for a later
    # ordinary JOIN retry after the operator reboots this Host.
    : >"$RUN/prepare-reboot-required"
    chmod 0600 "$RUN/prepare-reboot-required"
    printf 'REBOOT REQUIRED %s preparation installed a driver. Reboot this Host, then rerun the same gdc host join command. No reset is required.\n' "$NODE" >&2
  fi
  exit "$prepare_rc"
fi
record_join_transition HOST_BASE_PREPARED

if [[ "${GDC_JOIN_SKIP_QUALIFICATION:-false}" == true ]]; then
  printf 'SKIP  ML qualification explicitly disabled by the joining Host operator\n'
else
  # ensure_ml_qualification uses die() for a missing/invalid final report.
  # Run it in a subshell so that exit remains a qualification failure here,
  # instead of terminating this phase before it can retain the pre-identity
  # boundary for the launcher.
  qualification_rc=0
  ( ensure_ml_qualification "$ML_TARGET" ) || qualification_rc=$?
  if (( qualification_rc != 0 )); then
    # Qualification is the last gate before local account, identity,
    # deployment and signer creation. Keep a typed marker so the launcher can
    # retain a bounded, retryable outcome instead of claiming signer state is
    # unknown.
    : >"$RUN/qualification-failed-before-identity"
    chmod 0600 "$RUN/qualification-failed-before-identity"
    exit "$qualification_rc"
  fi
fi
# Every joining Host creates and owns its local keyring passwords before it
# creates any account. No Genesis operator key, funding approval, or
# cross-operator secret transfer is needed. A backup supplies its warm
# mnemonic, so a replaced Host can create a fresh encrypted keyring and then
# prove that it recreates the recorded public identity.
if [[ ! -s "$SECRETS/operator.keyring" || ! -s "$SECRETS/$NODE.keyring" || ! -s "$SECRETS/$NODE.postgres" ]]; then
  step "Create scoped operator secrets for $NODE"
  "$ROOT/scripts/make-node-operator-secrets.sh" "$NODE" "$SECRETS"
fi

step "Ensure $NODE cold account is available for transaction signing"
"$ROOT/01-identities-genesis/create-cold-accounts.sh" "$SECRETS/operator.keyring" "$NODE"
[[ -s "$ACCOUNT" ]] || die "missing public cold account for $NODE"
ADDRESS="$(jq -er .address "$ACCOUNT")"
RUNTIME_ID="$(runtime_id_for_participant "$ADDRESS")"
record_runtime_identity "$NODE" "$ADDRESS" "$RUNTIME_ID"

# A cold mnemonic identifies the on-chain participant, but it cannot recover
# its validator identity.  Check this before generating anything on the Host:
# otherwise a reset Host could acquire a new TMKMS/P2P/warm identity and appear
# to resume an existing participant.
# Retry transport errors and 5xx so a transient failure does not strand a new
# cold account. No --fail: 404 is the answer for a new participant.
lookup_participant() {
  local endpoint="$1" body_file="$2" stderr_file="$3" attempts=6
  participant_attempt=0
  while :; do
    participant_attempt=$((participant_attempt + 1))
    participant_curl_exit=0
    participant_http_status="$(curl -sS --connect-timeout 10 --max-time 30 -o "$body_file" -w '%{http_code}' "$endpoint" 2>"$stderr_file")" || participant_curl_exit=$?
    if (( participant_curl_exit == 0 )) && [[ ! "$participant_http_status" =~ ^5[0-9][0-9]$ ]]; then
      return 0
    fi
    (( participant_attempt < attempts )) || return 0
    printf 'WAIT  participant lookup attempt %s failed (curl_exit=%s http_status=%s); retrying\n' "$participant_attempt" "$participant_curl_exit" "${participant_http_status:-000}"
    sleep 10
  done
}
participant_endpoint="https://${GENESIS_PUBLIC_HOST}/v2/participants/$ADDRESS"
participant_body_file="$(mktemp)"
participant_stderr_file="$(mktemp)"
lookup_participant "$participant_endpoint" "$participant_body_file" "$participant_stderr_file"
participant_error_detail="$(tr '\n' ' ' <"$participant_stderr_file" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
participant_body="$(<"$participant_body_file")"
rm -f "$participant_body_file" "$participant_stderr_file"
if (( participant_curl_exit != 0 )); then
  die "cannot determine whether $NODE participant already exists (url=$participant_endpoint http_status=${participant_http_status:-000} curl_exit=$participant_curl_exit curl_status=$(curl_exit_status "$participant_curl_exit")${participant_error_detail:+ detail=$participant_error_detail})"
fi
case "$participant_http_status" in
  200)
    participant_status="$(jq -r '.participant.status // empty' <<<"$participant_body" 2>/dev/null)" || die "participant endpoint returned malformed JSON for $NODE (url=$participant_endpoint http_status=200)"
    participant_state="$(participant_onboarding_state "$participant_status")"
    ;;
  404)
    participant_status=''
    participant_state=new
    ;;
  *)
    die "cannot determine whether $NODE participant already exists (url=$participant_endpoint http_status=$participant_http_status attempts=$participant_attempt)"
    ;;
esac

# `host reset` deliberately preserves the joining Host's local account and
# identity evidence, while removing the deployed inference directory and its
# keyring.  A local JSON identity is therefore not sufficient proof that the
# remote node can start.  Recreate the bootstrap when that remote state is
# absent so a subsequent join is self-contained.
remote_identity_ready=false
if [[ -s "$IDENTITY" && "$remote_identity_state" == present ]]; then
  remote_identity_ready=true
fi
[[ "${GDC_RESTORE_VALIDATOR_BACKUP:-false}" == true ]] && remote_identity_ready=false
rebind_existing_participant=false
if [[ "${GDC_JOIN_REBIND_EXISTING_PARTICIPANT:-false}" == true ]]; then
  [[ "${GDC_RESTORE_VALIDATOR_BACKUP:-false}" != true ]] || die "$NODE cannot rebind an existing participant while restoring a validator archive"
  if [[ "$participant_state" == new ]]; then
    printf 'READY %s --mnemonic recovered a new cold account; continuing with ordinary participant registration\n' "$NODE"
  else
    rebind_existing_participant=true
    printf 'READY %s cold account owns an existing participant; a newly generated TMKMS signer will replace its registered validator key\n' "$NODE"
  fi
fi
if [[ "$participant_state" != new && "${GDC_RESTORE_VALIDATOR_BACKUP:-false}" != true && "$remote_identity_ready" != true && "$rebind_existing_participant" != true ]]; then
  die "$NODE participant already exists on this chain, but its validator identity is absent on the Host; cold and warm mnemonics alone cannot restore it. Preserve the evidence and use a separately validated recovery procedure."
fi
if [[ "$remote_identity_ready" != true ]]; then
  [[ -s "$IDENTITY" ]] && printf 'READY remote identity state is absent; recreating %s identity bootstrap\n' "$NODE"
  step "Create $NODE identity"
  GDC_RESTORE_WARM_MNEMONIC="${GDC_RESTORE_VALIDATOR_BACKUP:+$GDC_HOME/mnemonics/$NODE-warm.mnemonic}" \
    "$ROOT/01-identities-genesis/collect-identities.sh" "$INVENTORY" "$SECRETS" "$IDENTITIES" "$GDC_HOME/mnemonics" "$NODE"
fi
if [[ "${GDC_RESTORE_VALIDATOR_BACKUP:-false}" == true ]]; then
  jq -e --slurpfile expected "$GDC_RESTORE_IDENTITY_FILE" '
    .node_name == $expected[0].node_name and
    .node_id == $expected[0].node_id and
    .consensus_pubkey == $expected[0].consensus_pubkey and
    .warm_address == $expected[0].warm_address and
    .warm_pubkey_b64 == $expected[0].warm_pubkey_b64
  ' "$IDENTITY" >/dev/null || die "$NODE restored identity does not match validator backup"
  printf 'READY %s restored validator identity matches the operator backup\n' "$NODE"
fi
# The temporary identity bootstrap reports a public key, but the durable
# authority for a JOIN signer is the softsign key that will be mounted into
# canonical TMKMS. Derive that exact public value before rendering any
# configuration, registration request or recovery archive. A restore archive
# remains strict: its recorded identity must already match the restored key.
canonical_tmkms_key="$(ssh -T "$NODE" "sudo -n bash -s -- '/srv/dai/signer/$NODE/tmkms/secrets/priv_validator_key.softsign'" <"$ROOT/scripts/tmkms-softsign-public-key.sh")" \
  || die "$NODE cannot derive the durable TMKMS public key"
[[ "$(base64 -d <<<"$canonical_tmkms_key" 2>/dev/null | wc -c | tr -d ' ')" == 32 ]] \
  || die "$NODE durable TMKMS public key is malformed"
bootstrap_tmkms_key="$(jq -er .consensus_pubkey "$IDENTITY")"
if [[ "$bootstrap_tmkms_key" != "$canonical_tmkms_key" ]]; then
  [[ "${GDC_RESTORE_VALIDATOR_BACKUP:-false}" != true ]] \
    || die "$NODE restored validator identity does not match its durable TMKMS signer"
  identity_next="$(mktemp "${IDENTITY}.tmkms.XXXXXX")"
  jq --arg consensus "$canonical_tmkms_key" '.consensus_pubkey = $consensus' "$IDENTITY" >"$identity_next"
  chmod 0600 "$identity_next"
  mv "$identity_next" "$IDENTITY"
  printf 'READY %s identity consensus key reconciled to its durable TMKMS signer\n' "$NODE"
fi
record_join_state "$NODE" IDENTITY_CREATED "$ADDRESS"
record_join_transition IDENTITY_READY

step "Render $NODE"
NODE_DIR="$GENERATED/nodes/$NODE"
mkdir -p "$NODE_DIR" "$GENERATED/edge" "$GENERATED/agents"
env_args=(--inventory "$INVENTORY" --node-name "$NODE" --account-public "$ACCOUNT" --seeds-file "$GENESIS/genesis-seeds.txt" --secrets-dir "$SECRETS")
env_args+=(--consensus-pubkey "$(jq -er .consensus_pubkey "$IDENTITY")")
[[ -z "${GDC_JOIN_PROFILE:-}" ]] || env_args+=(--join-profile "$GDC_JOIN_PROFILE")
[[ -r "${GDC_JOIN_LINEAGE_RECEIPT:-}" ]] || die 'JOIN lacks a completed lineage preflight receipt'
generation_dir="/srv/dai/data/${NODE}.generations/${GDC_RUN_ID}"
env_args+=(--state-sync-env "$STATE/lineage-preflight.env" --data-dir "$generation_dir")
ML_HOST="$(node_ml_host "$NODE" || true)"
if [[ -n "$ML_HOST" ]]; then
  # The public hostname may resolve to the shared edge.  The ML runtime must
  # post PoC batches to the joining network Host itself, so prefer the SSH
  # endpoint that identifies that Host and only use DNS as a fallback.
  callback_address="$(ssh -G "$NODE" 2>/dev/null | awk '$1 == "hostname" {print $2; exit}' || true)"
  if [[ ! "$callback_address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    callback_address="$(getent ahostsv4 "$(node_public_host "$NODE")" 2>/dev/null | awk 'NR == 1 {print $1}' || true)"
  fi
  [[ "$callback_address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "cannot determine callback IPv4 for $NODE"
  env_args+=(--poc-callback-url "http://$callback_address:9100" --ml-callback-bind 0.0.0.0)
fi
"$ROOT/02-node/render-node-env.sh" "${env_args[@]}" --output "$NODE_DIR/.env" >/dev/null
config_args=(--node-name "$NODE" --runtime-id "$RUNTIME_ID" --output "$NODE_DIR/node-config.json")
[[ -z "${GDC_JOIN_PROFILE:-}" ]] || config_args+=(--join-profile "$GDC_JOIN_PROFILE")
if [[ -n "$ML_HOST" ]]; then
  ML_ENDPOINT="$(ssh -G "$ML_HOST" 2>/dev/null | awk '$1 == "hostname" {print $2; exit}')"
  [[ -n "$ML_ENDPOINT" ]] || die "cannot determine network GPU endpoint from SSH alias $ML_HOST"
  config_args+=(--ml-host "$ML_ENDPOINT" --ml-poc-port 5000)
fi
"$ROOT/02-node/render-node-config.sh" "${config_args[@]}" >/dev/null
edge_env_args=(--inventory "$INVENTORY" --node-name "$NODE" --output "$GENERATED/edge/$NODE.env")
agent_env_args=(--inventory "$INVENTORY" --host "$NODE" --output "$GENERATED/agents/$NODE.env")
if [[ -n "${GDC_JOIN_PROFILE:-}" ]]; then
  edge_env_args+=(--join-profile "$GDC_JOIN_PROFILE")
  edge_env_args+=(--gateway-admission-protocols-json "${GDC_JOIN_GATEWAY_ADMISSION_PROTOCOLS_JSON:-}")
  agent_env_args+=(--join-profile "$GDC_JOIN_PROFILE")
fi
"$ROOT/04-ops/edge-node/render-env.sh" "${edge_env_args[@]}" >/dev/null
"$ROOT/04-ops/agent/render-env.sh" "${agent_env_args[@]}" >/dev/null
record_join_transition CANDIDATE_RENDERED

step "Install $NODE deployment"
REMOTE="/tmp/gdc-deploy-$$-$NODE"
ssh "$NODE" "rm -rf '$REMOTE' && mkdir -p '$REMOTE'"
rsync -a "$ROOT/02-node/" "$NODE:$REMOTE/02-node/"
rsync -a "$ROOT/03-join/" "$NODE:$REMOTE/03-join/"
rsync -a "$ROOT/04-ops/edge-node/" "$NODE:$REMOTE/edge/"
rsync -a "$ROOT/04-ops/agent/" "$NODE:$REMOTE/agent/"
scp -q "$NODE_DIR/.env" "$NODE:$REMOTE/node.env"
scp -q "$NODE_DIR/node-config.json" "$NODE:$REMOTE/node-config.json"
scp -q "$GDC_JOIN_PROFILE" "$NODE:$REMOTE/join-profile.v1.json"
scp -q "$GENERATED/edge/$NODE.env" "$NODE:$REMOTE/edge.env"
scp -q "$GENERATED/agents/$NODE.env" "$NODE:$REMOTE/agent.env"
scp -q "$GENESIS/genesis.json" "$NODE:$REMOTE/genesis.json"
scp -q "$GDC_JOIN_LINEAGE_RECEIPT" "$NODE:$REMOTE/lineage-receipt.json"
scp -q "$ROOT/scripts/verify-join-lineage-state.sh" "$NODE:$REMOTE/verify-join-lineage-state.sh"
local_ml=(); gpu=()
[[ -z "$ML_HOST" ]] && local_ml=(--local-ml) && gpu=(--gpu)
if [[ "$NODE" == "$PUBLIC_EDGE_NODE" ]]; then
  # The public edge owns /srv/dai/edge on this Host.  A participant JOIN must
  # never replace that shared TLS configuration with the node-local edge.
  ssh -T "$NODE" "sudo '$REMOTE/02-node/install-node.sh' --node-name '$NODE' --env '$REMOTE/node.env' --node-config '$REMOTE/node-config.json' --genesis '$REMOTE/genesis.json' --join-profile '$REMOTE/join-profile.v1.json' ${local_ml[*]}; sudo '$REMOTE/agent/install-agent.sh' '$NODE' '$REMOTE/agent.env' ${gpu[*]}"
  printf 'READY retained shared public edge on %s during participant JOIN\n' "$NODE"
else
  ssh -T "$NODE" "sudo '$REMOTE/02-node/install-node.sh' --node-name '$NODE' --env '$REMOTE/node.env' --node-config '$REMOTE/node-config.json' --genesis '$REMOTE/genesis.json' --join-profile '$REMOTE/join-profile.v1.json' ${local_ml[*]}; sudo '$REMOTE/edge/install-edge.sh' '$REMOTE/edge.env' --node-name '$NODE'; sudo '$REMOTE/agent/install-agent.sh' '$NODE' '$REMOTE/agent.env' ${gpu[*]}"
fi
# Persist the explicit external-GPU association as soon as the validator
# deployment exists.  A join can fail later (for example, while claiming the
# faucet); reset must still know exactly which GPU host may be cleaned up and
# must never infer it from an alias convention.
if [[ -n "$ML_HOST" ]]; then
  link_record="$(jq -cn \
    --arg validator_alias "$NODE" \
    --arg ml_ssh_alias "$ML_HOST" \
    --arg ml_endpoint "$ML_ENDPOINT" \
    '{schema_version:1,validator_alias:$validator_alias,ml_ssh_alias:$ml_ssh_alias,ml_endpoint:$ml_endpoint}')"
  printf '%s\n' "$link_record" | ssh -T "$NODE" "set -Eeuo pipefail
    install_path='/srv/dai/deploy/$NODE/gdc-ml-link.json'
    sudo install -d -m 0750 '/srv/dai/deploy/$NODE'
    sudo tee \"\${install_path}.tmp\" >/dev/null
    sudo install -m 0640 \"\${install_path}.tmp\" \"\${install_path}\"
    sudo rm -f \"\${install_path}.tmp\""
  printf 'READY recorded network GPU %s for %s before activation\n' "$ML_HOST" "$NODE"
fi

step "Start signerless native P2P synchronization canary for $NODE"
# The immutable profile was created before preparation. Recreate only its
# short-lived lineage decision at the canary boundary, then render and stage
# the matching state-sync environment without touching identity or signer
# state. This avoids failing a completed preparation merely because its old
# trust checkpoint expired while images or a model were loading.
refresh_lineage_for_canary
"$ROOT/02-node/render-node-env.sh" "${env_args[@]}" --output "$NODE_DIR/.env" >/dev/null
scp -q "$NODE_DIR/.env" "$NODE:$REMOTE/node.env"
scp -q "$GDC_JOIN_LINEAGE_RECEIPT" "$NODE:$REMOTE/lineage-receipt.json"
ssh "$NODE" "owner=\$(id -u); group=\$(id -g); sudo install -o \$owner -g \$group -m 0600 '$REMOTE/node.env' '/srv/dai/deploy/$NODE/.env'; cd '/srv/dai/deploy/$NODE' && docker compose --env-file .env -f compose.yaml config --quiet"
"$ROOT/scripts/verify-lineage-trust-fresh.sh" "$GDC_JOIN_LINEAGE_RECEIPT"
record_join_state "$NODE" SYNCING "$ADDRESS"
ssh "$NODE" "cd /srv/dai/deploy/$NODE && ./start-node.sh --canary"
record_join_transition CANARY_RUNNING
ssh "$NODE" "cd /srv/dai/deploy/$NODE && ./verify-state-sync-config.sh /srv/dai/deploy/$NODE '$REMOTE/lineage-receipt.json'"

step "Wait until signerless P2P canary for $NODE is synchronized"
ssh "$NODE" "cd /srv/dai/deploy/$NODE && ./wait-state-sync-canary.sh /srv/dai/deploy/$NODE '${GDC_JOIN_RPC_SERVER_1%/}'"
record_join_state "$NODE" CAUGHT_UP "$ADDRESS"
record_join_transition CANARY_CAUGHT_UP
step "Verify $NODE acquired the selected source lineage before enabling its signer"
ssh "$NODE" "bash '$REMOTE/verify-join-lineage-state.sh' http://127.0.0.1:26657 '$REMOTE/lineage-receipt.json'"
ssh "$NODE" "cd /srv/dai/deploy/$NODE && ./record-state-sync-canary.sh /srv/dai/deploy/$NODE '$REMOTE/lineage-receipt.json'"
scp -q "$NODE:$REMOTE/lineage-receipt.json" "$RUN/lineage-state-sync-receipt.json"
printf 'READY retained verified signerless P2P canary receipt=%s\n' "$RUN/lineage-state-sync-receipt.json"
record_join_state "$NODE" LINEAGE_VERIFIED "$ADDRESS"
record_join_transition CANARY_VERIFIED
step "Stop signerless P2P canary before promoting $NODE state"
ssh "$NODE" "sudo /srv/dai/deploy/$NODE/stop-state-sync-canary.sh /srv/dai/deploy/$NODE"
record_join_state "$NODE" CANARY_STOPPED "$ADDRESS"
record_join_transition CANARY_STOPPED
step "Promote verified $NODE state-sync generation atomically"
record_join_transition PROMOTION_PREPARED
record_join_transition PROMOTING
ssh "$NODE" "sudo /srv/dai/deploy/$NODE/promote-state-sync-generation.sh '$NODE' '$generation_dir' '/srv/dai/data/$NODE'"
record_join_transition PROMOTED
# Canonical Core remains signerless until membership is reconciled. Upstream
# initialization intentionally creates a disposable local validator key in
# that mode; it must not be treated as the future TMKMS identity.
# The bootstrap keyring is intentionally outside the candidate generation.
# Import the same already verified warm mnemonic into the promoted generation
# before DAPI starts, then prove its public address. This is local keyring
# recovery only: it performs no chain action and never starts TMKMS.
step "Bind $NODE warm account to the promoted signerless generation"
warm_address="$(jq -er '.warm_address' "$IDENTITY")"
printf '%s\n' "$(<"$GDC_HOME/mnemonics/$NODE-warm.mnemonic")" \
  | ssh -T "$NODE" "cd /srv/dai/deploy/$NODE && ./ensure-warm-key.sh --expected-address '$warm_address'"
# Start the canonical application stack without the signer. Registration and
# permissions are chain actions; they must be reconciled and read back before
# this Host can ever sign. `start-node.sh` needs an explicit --enable-signer
# to include TMKMS, so this normal start remains signerless.
step "Start signerless canonical application stack for $NODE"
ssh "$NODE" "cd /srv/dai/deploy/$NODE && ./start-node.sh"
record_join_transition CANONICAL_RUNNING
expected_p2p_node_id="$(jq -er '.node_id' "$IDENTITY")"
expected_core_version="$(jq -er '.spec.components.core.expected_runtime.version' "$GDC_JOIN_PROFILE")"
expected_core_commit="$(jq -er '.spec.components.core.expected_runtime.commit' "$GDC_JOIN_PROFILE")"
expected_dapi_version="$(jq -er '.spec.components.dapi.expected_runtime.version' "$GDC_JOIN_PROFILE")"
expected_dapi_commit="$(jq -er '.spec.components.dapi.expected_runtime.commit' "$GDC_JOIN_PROFILE")"
expected_chain_id="$(jq -er '.spec.network.chain_id' "$GDC_JOIN_PROFILE")"
step "Restart $NODE API and colocated MLNode only after synchronization"
"$ROOT/03-join/restart-api-after-sync.sh" "$NODE"
record_join_transition APPLICATION_ACTIVE
step "Read back canonical signerless Core identity, runtime and state for $NODE"
ssh "$NODE" "cd /srv/dai/deploy/$NODE && ./verify-canonical-join-state.sh '/srv/dai/deploy/$NODE' '$expected_chain_id' '$expected_p2p_node_id' '$expected_core_version' '$expected_core_commit' '$expected_dapi_version' '$expected_dapi_commit'"
ssh "$NODE" "bash '$REMOTE/verify-join-lineage-state.sh' http://127.0.0.1:26657 '$REMOTE/lineage-receipt.json'"
record_join_transition CANONICAL_VERIFIED
if [[ "$NODE" != "$PUBLIC_EDGE_NODE" ]]; then
  # A participant edge is Caddy only: gateway-admission belongs to the shared
  # gateway, and its script is installed only by `gateway apply`.
  start_stack "$NODE" "/srv/dai/deploy/$NODE/edge" caddy
else
  printf 'READY retained shared public edge on %s during participant JOIN\n' "$NODE"
fi
start_stack "$NODE" "/srv/dai/deploy/$NODE/monitoring-agent"
# Registration permanently binds the cold account to this consensus key.  A
# verified archive must exist before that first chain mutation; the archive
# refreshed after signer activation only advances its signing-state evidence.
step "Create $NODE validator recovery archive before registration"
"$ROOT/scripts/validator-backup.sh" create "$NODE"
record_join_transition RECOVERY_ARCHIVE_READY
participant_body="$(curl --connect-timeout 5 --max-time 10 -fsS "https://$GENESIS_PUBLIC_HOST/v2/participants/$ADDRESS" 2>/dev/null || true)"
participant_status="$(jq -r '.participant.status // empty' <<<"$participant_body" 2>/dev/null || true)"
participant_state="$(participant_onboarding_state "$participant_status")"
case "$participant_state" in
  active)
    already_registered=true
    already_active=true
    ;;
  new)
    already_registered=false
    already_active=false
    ;;
  registered)
    already_registered=true
    already_active=false
    ;;
  invalid)
    die "$NODE participant is INVALID; recovery requires an explicit chain-state decision, not duplicate funding"
    ;;
esac

expected_registration_key="$(jq -er .consensus_pubkey "$IDENTITY")"
[[ "$expected_registration_key" == "$canonical_tmkms_key" ]] \
  || die "$NODE registered validator key does not match the durable TMKMS signer; refuse registration"

if [[ "${GDC_RESTORE_VALIDATOR_BACKUP:-false}" == true && "$already_registered" != true ]]; then
  die "$NODE validator backup belongs to a participant that is not registered on this chain; refusing to create a duplicate participant"
fi

if [[ "$already_registered" == true && "$rebind_existing_participant" != true ]]; then
  printf 'READY %s participant already registered with status=%s; skip duplicate registration\n' "$NODE" "$participant_status"
elif [[ "$rebind_existing_participant" == true ]]; then
  # The public DAPI registration endpoint accepts only
  # MsgSubmitNewUnfundedParticipant. It cannot update an account which already
  # exists, even when the HTTP request succeeds. The native participant message
  # is the supported update path: the restored cold account signs it directly.
  step "Rebind $NODE participant validator key with its restored cold account"
  rebind_rpc="${GDC_CHAIN_RPC_URL:-https://$GENESIS_PUBLIC_HOST/chain-rpc/}"
  rebind_password="$(<"$SECRETS/operator.keyring")"
  rebind_tx="$(printf '%s\n' "$rebind_password" | GDC_OPERATOR_HOME="$STATE/operator-home" \
    "$ROOT/scripts/inferenced.sh" tx inference submit-new-participant "$URL" \
      --validator-key "$expected_registration_key" \
      --from "$NODE-cold" --keyring-backend file --chain-id "$CHAIN_ID" --node "$rebind_rpc" \
      --gas auto --gas-adjustment 1.5 --gas-prices 0ngonka --broadcast-mode sync --output json --yes)"
  jq -e '(.code // .tx_response.code // -1) == 0 and ((.txhash // .tx_response.txhash // "") | test("^[A-Fa-f0-9]{64}$"))' \
    <<<"$rebind_tx" >/dev/null || die "$NODE participant-key rebind transaction was not accepted"
  rebind_txhash="$(jq -er '.txhash // .tx_response.txhash' <<<"$rebind_tx")"
  rebind_receipt=''
  for _ in $(seq 1 60); do
    rebind_receipt="$("$ROOT/scripts/inferenced.sh" query tx "$rebind_txhash" --node "$rebind_rpc" --output json 2>/dev/null || true)"
    if jq -e '(.code // .tx_response.code // -1) == 0 and ((.height // .tx_response.height // "0") | tonumber) > 0' \
      <<<"$rebind_receipt" >/dev/null 2>&1; then
      break
    fi
    printf 'WAIT  participant-key rebind transaction %s to enter a block\n' "$rebind_txhash"
    sleep 2
  done
  jq -e '(.code // .tx_response.code // -1) == 0 and ((.height // .tx_response.height // "0") | tonumber) > 0' \
    <<<"$rebind_receipt" >/dev/null || die "$NODE participant-key rebind transaction did not commit"
  printf '%s\n' "$rebind_receipt" >"$RUN/participant-key-rebind-receipt.json"
  rebound_body="$(curl -fsS --connect-timeout 5 --max-time 15 "https://${GENESIS_PUBLIC_HOST}/chain-api/productscience/inference/inference/participant/$ADDRESS")" \
    || die "$NODE participant-key rebind committed but its chain readback is unavailable"
  jq -e --arg expected "$expected_registration_key" '.participant.validator_key == $expected' <<<"$rebound_body" >/dev/null \
    || die "$NODE participant-key rebind committed but did not publish the durable TMKMS validator key"
  printf 'PASS %s participant validator key now matches the durable TMKMS signer\n' "$NODE"
else
  step "Register $NODE before funding"
  registration_timeout="${GDC_JOIN_REGISTRATION_TIMEOUT_SECONDS:-300}"
  [[ "$registration_timeout" =~ ^[1-9][0-9]*$ ]] || die 'GDC_JOIN_REGISTRATION_TIMEOUT_SECONDS must be positive'
  registration_deadline=$((SECONDS + registration_timeout))
  registration_succeeded=false
  while (( SECONDS < registration_deadline )); do
    if ssh "$NODE" "cd /srv/dai/deploy/$NODE && ./register-participant.sh .env >register-participant.log 2>&1"; then
      registration_succeeded=true
      break
    fi
    registration_log="$(ssh "$NODE" "tail -100 /srv/dai/deploy/$NODE/register-participant.log" 2>/dev/null || true)"
    # The registration endpoint is served through the currently active chain
    # participant. It can legitimately return a transient 5xx response while
    # that edge is restarting or changing PoC phase. Retry only that class;
    # malformed identities, authentication errors and other deterministic
    # failures must surface immediately instead of becoming a 30-minute wait.
    if grep -Eq '(^|[^0-9])5[0-9]{2}([^0-9]|$)|Service Temporarily Unavailable|context deadline exceeded|Client\.Timeout exceeded|TLS handshake timeout' <<<"$registration_log"; then
      # A client-side timeout is ambiguous: the chain edge may have accepted
      # the registration after the client disconnected. Check public state
      # before retrying so a second POST is never used to infer success.
      observed_body="$(curl -fsS --connect-timeout 5 --max-time 15 "https://$GENESIS_PUBLIC_HOST/v2/participants/$ADDRESS" 2>/dev/null || true)"
      observed_status="$(jq -r '.participant.status // empty' <<<"$observed_body" 2>/dev/null || true)"
      case "$(participant_onboarding_state "$observed_status")" in
        active|registered)
          registration_succeeded=true
          printf 'READY %s registration is committed after an ambiguous transport timeout\n' "$NODE"
          break
          ;;
      esac
      printf 'WAIT  %s registration endpoint is transiently unavailable\n' "$NODE"
      sleep 5
      continue
    fi
    printf '%s\n' "$registration_log" >&2
    die "$NODE registration command failed without a retryable server response"
  done
  [[ "$registration_succeeded" == true ]] || {
    ssh "$NODE" "tail -100 /srv/dai/deploy/$NODE/register-participant.log" >&2 || true
    die "$NODE registration endpoint did not accept the participant within ${registration_timeout}s"
  }
  "$ROOT/03-join/wait-registered.sh" "https://$GENESIS_PUBLIC_HOST" "$ADDRESS" "$registration_timeout" || {
    ssh "$NODE" "tail -100 /srv/dai/deploy/$NODE/register-participant.log" >&2 || true
    exit 1
  }
fi
record_join_state "$NODE" MEMBERSHIP_RECONCILED "$ADDRESS"
record_join_transition MEMBERSHIP_RECONCILED
if [[ "$already_active" == true ]]; then
  warm_address="$(jq -er .warm_address "$IDENTITY")"
  warm_account_endpoint="https://${GENESIS_PUBLIC_HOST}/chain-api/cosmos/auth/v1beta1/accounts/$warm_address"
  warm_account_body="$(mktemp)"
  warm_account_stderr="$(mktemp)"
  if warm_account_status="$(curl -sS --connect-timeout 5 --max-time 15 -o "$warm_account_body" -w '%{http_code}' "$warm_account_endpoint" 2>"$warm_account_stderr")"; then
    warm_account_curl_exit=0
  else
    warm_account_curl_exit=$?
  fi
  warm_account_detail="$(tr '\n' ' ' <"$warm_account_stderr" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  rm -f "$warm_account_body" "$warm_account_stderr"
  if (( warm_account_curl_exit == 0 )) && [[ "$warm_account_status" =~ ^2[0-9][0-9]$ ]]; then
    printf 'READY %s is already ACTIVE with a provisioned warm account; skip duplicate funding and ML permission transactions\n' "$NODE"
  elif (( warm_account_curl_exit == 0 )) && [[ "$warm_account_status" == 404 ]]; then
    printf 'READY %s is already ACTIVE but its warm account is absent; resume ML permission grant without duplicate funding\n' "$NODE"
    step "Grant ML operational permissions for $NODE"
    "$ROOT/03-join/grant-ml-ops.sh" "$NODE" "$IDENTITY" "$INVENTORY"
  else
    die "cannot determine whether ACTIVE $NODE has a provisioned warm account (url=$warm_account_endpoint http_status=${warm_account_status:-000} curl_exit=$warm_account_curl_exit curl_status=$(curl_exit_status "$warm_account_curl_exit")${warm_account_detail:+ detail=$warm_account_detail})"
  fi
else
  step "Claim bounded public DevNet funding for $NODE"
  "$ROOT/scripts/claim-devnet-faucet.sh" "$ADDRESS"
  step "Grant ML operational permissions for $NODE"
  "$ROOT/03-join/grant-ml-ops.sh" "$NODE" "$IDENTITY" "$INVENTORY"
  if [[ -z "$ML_HOST" ]]; then
    step "Start colocated ML inference for $NODE"
    "$ROOT/03-join/start-local-ml.sh" "$NODE" "$MODEL_ID" "$MODEL_REVISION" \
      "$MLNODE_DTYPE" "$MLNODE_TENSOR_PARALLEL_SIZE" "$MLNODE_MAX_NUM_SEQS" \
      "$MLNODE_GPU_MEMORY_UTILIZATION" "$MLNODE_CONTEXT_LENGTH"
  fi
  step "Wait until $NODE is ACTIVE"
  "$ROOT/03-join/wait-active.sh" "https://$GENESIS_PUBLIC_HOST" "$ADDRESS"
fi
record_join_state "$NODE" PERMISSIONS_RECONCILED "$ADDRESS"
record_join_transition PERMISSIONS_RECONCILED
mkdir -p "$STATE/joined"
touch "$STATE/joined/$NODE"
if [[ -n "$ML_HOST" ]]; then
  step "Attach network GPU $ML_HOST to $NODE"
  "$ROOT/scripts/phase-ml-attach.sh" "$NODE"
fi

# A controlled reset authorizes rejoin only on that same physical Host.
# Cross-Host replacement still has no automatic signer dispatcher.
if [[ "$join_operation" == restore ]]; then
  bash "$ROOT/scripts/same-host-restore.sh" bind "$NODE" "$IDENTITY" "$GENESIS_CHAIN_ID" "$RUN/same-host-reset-before-enable.json"
fi

step "Fence existing $NODE signer after membership reconciliation"
signer_consensus_pubkey="$(jq -er .consensus_pubkey "$IDENTITY")"
signer_fence_remote="/srv/dai/deploy/$NODE/.gdc/runs/${GDC_RUN_ID:-manual}/signer-fence-receipt.v1.json"
ssh "$NODE" "sudo /srv/dai/deploy/$NODE/fence-existing-signer.sh /srv/dai/deploy/$NODE '${GDC_RUN_ID:-manual}' '$signer_consensus_pubkey' '$NODE'"
# The fence helper is deliberately root-owned: it observed and stopped a
# privileged service. Do not weaken its remote permissions merely to make an
# ordinary SSH account read it. Retrieve this bounded document through the
# same sudo authority that ran the helper, then keep the local copy private.
ssh "$NODE" "sudo cat '$signer_fence_remote'" >"$RUN/signer-fence-receipt.v1.json"
chmod 600 "$RUN/signer-fence-receipt.v1.json"
"$ROOT/scripts/verify-signer-fence-receipt.sh" --receipt "$RUN/signer-fence-receipt.v1.json" \
  --run-id "${GDC_RUN_ID:-manual}" --consensus-pubkey "$signer_consensus_pubkey"
record_join_state "$NODE" SIGNER_FENCE_VERIFIED "$ADDRESS"
record_join_transition SIGNER_FENCE_VERIFIED
step "Enable $NODE consensus signer after application and membership verification"
# Persist the conservative terminal result before the remote start.  If SSH
# drops after Docker accepts the request, a later invocation must not infer
# that the signer remains off or attempt an automatic resume.
record_signer_activation_guard
record_join_transition SIGNER_ACTIVATING true
step "Capture $NODE TMKMS signing minimum before enablement"
ssh "$NODE" "sudo cat '/srv/dai/signer/$NODE/tmkms/state/priv_validator_state.json'" >"$RUN/tmkms-signing-state-before-enable.json"
chmod 600 "$RUN/tmkms-signing-state-before-enable.json"
[[ -s "$RUN/tmkms-signing-state-before-enable.json" ]] || die 'TMKMS signing minimum is unavailable before enablement'
ssh -T "$NODE" 'curl -fsS --max-time 10 http://127.0.0.1:26657/status' >"$RUN/status-before-enable.json"
jq -e --slurpfile state "$RUN/tmkms-signing-state-before-enable.json" '.result.sync_info.catching_up==false
  and (.result.sync_info.latest_block_height|tonumber)>($state[0].height|tonumber)' "$RUN/status-before-enable.json" >/dev/null \
  || die 'restored chain has not passed the last height signed before reset'
ssh "$NODE" "cd /srv/dai/deploy/$NODE && ./start-node.sh --enable-signer"
# Enabling the signer recreates Core. Its RPC answers and leaves block sync
# some seconds later, so one immediate readback fails on a healthy Host.
signer_readback_deadline=$((SECONDS+300))
until ssh "$NODE" "cd /srv/dai/deploy/$NODE && ./verify-active-signer-state.sh '/srv/dai/deploy/$NODE' '$expected_chain_id' '$expected_core_version'" >"$RUN/active-signer-readback.log" 2>&1; do
  if (( SECONDS>=signer_readback_deadline )); then
    cat "$RUN/active-signer-readback.log" >&2
    die 'active signer readback did not pass after signer enablement'
  fi
  printf 'WAIT active signer readback for %s: %s\n' "$NODE" "$(tail -n 1 "$RUN/active-signer-readback.log")"
  sleep 5
done
cat "$RUN/active-signer-readback.log"
active_signer_key="$(ssh -T "$NODE" 'curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:26657/status' | jq -r '.result.validator_info.pub_key.value // empty')"
[[ "$active_signer_key" == "$signer_consensus_pubkey" ]] \
  || die "$NODE enabled signer does not expose the registered TMKMS validator key"
printf 'PASS %s enabled signer exposes its registered TMKMS validator key\n' "$NODE"
advanced=false
# The key signs only once it is in the validator set. ACTIVE does not mean
# that: a new participant enters the set at an epoch boundary after its first
# PoC, a restored one when its PoC becomes effective again. Both get the
# window RECOVER-INCIDENT.md allows for set membership.
signing_deadline=$((SECONDS+2400))
signing_wait_started=$SECONDS
signing_wait_reported=0
while (( SECONDS<signing_deadline )); do
  # The signer is already on; one failed read is not evidence about it.
  ssh "$NODE" "sudo cat '/srv/dai/signer/$NODE/tmkms/state/priv_validator_state.json'" >"$RUN/tmkms-signing-state-after-enable.json" \
    || { sleep 2; continue; }
  chmod 600 "$RUN/tmkms-signing-state-after-enable.json"
  if "$ROOT/scripts/verify-tmkms-signing-state.sh" --minimum "$RUN/tmkms-signing-state-before-enable.json" --observed "$RUN/tmkms-signing-state-after-enable.json" --require-advance >/dev/null 2>"$RUN/tmkms-signing-wait.err"; then
    advanced=true
    break
  fi
  if (( SECONDS-signing_wait_started >= signing_wait_reported+60 )); then
    signing_wait_reported=$((SECONDS-signing_wait_started))
    printf 'WAIT first %s signature after signer enablement elapsed=%ss last=%s\n' "$NODE" "$signing_wait_reported" "$(tail -n 1 "$RUN/tmkms-signing-wait.err" 2>/dev/null)"
  fi
  sleep 2
done
if [[ "$advanced" != true && "$join_operation" == restore ]]; then
  cat "$RUN/tmkms-signing-wait.err" >&2 2>/dev/null || true
  die 'TMKMS signing state did not advance after signer enablement'
fi
record_join_state "$NODE" SIGNER_ENABLED "$ADDRESS"
if [[ "$advanced" == true ]]; then
  record_join_transition SIGNER_ACTIVE_VERIFIED true
else
  # A new participant is ACTIVE before an accepted PoC distribution assigns it
  # positive consensus weight.  Its correctly connected signer has no block to
  # sign in that interval, so a missing signature is not a local JOIN failure.
  # `host join --verification` remains the strict end-to-end eligibility gate.
  cat "$RUN/tmkms-signing-wait.err" >&2 2>/dev/null || true
  record_join_transition SIGNER_ARMED_PENDING_ELIGIBILITY true
  printf 'READY %s signer is armed; positive consensus eligibility remains pending accepted PoC evidence\n' "$NODE"
fi
# Staging cleanup says nothing about the validator and must not end its JOIN.
ssh "$NODE" "rm -rf '$REMOTE'" \
  || printf 'WARN staging directory %s was not removed on %s\n' "$REMOTE" "$NODE"

step "Create $NODE validator recovery archive"
"$ROOT/scripts/validator-backup.sh" create "$NODE"
record_join_transition RECOVERY_ARCHIVE_VERIFIED true
[[ "${GDC_JOIN_VERIFICATION:-false}" == true ]] \
  || {
    record_join_transition COMPLETE true
    printf 'PASS Host JOIN mandatory convergence complete; full lifecycle verification was not requested\n'
    exit 0
  }
step "Verify $NODE through chain eligibility and a gateway regression"
"$ROOT/scripts/phase-join-acceptance.sh" "$NODE"
record_join_transition COMPLETE true
