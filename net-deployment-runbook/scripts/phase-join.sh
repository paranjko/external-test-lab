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
record_join_transition() {
  local state="$1" signer_ever_started="${2:-false}" input participant consensus p2p warm evidence
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
  fi
  jq -cn \
    --arg run_id "${GDC_RUN_ID:-manual}" --arg operation "$join_operation" --arg node "$NODE" --arg state "$state" \
    --arg profile "$join_profile_sha256" --arg observation "$join_observation_sha256" --arg generation "${GDC_RUN_ID:-manual}" \
    --arg participant "$participant" --arg consensus "$consensus" --arg p2p "$p2p" --arg warm "$warm" \
    --argjson signer_ever_started "$signer_ever_started" --argjson evidence "$evidence" \
    '{schema_version:2,kind:"gdc-host-join-receipt",run_id:$run_id,operation:$operation,node_name:$node,state:$state,join_profile_sha256:$profile,network_observation_sha256:$observation,generation_id:$generation,identity_fingerprints:{participant_address:$participant,consensus_pubkey:$consensus,p2p_node_id:$p2p,warm_address:$warm},signer_ever_started:$signer_ever_started,tmkms_state:{height:0,round:0,step:0,block_id:""},evidence:$evidence,outcome:"in_progress",resume_policy:"resume_same_run"}' >"$input"
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
case "$JOIN_CLASS" in
  new|restore_empty)
    printf 'READY Host JOIN classification=%s before mutation\n' "$JOIN_CLASS"
    ;;
  running_matched)
    printf 'READY Host JOIN classification=running_matched; preserving existing local identity for chain readback\n'
    ;;
  partial_identity)
    die 'Host JOIN classification=partial_identity; refuse mutation until the incomplete local identity is resolved through the supported recovery path'
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
    die 'Host JOIN classification=unreachable; remote identity preflight could not establish an SSH session'
  fi
fi
if [[ "$remote_identity_state" == present && "$JOIN_CLASS" == new && -z "${GDC_RESTORE_VALIDATOR_BACKUP_ARCHIVE:-}" ]]; then
  die 'Host JOIN classification=identity_conflict; a remote validator identity exists without matching local operator state'
fi
if [[ "$remote_identity_state" == present && "$JOIN_CLASS" == partial_identity ]]; then
  die 'Host JOIN classification=partial_identity; remote identity cannot be adopted from incomplete local state'
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
    "$ROOT/scripts/recover-running-host-state.sh" "$NODE" "$GDC_RESTORE_VALIDATOR_BACKUP_ARCHIVE"
    exit 0
  fi
fi

# An independent operator may be the first person to use this Host.  In a
# split deployment the ML runtime must be able to reach the network Host's
# DAPI callback port; that ingress rule belongs to host preparation, not to a
# later PoC retry.  Prepare only this joining topology (and its declared ML
# Host, which phase-prepare derives) so unrelated Hosts are never touched.
step "Prepare $NODE for independent join"
GDC_PREPARE_HOSTS="$NODE" "$ROOT/scripts/phase-prepare.sh"
record_join_transition HOST_BASE_PREPARED

if [[ "${GDC_JOIN_SKIP_QUALIFICATION:-false}" == true ]]; then
  printf 'SKIP  ML qualification explicitly disabled by the joining Host operator\n'
else
  ensure_ml_qualification "$ML_TARGET"
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
participant_endpoint="https://${GENESIS_PUBLIC_HOST}/v2/participants/$ADDRESS"
participant_body_file="$(mktemp)"
participant_stderr_file="$(mktemp)"
if participant_http_status="$(curl -sS --connect-timeout 5 --max-time 15 -o "$participant_body_file" -w '%{http_code}' "$participant_endpoint" 2>"$participant_stderr_file")"; then
  participant_curl_exit=0
else
  participant_curl_exit=$?
fi
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
    die "cannot determine whether $NODE participant already exists (url=$participant_endpoint http_status=$participant_http_status)"
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
if [[ "$participant_state" != new && "${GDC_RESTORE_VALIDATOR_BACKUP:-false}" != true && "$remote_identity_ready" != true ]]; then
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
record_join_state "$NODE" IDENTITY_CREATED "$ADDRESS"
record_join_transition IDENTITY_READY

step "Render $NODE"
NODE_DIR="$GENERATED/nodes/$NODE"
mkdir -p "$NODE_DIR" "$GENERATED/edge" "$GENERATED/agents"
env_args=(--inventory "$INVENTORY" --node-name "$NODE" --account-public "$ACCOUNT" --seeds-file "$GENESIS/genesis-seeds.txt" --secrets-dir "$SECRETS")
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
scp -q "$GENERATED/edge/$NODE.env" "$NODE:$REMOTE/edge.env"
scp -q "$GENERATED/agents/$NODE.env" "$NODE:$REMOTE/agent.env"
scp -q "$GENESIS/genesis.json" "$NODE:$REMOTE/genesis.json"
scp -q "$GDC_JOIN_LINEAGE_RECEIPT" "$NODE:$REMOTE/lineage-receipt.json"
scp -q "$ROOT/scripts/verify-join-lineage-state.sh" "$NODE:$REMOTE/verify-join-lineage-state.sh"
local_ml=(); gpu=()
[[ -z "$ML_HOST" ]] && local_ml=(--local-ml) && gpu=(--gpu)
ssh -T "$NODE" "sudo '$REMOTE/02-node/install-node.sh' --node-name '$NODE' --env '$REMOTE/node.env' --node-config '$REMOTE/node-config.json' --genesis '$REMOTE/genesis.json' ${local_ml[*]}; sudo '$REMOTE/edge/install-edge.sh' '$REMOTE/edge.env'; sudo '$REMOTE/agent/install-agent.sh' '$REMOTE/agent.env' ${gpu[*]}"

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

step "Start signerless P2P state-sync canary for $NODE"
record_join_state "$NODE" SYNCING "$ADDRESS"
ssh "$NODE" "cd /srv/dai/deploy/$NODE && ./start-node.sh --canary"
record_join_transition CANARY_RUNNING
ssh "$NODE" "cd /srv/dai/deploy/$NODE && ./verify-state-sync-config.sh /srv/dai/deploy/$NODE '$REMOTE/lineage-receipt.json'"

step "Wait until signerless P2P canary for $NODE is synchronized"
ssh "$NODE" "cd /srv/dai/deploy/$NODE && ./wait-state-sync-canary.sh /srv/dai/deploy/$NODE '${GDC_JOIN_RPC_SERVER_1%/}'"
record_join_state "$NODE" CAUGHT_UP "$ADDRESS"
record_join_transition CANARY_CAUGHT_UP
step "Verify $NODE acquired the quorum-attested lineage before enabling its signer"
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
step "Read back canonical signerless Core identity, runtime and state for $NODE"
expected_p2p_node_id="$(jq -er '.node_id' "$IDENTITY")"
expected_core_version="$(jq -er '.spec.components.core.expected_runtime.version' "$GDC_JOIN_PROFILE")"
expected_core_commit="$(jq -er '.spec.components.core.expected_runtime.commit' "$GDC_JOIN_PROFILE")"
expected_dapi_version="$(jq -er '.spec.components.dapi.expected_runtime.version' "$GDC_JOIN_PROFILE")"
expected_dapi_commit="$(jq -er '.spec.components.dapi.expected_runtime.commit' "$GDC_JOIN_PROFILE")"
expected_chain_id="$(jq -er '.spec.network.chain_id' "$GDC_JOIN_PROFILE")"
ssh "$NODE" "cd /srv/dai/deploy/$NODE && ./verify-canonical-join-state.sh '/srv/dai/deploy/$NODE' '$expected_chain_id' '$expected_p2p_node_id' '$expected_core_version' '$expected_core_commit' '$expected_dapi_version' '$expected_dapi_commit'"
ssh "$NODE" "bash '$REMOTE/verify-join-lineage-state.sh' http://127.0.0.1:26657 '$REMOTE/lineage-receipt.json'"
record_join_transition CANONICAL_VERIFIED
start_stack "$NODE" /srv/dai/edge
start_stack "$NODE" /srv/dai/monitoring-agent
step "Restart $NODE API and colocated MLNode only after synchronization"
"$ROOT/03-join/restart-api-after-sync.sh" "$NODE"
record_join_transition APPLICATION_ACTIVE
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

if [[ "${GDC_RESTORE_VALIDATOR_BACKUP:-false}" == true && "$already_registered" != true ]]; then
  die "$NODE validator backup belongs to a participant that is not registered on this chain; refusing to create a duplicate participant"
fi

if [[ "$already_registered" == true ]]; then
  printf 'READY %s participant already registered with status=%s; skip duplicate registration\n' "$NODE" "$participant_status"
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

# The local target's TMKMS is not an old-validator fence.  A restore can
# synchronize safely without signing, but it must never activate the restored
# consensus key until a separate, fresh and externally evidenced fence of the
# previous Host is available.  This runbook deliberately has no automatic
# replacement-signer dispatcher until it can acquire that evidence itself.
if [[ "$join_operation" == restore ]]; then
  record_restore_fence_refusal
  echo 'old_signer_fence_unprovable: restored Host remains signerless until owner-authorized recovery can acquire conclusive previous-Host evidence' >&2
  exit 1
fi

step "Fence existing $NODE signer after membership reconciliation"
signer_consensus_pubkey="$(jq -er .consensus_pubkey "$IDENTITY")"
signer_fence_remote="/srv/dai/deploy/$NODE/.gdc/runs/${GDC_RUN_ID:-manual}/signer-fence-receipt.v1.json"
ssh "$NODE" "sudo /srv/dai/deploy/$NODE/fence-existing-signer.sh /srv/dai/deploy/$NODE '${GDC_RUN_ID:-manual}' '$signer_consensus_pubkey' '$NODE'"
scp -q "$NODE:$signer_fence_remote" "$RUN/signer-fence-receipt.v1.json"
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
ssh "$NODE" "cd /srv/dai/deploy/$NODE && ./start-node.sh --enable-signer"
ssh "$NODE" "cd /srv/dai/deploy/$NODE && ./verify-active-signer-state.sh '/srv/dai/deploy/$NODE' '$expected_chain_id' '$expected_core_version'"
advanced=false
for ((attempt = 1; attempt <= 30; attempt++)); do
  ssh "$NODE" "sudo cat '/srv/dai/signer/$NODE/tmkms/state/priv_validator_state.json'" >"$RUN/tmkms-signing-state-after-enable.json"
  chmod 600 "$RUN/tmkms-signing-state-after-enable.json"
  if "$ROOT/scripts/verify-tmkms-signing-state.sh" --minimum "$RUN/tmkms-signing-state-before-enable.json" --observed "$RUN/tmkms-signing-state-after-enable.json" --require-advance >/dev/null; then
    advanced=true
    break
  fi
  sleep 2
done
[[ "$advanced" == true ]] || die 'TMKMS signing state did not advance after signer enablement'
ssh "$NODE" "rm -rf '$REMOTE'"
record_join_state "$NODE" SIGNER_ENABLED "$ADDRESS"
record_join_transition SIGNER_ACTIVE_VERIFIED true

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
