#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"
load_project

NODE="$(node_name "${1:-}")"
BACKUP_ARCHIVE="${2:-}"
[[ -f "$BACKUP_ARCHIVE" && -r "$BACKUP_ARCHIVE" ]] || die 'running Host recovery requires a readable validator backup archive'

RESTORE_DIR="$STATE/restore/$NODE"
RESTORE_MANIFEST="$RESTORE_DIR/manifest.json"
RESTORE_IDENTITY="$RESTORE_DIR/identity.json"
RESTORE_MODE="$RESTORE_DIR/mode"
for restore_file in "$RESTORE_MANIFEST" "$RESTORE_IDENTITY" "$RESTORE_MODE"; do
  [[ -f "$restore_file" && ! -L "$restore_file" && -s "$restore_file" ]] \
    || die "$NODE validator backup validation did not produce safe complete local recovery metadata"
done
[[ "$(<"$RESTORE_MODE")" == existing ]] \
  || die "$NODE is not an existing running validator; continue the normal restore JOIN workflow"

RUN="$GDC_HOME/runs/${GDC_RUN_ID:-manual}/operator-state-recovery-$NODE"
export RUN EVIDENCE_PHASE_NAME="operator-state-recovery-$NODE"
mkdir -p "$RUN"
install_evidence_exit_trap 'Existing Host operator-state recovery'

CHAIN_BASE="${GDC_CHAIN_PUBLIC_BASE:-https://$GENESIS_PUBLIC_HOST}"
CHAIN_BASE="${CHAIN_BASE%/}"
PUBLIC_HOST="$(node_public_host "$NODE")"
EXPECTED_URL="https://$PUBLIC_HOST"
ACCOUNT="$(node_account_file "$NODE")"
IDENTITY="$(node_identity_file "$NODE")"
EXPECTED_ADDRESS="$(jq -er .participant_address "$RESTORE_MANIFEST")"
EXPECTED_RUNTIME_ID="$(runtime_id_for_participant "$EXPECTED_ADDRESS")"
EXPECTED_NODE_ID="$(jq -er .node_id "$RESTORE_IDENTITY")"
EXPECTED_VALIDATOR_KEY="$(jq -er .consensus_pubkey "$RESTORE_IDENTITY")"
EXPECTED_WARM_ADDRESS="$(jq -er .warm_address "$RESTORE_IDENTITY")"
EXPECTED_WARM_KEY="$(jq -er .warm_pubkey_b64 "$RESTORE_IDENTITY")"
EXPECTED_ML_HOST="$(node_ml_host "$NODE" || true)"
EXPECTED_CHAIN_ID="$(jq -er .chain_id "$RESTORE_MANIFEST")"
EXPECTED_GENESIS_SHA256="$(jq -er .genesis_sha256 "$RESTORE_MANIFEST")"
RECOVERY_SYNC_TIMEOUT="${GDC_RECOVERY_SYNC_TIMEOUT_SECONDS:-300}"
RECOVERY_DECISION_TIMEOUT="${GDC_RECOVERY_DECISION_TIMEOUT_SECONDS:-120}"
MAX_NODE_LAG="${GDC_MAX_NODE_LAG_BLOCKS:-5}"
RECOVERY_FETCH_ATTEMPTS="${GDC_RECOVERY_FETCH_ATTEMPTS:-5}"
RECOVERY_SNAPSHOT_MAX_AGE="${GDC_RECOVERY_SNAPSHOT_MAX_AGE_SECONDS:-120}"
[[ "$RECOVERY_SYNC_TIMEOUT" =~ ^[1-9][0-9]{1,3}$ && "$RECOVERY_SYNC_TIMEOUT" -ge 30 ]] \
  || die 'GDC_RECOVERY_SYNC_TIMEOUT_SECONDS must be at least 30'
[[ "$RECOVERY_DECISION_TIMEOUT" =~ ^[1-9][0-9]{1,2}$ && "$RECOVERY_DECISION_TIMEOUT" -ge 30 ]] \
  || die 'GDC_RECOVERY_DECISION_TIMEOUT_SECONDS must be between 30 and 999'
[[ "$MAX_NODE_LAG" =~ ^(0|[1-9][0-9]{0,5})$ ]] || die 'GDC_MAX_NODE_LAG_BLOCKS must be a bounded non-negative integer'
[[ "$RECOVERY_FETCH_ATTEMPTS" =~ ^[1-9][0-9]?$ ]] \
  || die 'GDC_RECOVERY_FETCH_ATTEMPTS must be positive'
[[ "$RECOVERY_SNAPSHOT_MAX_AGE" =~ ^[1-9][0-9]{1,3}$ \
  && "$RECOVERY_SNAPSHOT_MAX_AGE" -le 3600 ]] \
  || die 'GDC_RECOVERY_SNAPSHOT_MAX_AGE_SECONDS must be between 10 and 3600'

fetch_json() {
  local label="$1" url="$2" output="$3" stderr_file response_file http_status rc detail attempt response_status
  for ((attempt = 1; attempt <= RECOVERY_FETCH_ATTEMPTS; attempt++)); do
    stderr_file="$(mktemp "$RUN/.curl.XXXXXX")"
    response_file="$(mktemp "$RUN/.response.XXXXXX")"
    if http_status="$(curl -sS --connect-timeout 5 --max-time 20 -o "$response_file" -w '%{http_code}' "$url" 2>"$stderr_file")"; then
      rc=0
    else
      rc=$?
    fi
    detail="$(tr '\n' ' ' <"$stderr_file" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
    rm -f "$stderr_file"
    response_status=transport_error
    ((rc == 0)) && response_status=http_error
    if ((rc == 0)) && [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
      response_status=malformed_json
    fi
    if ((rc == 0)) && [[ "$http_status" =~ ^2[0-9][0-9]$ ]] && jq -e . "$response_file" >/dev/null 2>&1; then
      mv "$response_file" "$output"
      return 0
    fi
    rm -f "$response_file"
    printf 'WAIT  %s attempt=%s/%s url=%s response_status=%s http_status=%s curl_exit=%s curl_status=%s%s\n' \
      "$label" "$attempt" "$RECOVERY_FETCH_ATTEMPTS" "$url" "$response_status" \
      "${http_status:-000}" "$rc" "$(curl_exit_status "$rc")" "${detail:+ detail=$detail}" >&2
    ((attempt == RECOVERY_FETCH_ATTEMPTS)) || sleep 3
  done
  die "$label remained unavailable after $RECOVERY_FETCH_ATTEMPTS attempts (url=$url last_response_status=$response_status last_http_status=${http_status:-000} last_curl_exit=$rc last_curl_status=$(curl_exit_status "$rc")${detail:+ detail=$detail})"
}

fetch_remote_json() {
  local label="$1" url="$2" output="$3" stderr_file response rc detail attempt
  for ((attempt = 1; attempt <= RECOVERY_FETCH_ATTEMPTS; attempt++)); do
    stderr_file="$(mktemp "$RUN/.ssh-curl.XXXXXX")"
    if response="$(ssh -T "$NODE" "curl -fsS --connect-timeout 5 --max-time 20 '$url'" 2>"$stderr_file")"; then
      rc=0
    else
      rc=$?
    fi
    detail="$(tr '\n' ' ' <"$stderr_file" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
    rm -f "$stderr_file"
    if ((rc == 0)) && jq -e . >/dev/null 2>&1 <<<"$response"; then
      printf '%s\n' "$response" >"$output"
      return 0
    fi
    printf 'WAIT  %s attempt=%s/%s response_status=%s ssh_exit=%s%s\n' \
      "$label" "$attempt" "$RECOVERY_FETCH_ATTEMPTS" \
      "$([[ $rc -eq 0 ]] && printf malformed_json || printf transport_error)" "$rc" \
      "${detail:+ detail=$detail}" >&2
    ((attempt == RECOVERY_FETCH_ATTEMPTS)) || sleep 3
  done
  die "$label remained unavailable after $RECOVERY_FETCH_ATTEMPTS attempts (last_ssh_exit=$rc${detail:+ detail=$detail})"
}

evaluate_participant_snapshot() {
  local source="$1" output="$2" error_file="$3"
  if ! "$ROOT/scripts/evaluate-running-host-recovery.sh" participant \
    "$EXPECTED_ADDRESS" "$EXPECTED_VALIDATOR_KEY" "$EXPECTED_URL" "$source" \
    >"$output" 2>"$error_file"; then
    die "$(<"$error_file")"
  fi
}

status_height_or_zero() {
  local payload="$1"
  jq -er '
    .result.sync_info.latest_block_height
    | select(type == "string" and test("^[1-9][0-9]{0,17}$"))
  ' <<<"$payload" 2>/dev/null || printf '0\n'
}

capture_common_state() {
  local prefix="$1" height="$2" output_dir="${3:-$RUN}" remote_url
  remote_url="http://127.0.0.1:26657/block?height=$height"
  fetch_json "canonical block at common height $height" \
    "$CHAIN_BASE/chain-rpc/block?height=$height" "$output_dir/$prefix-chain-block.json"
  fetch_json "public Host block at common height $height" \
    "$EXPECTED_URL/chain-rpc/block?height=$height" "$output_dir/$prefix-public-block.json"
  fetch_remote_json "local Host block at common height $height" \
    "$remote_url" "$output_dir/$prefix-local-block.json"
  if ! "$ROOT/scripts/evaluate-running-host-recovery.sh" block "$EXPECTED_CHAIN_ID" "$height" \
    "$output_dir/$prefix-chain-block.json" "$output_dir/$prefix-public-block.json" \
    "$output_dir/$prefix-local-block.json" \
    >"$output_dir/$prefix-state.json" 2>"$output_dir/$prefix-state.err"; then
    die "$(<"$output_dir/$prefix-state.err")"
  fi
}

capture_validator_set() {
  local prefix="$1" height="$2" output_dir="$3" participant_evaluation="$4"
  local page page_size page_count total
  local -a page_files=()
  fetch_json "$prefix consensus validator set page 1" \
    "$CHAIN_BASE/chain-rpc/validators?height=$height&page=1&per_page=100" \
    "$output_dir/$prefix-validator-page-1.json"
  if ! "$ROOT/scripts/evaluate-running-host-recovery.sh" validator-pages \
    "$height" "$output_dir/$prefix-validator-page-1.json" \
    >"$output_dir/$prefix-validator-pages.json" 2>"$output_dir/$prefix-validator-pages.err"; then
    die "$(<"$output_dir/$prefix-validator-pages.err")"
  fi
  page_size="$(jq -er .page_size "$output_dir/$prefix-validator-pages.json")"
  page_count="$(jq -er .pages "$output_dir/$prefix-validator-pages.json")"
  total="$(jq -er .total "$output_dir/$prefix-validator-pages.json")"
  page_files+=("$output_dir/$prefix-validator-page-1.json")
  for ((page = 2; page <= page_count; page++)); do
    fetch_json "$prefix consensus validator set page $page" \
      "$CHAIN_BASE/chain-rpc/validators?height=$height&page=$page&per_page=$page_size" \
      "$output_dir/$prefix-validator-page-$page.json"
    page_files+=("$output_dir/$prefix-validator-page-$page.json")
  done
  fetch_json "$prefix consensus validator set page 1 stability readback" \
    "$CHAIN_BASE/chain-rpc/validators?height=$height&page=1&per_page=$page_size" \
    "$output_dir/$prefix-validator-page-1-readback.json"
  jq -S .result "$output_dir/$prefix-validator-page-1.json" \
    >"$output_dir/$prefix-validator-page-1.canonical.json"
  jq -S .result "$output_dir/$prefix-validator-page-1-readback.json" \
    >"$output_dir/$prefix-validator-page-1-readback.canonical.json"
  cmp -s "$output_dir/$prefix-validator-page-1.canonical.json" \
    "$output_dir/$prefix-validator-page-1-readback.canonical.json" \
    || die "$NODE consensus validator set changed during bounded pagination"
  if ! "$ROOT/scripts/evaluate-running-host-recovery.sh" validators \
    "$height" "$EXPECTED_ADDRESS" "$EXPECTED_VALIDATOR_KEY" "$participant_evaluation" \
    "${page_files[@]}" >"$output_dir/$prefix-validator-set.json" \
    2>"$output_dir/$prefix-validator-set.err"; then
    die "$(<"$output_dir/$prefix-validator-set.err")"
  fi
  [[ "$(jq -er .total "$output_dir/$prefix-validator-set.json")" == "$total" ]] \
    || die "$NODE validator pagination summary changed during evaluation"
}

capture_commit_decision() {
  local height="$1" validator_evaluation="$2" output_dir="$3"
  local voting_power offset commit_height signature_evaluation canonical
  voting_power="$(jq -er .voting_power "$validator_evaluation")"
  CONSENSUS_SIGNED_RECENTLY=false
  for offset in 0 1 2 3 4; do
    commit_height=$((height - offset))
    ((commit_height > 1)) || continue
    fetch_json "canonical consensus commit $commit_height" \
      "$CHAIN_BASE/chain-rpc/commit?height=$commit_height" \
      "$output_dir/canonical-commit-$commit_height.json"
    canonical="$("$ROOT/scripts/evaluate-running-host-recovery.sh" commit-canonicality \
      "$output_dir/canonical-commit-$commit_height.json")" \
      || die "$NODE consensus commit $commit_height has malformed canonicality metadata"
    if [[ "$canonical" == false ]]; then
      if ((offset == 0)); then
        printf 'WAIT  %s latest commit height=%s is not canonical until the next block; checking the previous committed height\n' \
          "$NODE" "$commit_height"
        continue
      fi
      die "$NODE historical consensus commit $commit_height is unexpectedly non-canonical"
    fi
    if ! signature_evaluation="$("$ROOT/scripts/evaluate-running-host-recovery.sh" signature \
      "$EXPECTED_CHAIN_ID" "$commit_height" "$EXPECTED_ADDRESS" "$EXPECTED_VALIDATOR_KEY" \
      "$validator_evaluation" "$output_dir/canonical-commit-$commit_height.json" \
      2>"$output_dir/canonical-commit-$commit_height.err")"; then
      die "$(<"$output_dir/canonical-commit-$commit_height.err")"
    fi
    printf '%s\n' "$signature_evaluation" >"$output_dir/commit.json"
    if ((voting_power == 0)); then
      [[ "$(jq -r '.signature_required == false and .signed == false' \
        "$output_dir/commit.json")" == true ]] \
        || die "$NODE zero voting-power commit evidence was misclassified"
      return 0
    fi
    if [[ "$(jq -r '.signature_required == true and .signed == true' \
      "$output_dir/commit.json")" == true ]]; then
      CONSENSUS_SIGNED_RECENTLY=true
      return 0
    fi
  done
  die "$NODE has positive voting power but no signed canonical commit was found in the five-height decision window"
}

capture_runtime_decision() {
  local output_dir="$1" remote_ml_link deployed_node_config probe_detail
  remote_ml_link="$(ssh -T "$NODE" "sudo cat /srv/dai/deploy/$NODE/gdc-ml-link.json 2>/dev/null || true")"
  deployed_node_config="$(ssh -T "$NODE" "sudo cat /srv/dai/deploy/$NODE/node-config.json 2>/dev/null || true")"
  printf '%s\n' "$deployed_node_config" >"$output_dir/deployed-node-config.json"
  printf '%s\n' "$remote_ml_link" >"$output_dir/remote-ml-link.json"
  if [[ -n "$EXPECTED_ML_HOST" ]]; then
    if ! ssh -T "$EXPECTED_ML_HOST" 'true' >/dev/null 2>"$output_dir/ml-host-probe.err"; then
      probe_detail="$(tr '\n' ' ' <"$output_dir/ml-host-probe.err" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
      die "$NODE configured split-GPU SSH target is unreachable (alias=$EXPECTED_ML_HOST endpoint=$EXPECTED_ML_ENDPOINT${probe_detail:+ detail=$probe_detail})"
    fi
  fi
  if ! "$ROOT/scripts/evaluate-running-host-recovery.sh" topology \
    "$NODE" "$EXPECTED_RUNTIME_ID" "$EXPECTED_ML_HOST" "$EXPECTED_ML_ENDPOINT" \
    "$archive_has_ml_host" "$archive_ml_host" "$output_dir/remote-ml-link.json" \
    "$output_dir/deployed-node-config.json" >"$output_dir/runtime.json" \
    2>"$output_dir/runtime.err"; then
    die "$(<"$output_dir/runtime.err")"
  fi
}

capture_decision_fence() {
  local deadline sample final_common wait_chain wait_public wait_local
  local decision_chain_id decision_genesis_sha256
  DECISION_SOURCE="$(mktemp -d "$RUN/.decision-candidate.XXXXXX")"
  printf 'schema_version=1\nnode=%s\nstarted_at=%s\n' \
    "$NODE" "$(date -u +%FT%TZ)" >"$DECISION_SOURCE/decision-boundary.marker"
  # Preserve a strict ordering even on filesystems with one-second mtimes.
  touch -d '1 second ago' "$DECISION_SOURCE/decision-boundary.marker"
  fetch_json 'decision-boundary participant identity' \
    "$CHAIN_BASE/v2/participants/$EXPECTED_ADDRESS" "$DECISION_SOURCE/participant-initial.json"
  evaluate_participant_snapshot "$DECISION_SOURCE/participant-initial.json" \
    "$DECISION_SOURCE/participant-initial-evaluation.json" "$DECISION_SOURCE/participant-initial.err"
  deadline=$((SECONDS + RECOVERY_DECISION_TIMEOUT))
  while ((SECONDS < deadline)); do
    fetch_json 'decision-boundary canonical status' \
      "$CHAIN_BASE/chain-rpc/status" "$DECISION_SOURCE/chain-status.json"
    fetch_json 'decision-boundary public Host status' \
      "$EXPECTED_URL/chain-rpc/status" "$DECISION_SOURCE/public-status.json"
    fetch_remote_json 'decision-boundary local Host status' \
      'http://127.0.0.1:26657/status' "$DECISION_SOURCE/local-status.json"
    if ! sample="$("$ROOT/scripts/evaluate-running-host-recovery.sh" status \
      "$EXPECTED_CHAIN_ID" "$EXPECTED_NODE_ID" "$MAX_NODE_LAG" \
      "$last_accepted_chain_height" "$last_accepted_public_height" "$last_accepted_remote_height" \
      "$DECISION_SOURCE/chain-status.json" "$DECISION_SOURCE/public-status.json" \
      "$DECISION_SOURCE/local-status.json" 2>"$DECISION_SOURCE/status.err")"; then
      die "$(<"$DECISION_SOURCE/status.err")"
    fi
    if [[ "$(jq -r .ready <<<"$sample")" == true ]]; then
      printf '%s\n' "$sample" >"$DECISION_SOURCE/status.json"
      break
    fi
    wait_chain="$(jq -r .chain_height <<<"$sample")"
    wait_public="$(jq -r .public_height <<<"$sample")"
    wait_local="$(jq -r .local_height <<<"$sample")"
    printf 'WAIT  %s recovery decision fence chain=%s public=%s local=%s requires=fresh-progress-and-convergence\n' \
      "$NODE" "$wait_chain" "$wait_public" "$wait_local"
    sleep 3
  done
  [[ -s "$DECISION_SOURCE/status.json" ]] \
    || die "$NODE did not produce a fresh synchronized decision snapshot within ${RECOVERY_DECISION_TIMEOUT}s"
  FINAL_CHAIN_HEIGHT="$(jq -er .chain_height "$DECISION_SOURCE/status.json")"
  FINAL_PUBLIC_HEIGHT="$(jq -er .public_height "$DECISION_SOURCE/status.json")"
  FINAL_LOCAL_HEIGHT="$(jq -er .local_height "$DECISION_SOURCE/status.json")"
  PUBLIC_CATCHING_UP="$(jq -er '
    .public_catching_up
    | if type == "boolean" then tostring else error("invalid public catching-up state") end
  ' "$DECISION_SOURCE/status.json")" \
    || die "$NODE decision snapshot has malformed public catching-up state"
  REMOTE_CATCHING_UP="$(jq -er '
    .local_catching_up
    | if type == "boolean" then tostring else error("invalid local catching-up state") end
  ' "$DECISION_SOURCE/status.json")" \
    || die "$NODE decision snapshot has malformed local catching-up state"
  VALIDATOR_HEIGHT="$FINAL_CHAIN_HEIGHT"
  capture_validator_set decision "$VALIDATOR_HEIGHT" "$DECISION_SOURCE" \
    "$DECISION_SOURCE/participant-initial-evaluation.json"
  mv "$DECISION_SOURCE/decision-validator-set.json" "$DECISION_SOURCE/validator-set.json"
  if ! "$ROOT/scripts/evaluate-running-host-recovery.sh" decision-height \
    "$DECISION_SOURCE/status.json" "$DECISION_SOURCE/validator-set.json" \
    >"$DECISION_SOURCE/decision-height.json" 2>"$DECISION_SOURCE/decision-height.err"; then
    die "$(<"$DECISION_SOURCE/decision-height.err")"
  fi
  VOTING_POWER="$(jq -er .voting_power "$DECISION_SOURCE/validator-set.json")"
  VALIDATOR_EFFECTIVE=false
  ((VOTING_POWER > 0)) && VALIDATOR_EFFECTIVE=true
  capture_commit_decision "$VALIDATOR_HEIGHT" \
    "$DECISION_SOURCE/validator-set.json" "$DECISION_SOURCE"
  EVIDENCE_AGE=0
  final_common="$FINAL_CHAIN_HEIGHT"
  ((FINAL_PUBLIC_HEIGHT < final_common)) && final_common="$FINAL_PUBLIC_HEIGHT"
  ((FINAL_LOCAL_HEIGHT < final_common)) && final_common="$FINAL_LOCAL_HEIGHT"
  capture_common_state synchronization "$final_common" "$DECISION_SOURCE"
  mv "$DECISION_SOURCE/synchronization-state.json" "$DECISION_SOURCE/synchronization.json"
  capture_runtime_decision "$DECISION_SOURCE"
  fetch_json 'decision-boundary participant stability readback' \
    "$CHAIN_BASE/v2/participants/$EXPECTED_ADDRESS" "$DECISION_SOURCE/participant-readback.json"
  evaluate_participant_snapshot "$DECISION_SOURCE/participant-readback.json" \
    "$DECISION_SOURCE/participant.json" "$DECISION_SOURCE/participant.err"
  jq -S '.participant | {status,address,validator_key,inference_url}' \
    "$DECISION_SOURCE/participant-initial.json" >"$DECISION_SOURCE/participant-initial.canonical.json"
  jq -S '.participant | {status,address,validator_key,inference_url}' \
    "$DECISION_SOURCE/participant-readback.json" >"$DECISION_SOURCE/participant-readback.canonical.json"
  cmp -s "$DECISION_SOURCE/participant-initial.canonical.json" \
    "$DECISION_SOURCE/participant-readback.canonical.json" \
    || die "$NODE participant identity changed across the recovery decision boundary"
  if ! capture_canonical_genesis "$CHAIN_BASE/chain-rpc/genesis" \
    "$DECISION_SOURCE/live-genesis.json"; then
    die "$NODE canonical Genesis became unavailable at the recovery decision boundary"
  fi
  decision_chain_id="$(jq -er .chain_id "$DECISION_SOURCE/live-genesis.json")" \
    || die "$NODE decision-boundary Genesis has no valid chain ID"
  decision_genesis_sha256="$(genesis_sha256 "$DECISION_SOURCE/live-genesis.json")" \
    || die "$NODE decision-boundary Genesis cannot be hashed"
  "$ROOT/scripts/evaluate-running-host-recovery.sh" lineage \
    "$EXPECTED_CHAIN_ID" "$EXPECTED_GENESIS_SHA256" \
    "$decision_chain_id" "$decision_genesis_sha256" \
    >"$DECISION_SOURCE/genesis-lineage.json" 2>"$DECISION_SOURCE/genesis-lineage.err" \
    || die "$(<"$DECISION_SOURCE/genesis-lineage.err")"
  if ! "$ROOT/scripts/evaluate-running-host-recovery.sh" freshness \
    "$RECOVERY_SNAPSHOT_MAX_AGE" "$DECISION_SOURCE/decision-boundary.marker" \
    "$DECISION_SOURCE/status.json" "$DECISION_SOURCE/participant.json" \
    "$DECISION_SOURCE/validator-set.json" "$DECISION_SOURCE/commit.json" \
    "$DECISION_SOURCE/runtime.json" "$DECISION_SOURCE/synchronization.json" \
    >"$DECISION_SOURCE/freshness.json" 2>"$DECISION_SOURCE/freshness.err"; then
    die "$(<"$DECISION_SOURCE/freshness.err")"
  fi
  COMMON_HEIGHT="$final_common"
  BACKUP_TOPOLOGY_BINDING="$(jq -er .backup_topology_binding "$DECISION_SOURCE/runtime.json")"
}

step "Verify the live canonical Genesis for $NODE recovery"
live_genesis_ready=false
for ((attempt = 1; attempt <= RECOVERY_FETCH_ATTEMPTS; attempt++)); do
  if capture_canonical_genesis "$CHAIN_BASE/chain-rpc/genesis" "$RUN/live-genesis.json"; then
    live_genesis_ready=true
    break
  fi
  printf 'WAIT  live canonical Genesis attempt=%s/%s url=%s/chain-rpc/genesis\n' \
    "$attempt" "$RECOVERY_FETCH_ATTEMPTS" "$CHAIN_BASE" >&2
  ((attempt == RECOVERY_FETCH_ATTEMPTS)) || sleep 3
done
[[ "$live_genesis_ready" == true ]] \
  || die "$NODE live canonical Genesis remained unavailable after $RECOVERY_FETCH_ATTEMPTS attempts"
LIVE_CHAIN_ID="$(jq -er .chain_id "$RUN/live-genesis.json")" \
  || die "$NODE live canonical Genesis has no valid chain ID"
LIVE_GENESIS_SHA256="$(genesis_sha256 "$RUN/live-genesis.json")" \
  || die "$NODE live canonical Genesis cannot be hashed"
if ! "$ROOT/scripts/evaluate-running-host-recovery.sh" lineage \
  "$EXPECTED_CHAIN_ID" "$EXPECTED_GENESIS_SHA256" "$LIVE_CHAIN_ID" "$LIVE_GENESIS_SHA256" \
  >"$RUN/genesis-lineage.json" 2>"$RUN/genesis-lineage.err"; then
  die "$(<"$RUN/genesis-lineage.err")"
fi
write_phase_lineage "$RUN" "$EXPECTED_CHAIN_ID" "$EXPECTED_GENESIS_SHA256"

step "Recover local operator account and public identity for $NODE"
"$ROOT/scripts/recover-running-host-deployment-secrets.sh" "$NODE" "$SECRETS"
if [[ ! -s "$SECRETS/operator.keyring" || ! -s "$SECRETS/$NODE.keyring" || ! -s "$SECRETS/$NODE.postgres" ]]; then
  "$ROOT/scripts/make-node-operator-secrets.sh" "$NODE" "$SECRETS"
fi
COLD_IDENTITY="$("$ROOT/scripts/derive-mnemonic-identity.sh" \
  "$GDC_HOME/mnemonics/$NODE-cold.mnemonic" "$SECRETS/operator.keyring" \
  "$NODE-cold-recovery-check" "$EXPECTED_ADDRESS")" \
  || die "$NODE cold mnemonic cannot be recovered in an isolated keyring"
"$ROOT/01-identities-genesis/create-cold-accounts.sh" "$SECRETS/operator.keyring" "$NODE"
[[ -s "$ACCOUNT" ]] || die "$NODE cold account was not recovered from the validator backup"
[[ "$(jq -er .address "$ACCOUNT")" == "$(jq -er .address <<<"$COLD_IDENTITY")" \
  && "$(jq -er .account_pubkey_b64 "$ACCOUNT")" == "$(jq -er .pubkey <<<"$COLD_IDENTITY")" ]] \
  || die "$NODE recovered cold account does not match the independently derived recovery mnemonic"
mkdir -p "$(dirname "$IDENTITY")"
[[ ! -L "$IDENTITY" ]] || die "$NODE local public identity is a symbolic link"
if [[ -e "$IDENTITY" ]]; then
  [[ -f "$IDENTITY" && -s "$IDENTITY" ]] \
    || die "$NODE local public identity is incomplete or has the wrong type"
  cmp -s "$IDENTITY" "$RESTORE_IDENTITY" \
    || die "$NODE local public identity conflicts with the validator backup"
else
  identity_staged="$(mktemp "$(dirname "$IDENTITY")/.${NODE}.identity.XXXXXX")"
  if ! install -m 0600 "$RESTORE_IDENTITY" "$identity_staged"; then
    rm -f -- "$identity_staged"
    die "$NODE local public identity could not be staged"
  fi
  mv -- "$identity_staged" "$IDENTITY"
fi

WARM_IDENTITY="$("$ROOT/scripts/derive-mnemonic-identity.sh" \
  "$GDC_HOME/mnemonics/$NODE-warm.mnemonic" "$SECRETS/$NODE.keyring" \
  "$NODE-warm-recovery-check" "$EXPECTED_WARM_ADDRESS" "$EXPECTED_WARM_KEY")" \
  || die "$NODE warm mnemonic cannot be recovered in an isolated keyring"
[[ "$(jq -er .address <<<"$WARM_IDENTITY")" == "$EXPECTED_WARM_ADDRESS" \
  && "$(jq -er .pubkey <<<"$WARM_IDENTITY")" == "$EXPECTED_WARM_KEY" ]] \
  || die "$NODE restored warm mnemonic does not control the identity recorded in the validator backup"

step "Verify $NODE archive identity against the live chain and Host"
fetch_json 'participant identity' "$CHAIN_BASE/v2/participants/$EXPECTED_ADDRESS" "$RUN/participant.json"
evaluate_participant_snapshot "$RUN/participant.json" "$RUN/participant-evaluation.json" \
  "$RUN/participant-evaluation.err"

fetch_json 'warm account' "$CHAIN_BASE/chain-api/cosmos/auth/v1beta1/accounts/$EXPECTED_WARM_ADDRESS" "$RUN/warm-account.json"
jq -e --arg address "$EXPECTED_WARM_ADDRESS" --arg key "$EXPECTED_WARM_KEY" '
  .account.address == $address and .account.pub_key.key == $key
' "$RUN/warm-account.json" >/dev/null \
  || die "$NODE live warm account disagrees with the validator backup"

sync_deadline=$((SECONDS + RECOVERY_SYNC_TIMEOUT))
last_accepted_remote_height=0
last_accepted_public_height=0
last_accepted_chain_height=0
last_sync_report=0
sync_ready=false
sync_samples=0
REMOTE_CATCHING_UP=unknown
PUBLIC_CATCHING_UP=unknown
while ((SECONDS < sync_deadline)); do
  chain_status="$(curl -fsS --connect-timeout 5 --max-time 15 "$CHAIN_BASE/chain-rpc/status" 2>/dev/null || true)"
  public_status="$(curl -fsS --connect-timeout 5 --max-time 15 "$EXPECTED_URL/chain-rpc/status" 2>/dev/null || true)"
  remote_status="$(ssh -T "$NODE" 'curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:26657/status' 2>/dev/null || true)"
  chain_height="$(status_height_or_zero "$chain_status")"
  public_height="$(status_height_or_zero "$public_status")"
  remote_height="$(status_height_or_zero "$remote_status")"
  public_catching="$(jq -r '
    .result.sync_info.catching_up
    | if type == "boolean" then tostring else "unknown" end
  ' <<<"$public_status" 2>/dev/null || true)"
  remote_catching="$(jq -r '
    .result.sync_info.catching_up
    | if type == "boolean" then tostring else "unknown" end
  ' <<<"$remote_status" 2>/dev/null || true)"
  [[ "$public_catching" == true || "$public_catching" == false ]] || public_catching=unknown
  [[ "$remote_catching" == true || "$remote_catching" == false ]] || remote_catching=unknown
  chain_read=ready
  public_read=ready
  host_read=ready
  ((chain_height > 0)) || chain_read=unavailable
  ((public_height > 0)) || public_read=unavailable
  ((remote_height > 0)) || host_read=unavailable
  if ((chain_height > 0 && public_height > 0 && remote_height > 0)); then
    printf '%s\n' "$chain_status" >"$RUN/chain-status-sample.json"
    printf '%s\n' "$public_status" >"$RUN/public-status-sample.json"
    printf '%s\n' "$remote_status" >"$RUN/host-status-sample.json"
    if ((last_accepted_remote_height == 0)); then
      last_accepted_chain_height="$chain_height"
      last_accepted_public_height="$public_height"
      last_accepted_remote_height="$remote_height"
    fi
    if ! sample="$("$ROOT/scripts/evaluate-running-host-recovery.sh" status \
      "$EXPECTED_CHAIN_ID" "$EXPECTED_NODE_ID" "$MAX_NODE_LAG" \
      "$last_accepted_chain_height" "$last_accepted_public_height" "$last_accepted_remote_height" \
      "$RUN/chain-status-sample.json" "$RUN/public-status-sample.json" \
      "$RUN/host-status-sample.json" 2>"$RUN/status-evaluation.err")"; then
      die "$(<"$RUN/status-evaluation.err")"
    fi
    if [[ "$(jq -r .ready <<<"$sample")" == true ]]; then
      sync_samples=$((sync_samples + 1))
      last_accepted_chain_height="$(jq -er .chain_height <<<"$sample")"
      last_accepted_public_height="$(jq -er .public_height <<<"$sample")"
      last_accepted_remote_height="$(jq -er .local_height <<<"$sample")"
    else
      sync_samples=0
    fi
    if ((sync_samples >= 3)); then
      sync_ready=true
      chain_height="$(jq -er .chain_height <<<"$sample")"
      public_height="$(jq -er .public_height <<<"$sample")"
      remote_height="$(jq -er .local_height <<<"$sample")"
      PUBLIC_CATCHING_UP="$(jq -r .public_catching_up <<<"$sample")"
      REMOTE_CATCHING_UP="$(jq -r .local_catching_up <<<"$sample")"
      cp "$RUN/chain-status-sample.json" "$RUN/chain-status.json"
      cp "$RUN/public-status-sample.json" "$RUN/public-status.json"
      cp "$RUN/host-status-sample.json" "$RUN/host-status.json"
      printf '%s\n' "$sample" >"$RUN/status-evaluation.json"
      break
    fi
  else
    sync_samples=0
  fi
  public_lag=$((chain_height > public_height ? chain_height - public_height : public_height - chain_height))
  local_lag=$((chain_height > remote_height ? chain_height - remote_height : remote_height - chain_height))
  if ((SECONDS - last_sync_report >= 15)); then
    printf 'WAIT  %s recovery sync chain=%s chain_read=%s public=%s public_read=%s public_lag=%s public_catching_up=%s local=%s local_read=%s local_lag=%s local_catching_up=%s stable_samples=%s/3\n' \
      "$NODE" "$chain_height" "$chain_read" "$public_height" "$public_read" "$public_lag" \
      "$public_catching" "$remote_height" "$host_read" "$local_lag" "$remote_catching" "$sync_samples"
    last_sync_report=$SECONDS
  fi
  sleep 5
done
[[ "$sync_ready" == true ]] \
  || die "$NODE did not prove bounded height progress and chain convergence within ${RECOVERY_SYNC_TIMEOUT}s"

COMMON_HEIGHT="$chain_height"
((public_height < COMMON_HEIGHT)) && COMMON_HEIGHT="$public_height"
((remote_height < COMMON_HEIGHT)) && COMMON_HEIGHT="$remote_height"
capture_common_state common "$COMMON_HEIGHT"

BASELINE_PROFILE_HASH="$(awk -F= '$1 == "profile_hash" {print $2; exit}' "$STATE/phase-profiles/genesis.env")"
[[ "$BASELINE_PROFILE_HASH" =~ ^[0-9a-f]{64}$ ]] || die 'current Genesis baseline profile hash is unavailable'
REMOTE_RELEASE="$(ssh -T "$NODE" "cat /srv/dai/deploy/$NODE/.gdc-release 2>/dev/null || true")"
[[ "$REMOTE_RELEASE" == "v2026.07.23 $BASELINE_PROFILE_HASH" ]] \
  || die "$NODE running deployment is not the current v2026.07.23 baseline"
archive_ml_host="$(jq -r '.ml_host // empty' "$RESTORE_MANIFEST")"
archive_has_ml_host="$(jq -r 'has("ml_host")' "$RESTORE_MANIFEST")"
EXPECTED_ML_ENDPOINT=''
if [[ -n "$EXPECTED_ML_HOST" ]]; then
  EXPECTED_ML_ENDPOINT="$(ssh -G "$EXPECTED_ML_HOST" 2>/dev/null | awk '$1 == "hostname" {print $2; exit}')"
  [[ -n "$EXPECTED_ML_ENDPOINT" ]] || die "$NODE configured split-GPU SSH alias has no endpoint"
fi

step "Revalidate $NODE at the recovery decision boundary"
capture_decision_fence

RUNTIME_ID="$EXPECTED_RUNTIME_ID"
BACKUP_SHA256="$(sha256sum "$BACKUP_ARCHIVE" | awk '{print $1}')"
DECISION_EVIDENCE_ID="$(sha256sum "$DECISION_SOURCE/freshness.json" | awk '{print substr($1,1,16)}')"
[[ "$DECISION_EVIDENCE_ID" =~ ^[0-9a-f]{16}$ ]] \
  || die "$NODE recovery decision evidence identifier is malformed"
DECISION_EVIDENCE_TARGET="$RUN/decision-evidence-$DECISION_EVIDENCE_ID"
receipt_staged="$(mktemp "$RUN/.receipt.pass.XXXXXX")"
verdict_staged="$(mktemp "$RUN/.verdict.pass.XXXXXX")"
runtime_target="$(runtime_identity_file "$RUNTIME_ID")"
join_state_target="$(join_state_file "$NODE")"
joined_target="$(node_joined_marker "$NODE")"
recovery_publication_exit() {
  local rc=$? interrupted_verdict
  rm -f -- "$receipt_staged" "$verdict_staged"
  if ((rc != 0)) && [[ ! -s "$joined_target" ]]; then
    interrupted_verdict="$(mktemp "$RUN/.verdict.inconclusive.XXXXXX")"
    cat >"$interrupted_verdict" <<EOF
# Existing Host operator-state recovery: INCONCLUSIVE

The phase stopped with exit code $rc before its transactional joined marker
was committed. Any provisional local records are safe to resume and do not
imply PASS.
EOF
    chmod 0600 "$interrupted_verdict"
    mv -f -- "$interrupted_verdict" "$RUN/verdict.md"
  fi
  return "$rc"
}
trap recovery_publication_exit EXIT
jq -n \
  --arg node "$NODE" \
  --arg participant_address "$EXPECTED_ADDRESS" \
  --arg validator_key "$EXPECTED_VALIDATOR_KEY" \
  --arg chain_id "$EXPECTED_CHAIN_ID" \
  --arg genesis_sha256 "$EXPECTED_GENESIS_SHA256" \
  --arg runtime_id "$RUNTIME_ID" \
  --arg public_host "$PUBLIC_HOST" \
  --arg node_id "$EXPECTED_NODE_ID" \
  --arg ml_host "$EXPECTED_ML_HOST" \
  --arg backup_sha256 "$BACKUP_SHA256" \
  --arg backup_topology_binding "$BACKUP_TOPOLOGY_BINDING" \
  --arg decision_evidence_bundle "$(basename "$DECISION_EVIDENCE_TARGET")" \
  --argjson public_catching_up "$PUBLIC_CATCHING_UP" \
  --argjson remote_catching_up "$REMOTE_CATCHING_UP" \
  --argjson common_height "$COMMON_HEIGHT" \
  --argjson validator_height "$VALIDATOR_HEIGHT" \
  --argjson voting_power "$VOTING_POWER" \
  --argjson validator_effective "$VALIDATOR_EFFECTIVE" \
  --argjson consensus_signed_recently "$CONSENSUS_SIGNED_RECENTLY" \
  --slurpfile decision_evidence "$DECISION_SOURCE/freshness.json" \
  --argjson evidence_age_blocks "$EVIDENCE_AGE" '
  {schema_version:1,verdict:"PASS",node:$node,
   chain_id:$chain_id,genesis_sha256:$genesis_sha256,
   participant_address:$participant_address,validator_key:$validator_key,
   voting_power:$voting_power,validator_effective:$validator_effective,
   consensus_signed_recently:$consensus_signed_recently,
   common_height:$common_height,validator_height:$validator_height,
   public_catching_up:$public_catching_up,
   remote_catching_up:$remote_catching_up,
   runtime_id:$runtime_id,public_host:$public_host,
   node_id:$node_id,ml_host:(if $ml_host == "" then null else $ml_host end),
   backup_sha256:$backup_sha256,backup_topology_binding:$backup_topology_binding,
   evidence_age_blocks:$evidence_age_blocks,
   decision_evidence_bundle:$decision_evidence_bundle,
   decision_evidence:$decision_evidence[0],
   remote_identity_write:false}
' >"$receipt_staged"
cat >"$verdict_staged" <<EOF
# Existing Host operator-state recovery: PASS

$NODE matched the supplied validator backup, current Genesis, ACTIVE chain
participant, warm account, public Host, running P2P identity, baseline
deployment and configured GPU topology. Current consensus voting power is
$VOTING_POWER and validator_effective is $VALIDATOR_EFFECTIVE. This recovery
proves operator identity continuity, not fleet readiness. Only local operator
state was recovered; remote validator material was not changed.
EOF

"$ROOT/scripts/publish-running-host-recovery.sh" \
  "$NODE" "$EXPECTED_ADDRESS" "$RUNTIME_ID" "${GDC_RUN_ID:-manual}" \
  "$runtime_target" "$join_state_target" "$joined_target" \
  "$DECISION_SOURCE" "$DECISION_EVIDENCE_TARGET" \
  "$receipt_staged" "$verdict_staged" \
  "$RUN/receipt.json" "$RUN/verdict.md"
rm -rf -- "$DECISION_SOURCE"
trap evidence_exit_trap EXIT
printf 'PASS existing %s operator state recovered without remote identity changes: %s\n' "$NODE" "$RUN"
