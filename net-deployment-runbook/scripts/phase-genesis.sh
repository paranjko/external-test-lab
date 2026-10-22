#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
on_genesis_error() {
  local rc=$?
  printf 'FAILED Genesis command at line %s (exit %s)\n' "$1" "$rc" >&2
  exit "$rc"
}
trap 'on_genesis_error "$LINENO"' ERR
load_project
TIME_SPEC="${1:---time=+1m}"
[[ "$TIME_SPEC" =~ ^--time=\+([1-9][0-9]*)m$ ]] || die 'expected --time=+Nm'
GENESIS_LEAD_MINUTES="${BASH_REMATCH[1]}"
RUN="$GDC_HOME/runs/${GDC_RUN_ID:-manual}/genesis"
export EVIDENCE_PHASE_NAME=genesis
mkdir -p "$RUN"
GENESIS_MODE=legacy
candidate_mode_count=0
[[ "${GDC_GENESIS_PREPARE_ONLY:-false}" != true ]] || { GENESIS_MODE=prepare; candidate_mode_count=$((candidate_mode_count + 1)); }
[[ -z "${GDC_GENESIS_APPLY_CANDIDATE:-}" ]] || { GENESIS_MODE=apply; candidate_mode_count=$((candidate_mode_count + 1)); }
[[ -z "${GDC_GENESIS_RESUME_CANDIDATE:-}" ]] || { GENESIS_MODE=resume; candidate_mode_count=$((candidate_mode_count + 1)); }
(( candidate_mode_count <= 1 )) || die 'Genesis prepare, apply, and installed-candidate resume modes are mutually exclusive'
GENESIS_DEFER_SERVICES="${GDC_GENESIS_DEFER_SERVICES:-false}"
[[ "$GENESIS_MODE" != resume || "$GENESIS_DEFER_SERVICES" != true ]] || die 'installed-candidate resume cannot defer the faucet service'
GENESIS_SOFTWARE_SHA256=''
if [[ -n "${GDC_GENESIS_SOFTWARE_FILE:-}" ]]; then
  [[ -s "$GDC_GENESIS_SOFTWARE_FILE" ]] || die 'reviewed Genesis software fragment is absent or empty'
  GENESIS_SOFTWARE_SHA256="$(sha256sum "$GDC_GENESIS_SOFTWARE_FILE" | awk '{print $1}')"
  [[ "$GENESIS_SOFTWARE_SHA256" == "${GDC_GENESIS_SOFTWARE_SHA256:-}" ]] || die 'reviewed Genesis software SHA-256 mismatch'
fi
GENESIS_CONFIG_SHA256=''
if [[ -n "${GDC_GENESIS_CONFIG_FILE:-}" ]]; then
  [[ -s "$GDC_GENESIS_CONFIG_FILE" ]] || die 'reviewed Genesis config file is absent or empty'
  GENESIS_CONFIG_SHA256="$(sha256sum "$GDC_GENESIS_CONFIG_FILE" | awk '{print $1}')"
  [[ "$GENESIS_CONFIG_SHA256" == "${GDC_GENESIS_CONFIG_SHA256:-}" ]] || die 'reviewed Genesis config SHA-256 mismatch'
fi
if [[ "$GENESIS_MODE" != legacy ]]; then
  [[ -n "$GENESIS_CONFIG_SHA256" ]] || die 'candidate Genesis modes require --config-file and reviewed --config-sha256'
  [[ "$GENESIS_CONFIG_SHA256" =~ ^[0-9a-f]{64}$ ]] || die 'invalid reviewed Genesis config SHA-256'
  [[ -n "$GENESIS_SOFTWARE_SHA256" && "$GENESIS_SOFTWARE_SHA256" =~ ^[0-9a-f]{64}$ ]] || die 'candidate Genesis modes require reviewed --software-file and --software-sha256'
  software_profile="$(jq -er '.source.model_profile' "$GDC_GENESIS_SOFTWARE_FILE")" || die 'Genesis software fragment lacks a model profile'
  canonical_software="$RUN/canonical-genesis-software.json"
  "$ROOT/scripts/render-genesis-software.sh" "$software_profile" "$canonical_software" >/dev/null
  [[ "$(sha256sum "$canonical_software" | awk '{print $1}')" == "$GENESIS_SOFTWARE_SHA256" ]] \
    || die 'Genesis software fragment differs from canonical reviewed locks'
  jq -e --arg selected "$MODEL_ID" '
    .source.release_profile == "v2026.10.06" and
    .spec.deployment.software.model.id == $selected
  ' "$GDC_GENESIS_SOFTWARE_FILE" >/dev/null \
    || die 'Genesis software model does not match the active GDC model profile'
  export GDC_GENESIS_RUNTIME_CONTEXT=verified-fragment
  GDC_GENESIS_RELEASE_LOCK_SHA256="$(sha256sum "$ROOT/profiles/releases/v2026.10.06.lock" | awk '{print $1}')"
  export GDC_GENESIS_RELEASE_LOCK_SHA256
  export GDC_PROFILE_KIND=release IS_GENESIS=true
fi
assert_baseline_release
if [[ -n "${GDC_GENESIS_CONFIG_FILE:-}" ]]; then
  jq -e --arg selected "$MODEL_ID" '
    .app_state.inference.params.poc_params.model_id == $selected
    and any(.app_state.inference.model_list[]; .id == $selected)
  ' "$GDC_GENESIS_CONFIG_FILE" >/dev/null || die 'reviewed Genesis config selected model does not match the active GDC model profile'
fi
GENESIS_CANDIDATE_DIR="$GDC_HOME/genesis-candidate"
GENESIS_CANDIDATE_RECEIPT="$GDC_HOME/genesis-candidate.json"
assert_genesis_target_fresh() {
  ssh_ready "$GENESIS_NODE" || die 'fresh-remote Genesis preflight failed: Genesis host is unreachable'
  ssh -T "$GENESIS_NODE" "sudo test ! -e /srv/dai/deploy/compose.yaml && sudo test ! -e /srv/dai/node/compose.yaml && sudo test ! -e /srv/dai/data/inference/config/genesis.json && sudo test ! -d /srv/dai/data/inference/data && sudo test ! -d /srv/dai/node/inference/data && docker_names=\$(sudo docker ps --filter label=com.docker.compose.project.working_dir=/srv/dai/deploy --format '{{.Names}}') && legacy_docker_names=\$(sudo docker ps --filter label=com.docker.compose.project.working_dir=/srv/dai/node --format '{{.Names}}') && test -z \"\$docker_names\" && test -z \"\$legacy_docker_names\"" \
    || die 'fresh-remote Genesis preflight found a deployed or previously initialized Genesis; reset and verify the host first'
}
genesis_candidate_profile_sha256() {
  profile_hash
}
genesis_candidate_validate() {
  local expected_sha="$1" candidate_sha canonical_sha now_epoch time_epoch identity_sha account_sha
  [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || die 'candidate approval must be a lowercase SHA-256'
  [[ -s "$GENESIS_CANDIDATE_RECEIPT" && -s "$GENESIS_CANDIDATE_DIR/genesis.json" ]] || die 'Genesis candidate or receipt is missing'
  candidate_sha="$(sha256sum "$GENESIS_CANDIDATE_DIR/genesis.json" | awk '{print $1}')"
  [[ "$candidate_sha" == "$expected_sha" ]] || die 'Genesis candidate hash does not match explicit approval'
  canonical_sha="$(genesis_sha256 "$GENESIS_CANDIDATE_DIR/genesis.json")" || die 'failed to calculate canonical candidate Genesis hash'
  jq -e --arg alias "$GENESIS_NODE" --arg chain "$CHAIN_ID" --arg host "$GENESIS_PUBLIC_HOST" \
    --arg edge "$PUBLIC_EDGE_NODE" --arg inventory "$(sha256sum "$INVENTORY" | awk '{print $1}')" \
    --arg config "$GENESIS_CONFIG_SHA256" --arg software "$GENESIS_SOFTWARE_SHA256" \
    --arg profile "$(genesis_candidate_profile_sha256)" --arg candidate "$candidate_sha" --arg canonical "$canonical_sha" '
    .schema_version == 1 and .kind == "gdc-genesis-candidate" and
    .genesis_node == $alias and .chain_id == $chain and .public_host == $host and
    .public_edge == $edge and .inventory_sha256 == $inventory and .config_sha256 == $config and
    .profile_sha256 == $profile and .software_sha256 == $software and .candidate_sha256 == $candidate and
    .canonical_genesis_sha256 == $canonical and
    (.prepare_run_id | type == "string" and length > 0) and
    (.genesis_time | type == "string") and (.identity_path | type == "string") and
    (.account_path | type == "string")
  ' "$GENESIS_CANDIDATE_RECEIPT" >/dev/null || die 'Genesis candidate receipt does not match this alias, chain, config, or release'
  time_epoch="$(jq -er '.genesis_time' "$GENESIS_CANDIDATE_RECEIPT")"
  time_epoch="$(date -u -d "$time_epoch" +%s 2>/dev/null)" || die 'candidate Genesis time is invalid'
  now_epoch="$(date -u +%s)"
  if [[ "$GENESIS_MODE" != resume ]]; then
    (( time_epoch > now_epoch )) || die 'candidate Genesis time has expired; prepare a new candidate'
  fi
  identity_sha="$(jq -er '.identity_path' "$GENESIS_CANDIDATE_RECEIPT")"
  account_sha="$(jq -er '.account_path' "$GENESIS_CANDIDATE_RECEIPT")"
  [[ -s "$identity_sha" && -s "$account_sha" ]] || die 'candidate identity or account reference is missing'
  [[ "$(sha256sum "$identity_sha" | awk '{print $1}')" == "$(jq -er '.identity_sha256' "$GENESIS_CANDIDATE_RECEIPT")" ]] || die 'candidate identity changed after preparation'
  [[ "$(sha256sum "$account_sha" | awk '{print $1}')" == "$(jq -er '.account_sha256' "$GENESIS_CANDIDATE_RECEIPT")" ]] || die 'candidate account changed after preparation'
  for candidate_file in genesis-seeds.txt ceremony-record.json; do
    [[ -s "$GENESIS_CANDIDATE_DIR/$candidate_file" ]] || die "candidate file is missing: $candidate_file"
    [[ "$(sha256sum "$GENESIS_CANDIDATE_DIR/$candidate_file" | awk '{print $1}')" == "$(jq -er --arg file "$candidate_file" '.files[$file]' "$GENESIS_CANDIDATE_RECEIPT")" ]] \
      || die "candidate file changed after preparation: $candidate_file"
  done
  GENESIS_TIME="$(jq -er '.genesis_time' "$GENESIS_CANDIDATE_RECEIPT")"
  jq -e --arg chain "$CHAIN_ID" --arg time "$GENESIS_TIME" '.chain_id == $chain and .genesis_time == $time' "$GENESIS_CANDIDATE_DIR/genesis.json" >/dev/null \
    || die 'candidate Genesis chain ID or time disagrees with its receipt'
  GENESIS_CANDIDATE_SHA256="$candidate_sha"
  GENESIS_SHA256="$canonical_sha"
  GENESIS="$GENESIS_CANDIDATE_DIR"
}

if [[ "$GENESIS_MODE" == prepare ]]; then
  umask 077
  [[ ! -e "$STATE/joined/$GENESIS_NODE" ]] || die 'prepare-only refuses an existing joined Genesis; complete scoped network reset first'
  [[ ! -s "$GENESIS_CANDIDATE_RECEIPT" && ! -e "$GENESIS_CANDIDATE_DIR" ]] || die 'Genesis candidate already exists; preserve it or use a fresh run after scoped reset'
  [[ ! -s "$GENESIS/genesis.json" ]] || die 'prepare-only refuses existing local Genesis artifacts; archive/reset them before preparing'
  assert_genesis_target_fresh
fi

if [[ "$GENESIS_MODE" == apply ]]; then
  genesis_candidate_validate "${GDC_GENESIS_APPLY_CANDIDATE:-}"
  if [[ ! -e "$STATE/joined/$GENESIS_NODE" ]]; then
    assert_genesis_target_fresh
  fi
fi

assert_installed_genesis_candidate_runtime() {
  local expected_node_id status_doc public_genesis
  expected_node_id="$(jq -er '.node_id | select(test("^[0-9a-f]{40}$"))' "$IDENTITIES/$GENESIS_NODE.json")" \
    || die 'candidate Genesis identity lacks the expected node ID'
  ssh_ready "$GENESIS_NODE" || die 'installed-candidate resume preflight failed: Genesis host is unreachable'
  status_doc="$(ssh -T "$GENESIS_NODE" sudo -n bash -s -- \
    "$GENESIS_CANDIDATE_SHA256" "$GENESIS_SOFTWARE_SHA256" "$GENESIS_NODE" \
    "$DAPI_EXPECTED_VERSION" "$DAPI_EXPECTED_COMMIT" <<'REMOTE'
set -eu
candidate_sha="$1"; software_sha="$2"; node_name="$3"; dapi_version="$4"; dapi_commit="$5"
fail() { printf 'GDC_RESUME_GATE_FAIL=%s\n' "$1" >&2; exit 1; }
check_raw_hash() {
  local label="$1" file="$2" expected="$3" actual
  test -s "$file" || fail "$label-missing"
  actual="$(sha256sum "$file" | awk '{print $1}')"
  test "$actual" = "$expected" || fail "$label-sha256"
}
check_raw_hash candidate-shared /srv/dai/shared/genesis.json "$candidate_sha"
check_raw_hash candidate-inference /srv/dai/inference/config/genesis.json "$candidate_sha"
check_raw_hash approved-software-fragment /srv/dai/deploy/genesis-software.json "$software_sha"
test -s /srv/dai/deploy/.gdc-genesis-software || fail runtime-receipt-missing
jq -e --arg fragment "$software_sha" --slurpfile software /srv/dai/deploy/genesis-software.json '
  .kind == "gdc-genesis-runtime-install" and .fragment_sha256 == $fragment and
  .core.version == $software[0].spec.deployment.software.components.node.version and
  .core.commit == $software[0].spec.deployment.software.components.node.commit and
  .core.image == $software[0].spec.deployment.software.components.node.image and
  .core.binary_sha256 == $software[0].binary_sha256.inferenced and
  .dapi.version == $software[0].spec.deployment.software.components.api.version and
  .dapi.commit == $software[0].spec.deployment.software.components.api.commit and
  .dapi.image == $software[0].spec.deployment.software.components.api.image and
  .dapi.binary_sha256 == $software[0].binary_sha256.decentralized_api
' /srv/dai/deploy/.gdc-genesis-software >/dev/null || fail runtime-receipt-mismatch
check_installed_binary() {
  local label="$1" file="$2" fragment_key="$3" expected actual
  expected="$(jq -er "$fragment_key" /srv/dai/deploy/genesis-software.json)" || fail "$label-pin-missing"
  actual="$(sha256sum "$file" | awk '{print $1}')" || fail "$label-binary-missing"
  test "$actual" = "$expected" || fail "$label-binary-sha256"
}
check_installed_binary core /srv/dai/deploy/bootstrap-runtime/node/bin/inferenced .binary_sha256.inferenced
check_installed_binary api /srv/dai/deploy/bootstrap-runtime/api/bin/decentralized-api .binary_sha256.decentralized_api
env_value() { awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' /srv/dai/deploy/.env; }
test "$(env_value NODE_NAME)" = "$node_name" || fail env-node-name
test "$(env_value IS_GENESIS)" = true || fail env-genesis-mode
test "$(env_value GDC_BOOTSTRAP_SOFTWARE)" = true || fail env-bootstrap-mode
test "$(env_value GDC_PROFILE_KIND)" = release || fail env-release-profile
test "$(env_value GDC_JOIN_STATESYNC_ENABLE)" = false || fail env-state-sync-mode
test "$(env_value SYNC_WITH_SNAPSHOTS)" = false || fail env-snapshot-mode
test "$(env_value INFERENCED_IMAGE)" = "$(jq -er .spec.deployment.software.components.node.image /srv/dai/deploy/genesis-software.json)" || fail env-core-image
test "$(env_value DAPI_IMAGE)" = "$(jq -er .spec.deployment.software.components.api.image /srv/dai/deploy/genesis-software.json)" || fail env-api-image
test "$(env_value MLNODE_IMAGE)" = "$(jq -er .spec.deployment.software.components.mlnode.image /srv/dai/deploy/genesis-software.json)" || fail env-mlnode-image
test "$(env_value DAPI_EXPECTED_VERSION)" = "$dapi_version" || fail env-api-version
test "$(env_value DAPI_EXPECTED_COMMIT)" = "$dapi_commit" || fail env-api-commit
test -s /srv/dai/deploy/node-config.json || fail node-config-missing
jq -ne --slurpfile software /srv/dai/deploy/genesis-software.json --slurpfile config /srv/dai/deploy/node-config.json '
  def extra($args):
    if $args == "" then []
    elif $args == "--enable-auto-tool-choice --tool-call-parser hermes" then ["--enable-auto-tool-choice", "--tool-call-parser", "hermes"]
    elif $args == "--enable-auto-tool-choice --tool-call-parser hermes --kv-cache-dtype fp8 --kv-cache-memory-bytes 1073741824" then ["--enable-auto-tool-choice", "--tool-call-parser", "hermes", "--kv-cache-dtype", "fp8", "--kv-cache-memory-bytes", "1073741824"]
    elif $args == "--enforce-eager" then ["--enforce-eager"]
    else error("unapproved MLNode arguments") end;
  ($software[0].spec.deployment.software.model) as $model |
  ($config[0][0].models) as $models |
  ($software[0].model_profile.vllm_args) as $vllm_args |
  ($models | keys) == [$model.id] and
  ($models[$model.id].args == ["--tensor-parallel-size", ($model.tensor_parallel_size | tostring),
    "--dtype", $model.dtype, "--revision", $model.revision,
    "--max-num-seqs", ($model.max_num_seqs | tostring),
    "--gpu-memory-utilization", ($model.gpu_memory_utilization | tostring),
    "--max-model-len", ($model.context_length | tostring)] + extra($vllm_args))
' >/dev/null || fail rendered-model-config
curl -fsS http://127.0.0.1:26657/status
REMOTE
  )" || die 'installed-candidate resume preflight failed; see GDC_RESUME_GATE_FAIL for the failed check'
  jq -e --arg chain "$CHAIN_ID" --arg node_id "$expected_node_id" \
    '.result.node_info.network == $chain and .result.node_info.id == $node_id' <<<"$status_doc" >/dev/null \
    || die 'running Genesis reports a different chain ID or node identity than the prepared candidate'
  public_genesis="$(mktemp)"
  if ! capture_canonical_genesis "https://${GENESIS_PUBLIC_HOST}/chain-rpc/genesis" "$public_genesis"; then
    rm -f "$public_genesis"
    die 'installed-candidate resume could not read the public Genesis document'
  fi
  [[ "$(genesis_sha256 "$public_genesis")" == "$GENESIS_SHA256" ]] || {
    rm -f "$public_genesis"
    die 'public Genesis does not match the approved installed candidate'
  }
  rm -f "$public_genesis"
}

if [[ "$GENESIS_MODE" == resume ]]; then
  genesis_candidate_validate "${GDC_GENESIS_RESUME_CANDIDATE:-}"
fi

run_genesis_faucet() {
  if [[ "$GENESIS" == "$GENESIS_CANDIDATE_DIR" ]]; then
    GDC_HOME="$GDC_HOME" GDC_GENESIS_DIR="$GENESIS" \
      GDC_GENESIS_CANDIDATE_SHA256="$GENESIS_CANDIDATE_SHA256" \
      "$ROOT/scripts/phase-ops.sh" faucet
  else
    "$ROOT/scripts/phase-ops.sh" faucet
  fi
}

continue_genesis_bootstrap() {
  step 'Start the public DevNet faucet for independent Host joins'
  run_genesis_faucet

  if [[ "${GDC_GENESIS_BOOTSTRAP_ACCESS:-true}" == true ]]; then
    step 'Install the configured public edge'
    GDC_PUBLIC_EDGE_VERIFY=false "$ROOT/scripts/phase-ops.sh" edge
    step 'Install the Genesis participant edge configuration'
    "$ROOT/scripts/phase-ops.sh" edge-node "$GENESIS_NODE"
    step 'Refresh the public edge configuration after Genesis'
    GDC_PUBLIC_EDGE_VERIFY=false "$ROOT/scripts/phase-ops.sh" edge
    step 'Bootstrap authenticated inference for the single-validator network'
    "$ROOT/scripts/phase-bootstrap-access.sh"
    ops_env="$GDC_DATA_ROOT/.env"
    if [[ -s "$ops_env" ]] \
      && grep -Eq '^TELEGRAM_BOT_TOKEN=.+$' "$ops_env" \
      && ! grep -Eq '^TELEGRAM_BOT_TOKEN=replace-with-BotFather-token$' "$ops_env"; then
      step 'Refresh the Telegram inference consumer for the new gateway'
      GDC_ENV="$ops_env" "$ROOT/scripts/phase-gateway-access-key.sh" ensure telegram
      GDC_ENV="$ops_env" "$ROOT/scripts/phase-telegram-consumer.sh" apply
    else
      printf 'INFO Telegram consumer is not configured in the OPS environment; skipping its deployment\n'
    fi
    step 'Require bounded Genesis validator effectiveness before lifecycle success'
    "$ROOT/scripts/phase-join-acceptance.sh" "$GENESIS_NODE"
    step 'Create the Genesis validator recovery archive'
    "$ROOT/scripts/validator-backup.sh" create "$GENESIS_NODE"
    step 'Reconcile public monitoring from the fresh Genesis topology'
    "$ROOT/scripts/phase-ops.sh" monitoring
    step 'Verify the public status site'
    "$ROOT/scripts/phase-ops.sh" site
  else
    printf 'INCOMPLETE Genesis was created without bootstrap access; it is not a full lifecycle PASS\n' >&2
  fi
}

genesis_activation_is_current() {
  local address local_sha public_genesis participant
  [[ -e "$STATE/joined/$GENESIS_NODE" ]] || return 1
  [[ -s "$GENESIS/genesis.json" && -s "$ACCOUNTS/$GENESIS_NODE-cold.json" ]] || return 1
  address="$(jq -er .address "$ACCOUNTS/$GENESIS_NODE-cold.json")" || return 1
  local_sha="$(genesis_sha256 "$GENESIS/genesis.json")" || return 1
  public_genesis="$(mktemp)"
  if ! capture_canonical_genesis "https://${GENESIS_PUBLIC_HOST}/chain-rpc/genesis" "$public_genesis"; then
    rm -f "$public_genesis"
    return 1
  fi
  [[ "$(genesis_sha256 "$public_genesis")" == "$local_sha" ]] || { rm -f "$public_genesis"; return 1; }
  rm -f "$public_genesis"
  participant="$(ssh -T "$GENESIS_NODE" "curl -fsS http://127.0.0.1:1317/productscience/inference/inference/participant/$address" 2>/dev/null || true)"
  jq -e '.participant.status == "ACTIVE" or .participant.status == "PARTICIPANT_STATUS_ACTIVE" or .participant.status == 1' <<<"$participant" >/dev/null 2>&1
}

load_genesis_software_env() {
  GDC_RELEASE_PROFILE=v2026.10.06
  GONKA_RELEASE="$(jq -er '.spec.deployment.software.components.node.version' "$GDC_GENESIS_SOFTWARE_FILE")"
  GONKA_COMMIT="$(jq -er '.spec.deployment.software.components.node.commit' "$GDC_GENESIS_SOFTWARE_FILE")"
  INFERENCED_IMAGE="$(jq -er '.spec.deployment.software.components.node.image' "$GDC_GENESIS_SOFTWARE_FILE")"
  DAPI_IMAGE="$(jq -er '.spec.deployment.software.components.api.image' "$GDC_GENESIS_SOFTWARE_FILE")"
  DAPI_EXPECTED_VERSION="$(jq -er '.spec.deployment.software.components.api.version' "$GDC_GENESIS_SOFTWARE_FILE")"
  DAPI_EXPECTED_COMMIT="$(jq -er '.spec.deployment.software.components.api.commit' "$GDC_GENESIS_SOFTWARE_FILE")"
  MLNODE_GENERIC_IMAGE="$(jq -er '.spec.deployment.software.components.mlnode.image' "$GDC_GENESIS_SOFTWARE_FILE")"
  MODEL_ID="$(jq -er '.spec.deployment.software.model.id' "$GDC_GENESIS_SOFTWARE_FILE")"
  MODEL_SOURCE_REVISION="$(jq -er '.spec.deployment.software.model.revision' "$GDC_GENESIS_SOFTWARE_FILE")"
  MLNODE_CONTEXT_LENGTH="$(jq -er '.spec.deployment.software.model.context_length' "$GDC_GENESIS_SOFTWARE_FILE")"
  MLNODE_MAX_NUM_SEQS="$(jq -er '.spec.deployment.software.model.max_num_seqs' "$GDC_GENESIS_SOFTWARE_FILE")"
  MLNODE_GPU_MEMORY_UTILIZATION="$(jq -er '.spec.deployment.software.model.gpu_memory_utilization' "$GDC_GENESIS_SOFTWARE_FILE")"
  MLNODE_DTYPE="$(jq -er '.spec.deployment.software.model.dtype' "$GDC_GENESIS_SOFTWARE_FILE")"
  MLNODE_TENSOR_PARALLEL_SIZE="$(jq -er '.spec.deployment.software.model.tensor_parallel_size' "$GDC_GENESIS_SOFTWARE_FILE")"
  MLNODE_VLLM_ARGS="$(jq -er '.model_profile.vllm_args' "$GDC_GENESIS_SOFTWARE_FILE")"
  GDC_BOOTSTRAP_SOFTWARE=true
  export GDC_RELEASE_PROFILE GONKA_RELEASE GONKA_COMMIT INFERENCED_IMAGE DAPI_IMAGE
  export DAPI_EXPECTED_VERSION DAPI_EXPECTED_COMMIT MLNODE_GENERIC_IMAGE
  export MODEL_ID MODEL_SOURCE_REVISION MLNODE_CONTEXT_LENGTH MLNODE_MAX_NUM_SEQS MLNODE_GPU_MEMORY_UTILIZATION MLNODE_DTYPE MLNODE_TENSOR_PARALLEL_SIZE MLNODE_VLLM_ARGS GDC_BOOTSTRAP_SOFTWARE
}

assert_installed_genesis_candidate() {
  local expected_node_id status_doc public_genesis remote_command
  expected_node_id="$(jq -er '.node_id | select(test("^[0-9a-f]{40}$"))' "$IDENTITIES/$GENESIS_NODE.json")" \
    || die 'candidate Genesis identity lacks the expected node ID'
  remote_command="sudo test -s /srv/dai/shared/genesis.json && test \"\$(sudo sha256sum /srv/dai/shared/genesis.json | awk '{print \$1}')\" = '$GENESIS_CANDIDATE_SHA256' && sudo test -s /srv/dai/inference/config/genesis.json && test \"\$(sudo sha256sum /srv/dai/inference/config/genesis.json | awk '{print \$1}')\" = '$GENESIS_CANDIDATE_SHA256' && sudo test -s /srv/dai/deploy/genesis-software.json && test \"\$(sudo sha256sum /srv/dai/deploy/genesis-software.json | awk '{print \$1}')\" = '$GENESIS_SOFTWARE_SHA256' && sudo test -s /srv/dai/deploy/.gdc-genesis-software && sudo jq -e --arg fragment '$GENESIS_SOFTWARE_SHA256' --slurpfile software /srv/dai/deploy/genesis-software.json '.kind == \"gdc-genesis-runtime-install\" and .fragment_sha256 == \$fragment and .core.version == \$software[0].spec.deployment.software.components.node.version and .core.commit == \$software[0].spec.deployment.software.components.node.commit and .core.image == \$software[0].spec.deployment.software.components.node.image and .core.binary_sha256 == \$software[0].binary_sha256.inferenced and .dapi.version == \$software[0].spec.deployment.software.components.api.version and .dapi.commit == \$software[0].spec.deployment.software.components.api.commit and .dapi.image == \$software[0].spec.deployment.software.components.api.image and .dapi.binary_sha256 == \$software[0].binary_sha256.decentralized_api' /srv/dai/deploy/.gdc-genesis-software >/dev/null && sudo test \"\$(sudo sha256sum /srv/dai/deploy/bootstrap-runtime/node/bin/inferenced | awk '{print \$1}')\" = \"\$(sudo jq -er .binary_sha256.inferenced /srv/dai/deploy/genesis-software.json)\" && sudo test \"\$(sudo sha256sum /srv/dai/deploy/bootstrap-runtime/api/bin/decentralized-api | awk '{print \$1}')\" = \"\$(sudo jq -er .binary_sha256.decentralized_api /srv/dai/deploy/genesis-software.json)\" && sudo test \"\$(awk -F= '\$1 == \"NODE_NAME\" {print \$2; exit}' /srv/dai/deploy/.env)\" = '$GENESIS_NODE' && sudo test \"\$(awk -F= '\$1 == \"IS_GENESIS\" {print \$2; exit}' /srv/dai/deploy/.env)\" = true && sudo test \"\$(awk -F= '\$1 == \"GDC_BOOTSTRAP_SOFTWARE\" {print \$2; exit}' /srv/dai/deploy/.env)\" = true && sudo test \"\$(awk -F= '\$1 == \"GDC_PROFILE_KIND\" {print \$2; exit}' /srv/dai/deploy/.env)\" = release && sudo test \"\$(awk -F= '\$1 == \"INFERENCED_IMAGE\" {sub(/^[^=]*=/,\"\"); print; exit}' /srv/dai/deploy/.env)\" = \"\$(sudo jq -er .spec.deployment.software.components.node.image /srv/dai/deploy/genesis-software.json)\" && sudo test \"\$(awk -F= '\$1 == \"DAPI_IMAGE\" {sub(/^[^=]*=/,\"\"); print; exit}' /srv/dai/deploy/.env)\" = \"\$(sudo jq -er .spec.deployment.software.components.api.image /srv/dai/deploy/genesis-software.json)\" && sudo test \"\$(awk -F= '\$1 == \"MLNODE_GENERIC_IMAGE\" {sub(/^[^=]*=/,\"\"); print; exit}' /srv/dai/deploy/.env)\" = \"\$(sudo jq -er .spec.deployment.software.components.mlnode.image /srv/dai/deploy/genesis-software.json)\" && sudo test \"\$(awk -F= '\$1 == \"MODEL_ID\" {sub(/^[^=]*=/,\"\"); print; exit}' /srv/dai/deploy/.env)\" = \"\$(sudo jq -er .spec.deployment.software.model.id /srv/dai/deploy/genesis-software.json)\" && sudo test \"\$(awk -F= '\$1 == \"DAPI_EXPECTED_VERSION\" {print \$2; exit}' /srv/dai/deploy/.env)\" = '$DAPI_EXPECTED_VERSION' && sudo test \"\$(awk -F= '\$1 == \"DAPI_EXPECTED_COMMIT\" {print \$2; exit}' /srv/dai/deploy/.env)\" = '$DAPI_EXPECTED_COMMIT' && curl -fsS http://127.0.0.1:26657/status"
  ssh_ready "$GENESIS_NODE" || die 'installed-candidate resume preflight failed: Genesis host is unreachable'
  ssh -T "$GENESIS_NODE" "sudo test \"\$(awk -F= '\$1 == \"GDC_JOIN_STATESYNC_ENABLE\" {print \$2; exit}' /srv/dai/deploy/.env)\" = false && sudo test \"\$(awk -F= '\$1 == \"SYNC_WITH_SNAPSHOTS\" {print \$2; exit}' /srv/dai/deploy/.env)\" = false" \
    || die 'installed Genesis environment is not configured for the reviewed full-sync mode'
  status_doc="$(ssh -T "$GENESIS_NODE" "$remote_command")" || die 'installed Genesis candidate or pinned runtime receipt does not match the approved candidate'
  jq -e --arg chain "$CHAIN_ID" --arg node_id "$expected_node_id" \
    '.result.node_info.network == $chain and .result.node_info.id == $node_id' <<<"$status_doc" >/dev/null \
    || die 'running Genesis reports a different chain ID or node identity than the prepared candidate'
  public_genesis="$(mktemp)"
  if ! capture_canonical_genesis "https://${GENESIS_PUBLIC_HOST}/chain-rpc/genesis" "$public_genesis"; then
    rm -f "$public_genesis"
    die 'installed-candidate resume could not read the public Genesis document'
  fi
  [[ "$(genesis_sha256 "$public_genesis")" == "$GENESIS_SHA256" ]] || {
    rm -f "$public_genesis"
    die 'public Genesis does not match the approved installed candidate'
  }
  rm -f "$public_genesis"
}

if [[ "$GENESIS_MODE" == resume ]]; then
  load_genesis_software_env
  assert_installed_genesis_candidate_runtime
fi

if [[ -e "$STATE/joined/$GENESIS_NODE" ]]; then
  if ! genesis_activation_is_current; then
    die 'existing Genesis activation does not match the local ceremony or is not ACTIVE; reset the network before creating another Genesis'
  fi
  resume_sha="$(genesis_sha256 "$GENESIS/genesis.json")"
  write_phase_lineage "$RUN" "$CHAIN_ID" "$resume_sha" || die 'failed to bind resumed Genesis evidence to the active chain'
  if [[ "$GENESIS_DEFER_SERVICES" == true ]]; then
    printf 'READY candidate Genesis participant is ACTIVE; deferred services remain untouched\n'
    exit 0
  fi
  if [[ "$GENESIS_MODE" == resume ]]; then
    printf 'READY candidate Genesis participant is ACTIVE; resuming only the faucet service\n'
    run_genesis_faucet
    exit 0
  fi
  printf 'READY resuming Genesis bootstrap from the verified ACTIVE participant\n'
  continue_genesis_bootstrap
  exit 0
fi

if [[ "$GENESIS_MODE" == resume ]]; then
  GENESIS_RUNTIME_ID="$(runtime_id_for_participant "$(jq -er .address "$ACCOUNTS/$GENESIS_NODE-cold.json")")"
  record_runtime_identity "$GENESIS_NODE" "$(jq -er .address "$ACCOUNTS/$GENESIS_NODE-cold.json")" "$GENESIS_RUNTIME_ID"
  write_phase_lineage "$RUN" "$CHAIN_ID" "$GENESIS_SHA256" || die 'failed to bind resumed Genesis evidence to the installed candidate'
  step 'Synchronize the installed MLNode configuration with the active deployment'
  ssh -T "$GENESIS_NODE" 'cd /srv/dai/deploy && ./sync-node-config.sh'
  step 'Wait for the installed Genesis participant to synchronize'
  "$ROOT/03-join/wait-synced.sh" "https://$GENESIS_PUBLIC_HOST/chain-rpc" "https://$GENESIS_PUBLIC_HOST/chain-rpc"
  record_join_state "$GENESIS_NODE" NODE_SYNCED "$(jq -er .address "$ACCOUNTS/$GENESIS_NODE-cold.json")"
  step 'Restart the Genesis API and colocated MLNode only after synchronization'
  "$ROOT/03-join/restart-api-after-sync.sh" "$GENESIS_NODE"
  "$ROOT/03-join/grant-ml-ops.sh" "$GENESIS_NODE" "$IDENTITIES/$GENESIS_NODE.json" "$INVENTORY"
  "$ROOT/03-join/wait-active.sh" "https://$GENESIS_PUBLIC_HOST" "$(jq -er .address "$ACCOUNTS/$GENESIS_NODE-cold.json")"
  record_join_state "$GENESIS_NODE" ACTIVE "$(jq -er .address "$ACCOUNTS/$GENESIS_NODE-cold.json")"
  mkdir -p "$STATE/joined"
  touch "$STATE/joined/$GENESIS_NODE"
  persist_runtime_topology
  printf 'READY candidate Genesis participant is ACTIVE; starting only the faucet service\n'
  run_genesis_faucet
  exit 0
fi

if [[ "$GENESIS_MODE" != apply ]]; then
step 'Verify the operator inferenced CLI matches the selected release'
"$ROOT/scripts/ensure-inferenced-cli.sh"

# Genesis is the one-command path for a fresh, single-validator network.  It
# must not rely on an operator remembering preparatory phases from a previous
# rehearsal.  Scope host preparation and qualification to the requested
# Genesis alias; additional validators remain independent join operations.
GDC_PREPARE_HOSTS="$GENESIS_NODE" "$ROOT/scripts/phase-prepare.sh"
qualification_status=passed
if [[ "${GDC_GENESIS_SKIP_QUALIFICATION:-false}" == true ]]; then
  qualification_status=skipped_by_operator
  printf 'SKIP  ML qualification explicitly disabled by the Genesis operator\n'
else
  GDC_QUALIFY_HOSTS="$GENESIS_NODE" "$ROOT/scripts/phase-qualify-ml.sh"
  require_ml_qualification "$GENESIS_NODE"
fi
record_phase_profile genesis
printf 'ml_qualification=%s\n' "$qualification_status" >>"$STATE/phase-profiles/genesis.env"
printf 'PROFILE phase=genesis ml_qualification=%s\n' "$qualification_status"
genesis_identity_inputs=(
  "$SECRETS/operator.keyring"
  "$SECRETS/$GENESIS_NODE.keyring"
  "$SECRETS/$GENESIS_NODE.postgres"
  "$ACCOUNTS/$GENESIS_NODE-cold.json"
  "$ACCOUNTS/gdc-gateway-cold.json"
  "$ACCOUNTS/gdc-faucet-cold.json"
  "$IDENTITIES/$GENESIS_NODE.json"
)
identity_inputs_ready=true
for input in "${genesis_identity_inputs[@]}"; do
  [[ -s "$input" ]] || identity_inputs_ready=false
done
# A host reset deliberately removes the remote inference directory while it
# preserves the operator's local account and identity evidence. Those local
# files alone cannot start a new Genesis: the node must also have the
# identity-bootstrap config.toml that init-identity.sh creates on the host.
if [[ "$identity_inputs_ready" == true ]] \
  && ! ssh -T "$GENESIS_NODE" "test -s '$DATA_ROOT/inference/config/config.toml'"; then
  identity_inputs_ready=false
  printf 'READY remote Genesis identity state is absent; recreating it before Genesis\n'
fi
if [[ "$identity_inputs_ready" != true ]]; then
  step 'Create Genesis operator secrets, Genesis participant identities, and gateway account'
  "$ROOT/scripts/phase-identities.sh"
fi
for input in "${genesis_identity_inputs[@]}"; do
  [[ -s "$input" ]] || die "Genesis identity input was not created: $input"
done
GENESIS_TIME="$(date -u -d "+${GENESIS_LEAD_MINUTES} minutes" +%Y-%m-%dT%H:%M:%SZ)"

step "Build and verify the one-participant Genesis at $GENESIS_TIME"
if [[ "$GENESIS_MODE" == prepare ]]; then
  mkdir -m 0700 "$GENESIS_CANDIDATE_DIR"
  GENESIS="$GENESIS_CANDIDATE_DIR"
fi
genesis_build_args=(--inventory "$INVENTORY" --identities-dir "$IDENTITIES" --secrets-dir "$SECRETS" --genesis-time "$GENESIS_TIME" --output-dir "$GENESIS")
if [[ "$GENESIS_MODE" == prepare ]]; then
  genesis_build_args+=(--candidate-only)
  INFERENCED_HOME="$RUN/candidate-operator-home"
  [[ -d "$STATE/operator-home/keyring-file" ]] || die 'candidate-only build requires the Genesis operator keyring from the identity phase'
  mkdir -p "$INFERENCED_HOME"
  chmod 0700 "$INFERENCED_HOME"
  cp -a "$STATE/operator-home/keyring-file" "$INFERENCED_HOME/keyring-file"
  export INFERENCED_HOME
fi
if [[ -n "${GDC_GENESIS_CONFIG_FILE:-}" ]]; then
  genesis_build_args+=(--config-file "$GDC_GENESIS_CONFIG_FILE")
fi
"$ROOT/01-identities-genesis/build-genesis.sh" "${genesis_build_args[@]}"
genesis_verify_args=("$GENESIS/genesis.json" "$GENESIS/genesis.sha256" "$CHAIN_ID")
if [[ -n "${GDC_GENESIS_CONFIG_FILE:-}" ]]; then
  genesis_verify_args+=(--config-file "$GDC_GENESIS_CONFIG_FILE")
fi
"$ROOT/01-identities-genesis/verify-genesis.sh" "${genesis_verify_args[@]}"
if ! GENESIS_SHA256="$(genesis_sha256 "$GENESIS/genesis.json")"; then
  die 'failed to calculate the canonical Genesis SHA-256'
fi
if [[ "$GENESIS_MODE" == prepare ]]; then
  GENESIS_CANDIDATE_SHA256="$(sha256sum "$GENESIS/genesis.json" | awk '{print $1}')"
fi
if [[ "$GENESIS_MODE" != prepare ]]; then
  if ! write_phase_lineage "$RUN" "$CHAIN_ID" "$GENESIS_SHA256"; then
    die 'failed to bind the Genesis evidence to this lifecycle run'
  fi
fi
for profile_field in genesis_sha256 genesis_overrides_sha256; do
  if ! profile_value="$(jq -er --arg field "$profile_field" '.[$field]' "$GENESIS/ceremony-record.json")"; then
    die "Genesis ceremony record is missing $profile_field"
  fi
  printf '%s=%s\n' "$profile_field" "$profile_value" >>"$STATE/phase-profiles/genesis.env"
  printf 'PROFILE phase=genesis %s=%s\n' "$profile_field" "$profile_value"
done
if [[ "$GENESIS_MODE" == prepare ]]; then
  identity_file="$IDENTITIES/$GENESIS_NODE.json"
  account_file="$ACCOUNTS/$GENESIS_NODE-cold.json"
  identity_sha256="$(sha256sum "$identity_file" | awk '{print $1}')"
  account_sha256="$(sha256sum "$account_file" | awk '{print $1}')"
  candidate_receipt_tmp="$GENESIS_CANDIDATE_RECEIPT.tmp"
  jq -n --arg alias "$GENESIS_NODE" --arg chain "$CHAIN_ID" --arg host "$GENESIS_PUBLIC_HOST" \
    --arg edge "$PUBLIC_EDGE_NODE" --arg inventory "$(sha256sum "$INVENTORY" | awk '{print $1}')" \
    --arg config "$GENESIS_CONFIG_SHA256" --arg software "$GENESIS_SOFTWARE_SHA256" \
    --arg profile "$(genesis_candidate_profile_sha256)" --arg genesis_time "$GENESIS_TIME" \
    --arg candidate "$GENESIS_CANDIDATE_SHA256" --arg canonical "$GENESIS_SHA256" \
    --arg identity "$identity_file" --arg identity_sha "$identity_sha256" \
    --arg account "$account_file" --arg account_sha "$account_sha256" --arg prepare_run "${GDC_RUN_ID:-manual}" \
    --arg seeds_sha "$(sha256sum "$GENESIS/genesis-seeds.txt" | awk '{print $1}')" \
    --arg ceremony_sha "$(sha256sum "$GENESIS/ceremony-record.json" | awk '{print $1}')" \
    '{schema_version:1,kind:"gdc-genesis-candidate",prepare_run_id:$prepare_run,genesis_node:$alias,chain_id:$chain,public_host:$host,public_edge:$edge,inventory_sha256:$inventory,config_sha256:$config,software_sha256:$software,profile_sha256:$profile,genesis_time:$genesis_time,candidate_sha256:$candidate,canonical_genesis_sha256:$canonical,identity_path:$identity,identity_sha256:$identity_sha,account_path:$account,account_sha256:$account_sha,files:{"genesis-seeds.txt":$seeds_sha,"ceremony-record.json":$ceremony_sha}}' \
    >"$candidate_receipt_tmp"
  chmod 0600 "$candidate_receipt_tmp"
  mv "$candidate_receipt_tmp" "$GENESIS_CANDIDATE_RECEIPT"
  chmod a-w "$GENESIS/genesis.json" "$GENESIS_CANDIDATE_RECEIPT"
  printf 'CANDIDATE candidate_sha256=%s genesis_sha256=%s config_sha256=%s receipt=%s\n' "$GENESIS_CANDIDATE_SHA256" "$GENESIS_SHA256" "$GENESIS_CONFIG_SHA256" "$GENESIS_CANDIDATE_RECEIPT"
  printf 'PREPARE ONLY: this step performed identity and host preparation. Run only after scoped reset; no deployment or start was performed.\n'
  exit 0
fi
else
  printf 'READY applying the exact prepared Genesis candidate %s\n' "$GDC_GENESIS_APPLY_CANDIDATE"
  write_phase_lineage "$RUN" "$CHAIN_ID" "$GENESIS_SHA256" || die 'failed to bind approved Genesis candidate to this lifecycle run'
fi

step "Render only $GENESIS_NODE"
NODE="$GENESIS_NODE"
if [[ "$GENESIS_MODE" != legacy ]]; then
  load_genesis_software_env
fi
NODE_DIR="$GENERATED/nodes/$NODE"
mkdir -p "$NODE_DIR"
if [[ "$GENESIS_DEFER_SERVICES" != true ]]; then
  mkdir -p "$GENERATED/edge" "$GENERATED/agents"
fi
GENESIS_RUNTIME_ID="$(runtime_id_for_participant "$(jq -er .address "$ACCOUNTS/$NODE-cold.json")")"
record_runtime_identity "$NODE" "$(jq -er .address "$ACCOUNTS/$NODE-cold.json")" "$GENESIS_RUNTIME_ID"
"$ROOT/02-node/render-node-env.sh" --inventory "$INVENTORY" --node-name "$NODE" --account-public "$ACCOUNTS/$NODE-cold.json" --seeds-file "$GENESIS/genesis-seeds.txt" --secrets-dir "$SECRETS" --output "$NODE_DIR/.env" >/dev/null
"$ROOT/02-node/render-node-config.sh" --node-name "$NODE" --runtime-id "$GENESIS_RUNTIME_ID" --output "$NODE_DIR/node-config.json" >/dev/null
if [[ "$GENESIS_DEFER_SERVICES" != true ]]; then
  "$ROOT/04-ops/edge-node/render-env.sh" --inventory "$INVENTORY" --node-name "$NODE" --output "$GENERATED/edge/$NODE.env"
  "$ROOT/04-ops/agent/render-env.sh" --inventory "$INVENTORY" --host "$NODE" --output "$GENERATED/agents/$NODE.env"
fi

step "Install $NODE deployment"
ssh_ready "$NODE" || die "$NODE is unreachable; Genesis cannot be launched"
REMOTE="/tmp/gdc-deploy-$$-$NODE"
ssh "$NODE" "rm -rf '$REMOTE' && mkdir -p '$REMOTE'"
rsync -a "$ROOT/02-node/" "$NODE:$REMOTE/02-node/"
rsync -a "$ROOT/03-join/" "$NODE:$REMOTE/03-join/"
if [[ "$GENESIS_DEFER_SERVICES" != true ]]; then
  rsync -a "$ROOT/04-ops/edge-node/" "$NODE:$REMOTE/edge/"
  rsync -a "$ROOT/04-ops/agent/" "$NODE:$REMOTE/agent/"
fi
scp -q "$NODE_DIR/.env" "$NODE:$REMOTE/node.env"
scp -q "$NODE_DIR/node-config.json" "$NODE:$REMOTE/node-config.json"
scp -q "$GENESIS/genesis.json" "$NODE:$REMOTE/genesis.json"
if [[ "$GENESIS_DEFER_SERVICES" != true ]]; then
  scp -q "$GENERATED/edge/$NODE.env" "$NODE:$REMOTE/edge.env"
  scp -q "$GENERATED/agents/$NODE.env" "$NODE:$REMOTE/agent.env"
fi
if [[ "$GENESIS_MODE" != legacy ]]; then
  scp -q "$GDC_GENESIS_SOFTWARE_FILE" "$NODE:$REMOTE/genesis-software.json"
fi
install_software_args=''
if [[ "$GENESIS_MODE" != legacy ]]; then
  install_software_args="--genesis-software '$REMOTE/genesis-software.json' --genesis-software-sha256 '$GENESIS_SOFTWARE_SHA256'"
fi
node_install_command="sudo '$REMOTE/02-node/install-node.sh' --node-name '$NODE' --env '$REMOTE/node.env' --node-config '$REMOTE/node-config.json' --genesis '$REMOTE/genesis.json' $install_software_args --local-ml"
if [[ "$GENESIS_DEFER_SERVICES" == true ]]; then
  ssh -T "$NODE" "$node_install_command && rm -rf '$REMOTE'"
else
  edge_install_args="--node-name '$NODE'"
  if [[ "$NODE" == "$PUBLIC_EDGE_NODE" ]]; then edge_install_args=''; fi
  ssh -T "$NODE" "$node_install_command && sudo '$REMOTE/edge/install-edge.sh' '$REMOTE/edge.env' $edge_install_args && sudo '$REMOTE/agent/install-agent.sh' '$NODE' '$REMOTE/agent.env' --gpu && rm -rf '$REMOTE'"
fi

step 'Start the Genesis participant'
if [[ "$GENESIS_DEFER_SERVICES" != true ]]; then
  edge_start_path=/srv/dai/deploy/edge
  if [[ "$NODE" == "$PUBLIC_EDGE_NODE" ]]; then edge_start_path=/srv/dai/edge; fi
  start_stack "$NODE" "$edge_start_path"
  start_stack "$NODE" /srv/dai/deploy/monitoring-agent
fi
ssh "$NODE" "cd /srv/dai/deploy && ./start-node.sh"

step 'Activate Genesis ML operations'
"$ROOT/03-join/wait-synced.sh" "https://$GENESIS_PUBLIC_HOST/chain-rpc" "https://$GENESIS_PUBLIC_HOST/chain-rpc"
record_join_state "$NODE" NODE_SYNCED "$(jq -er .address "$ACCOUNTS/$NODE-cold.json")"
step 'Restart the Genesis API and colocated MLNode only after synchronization'
"$ROOT/03-join/restart-api-after-sync.sh" "$NODE"
"$ROOT/03-join/grant-ml-ops.sh" "$NODE" "$IDENTITIES/$NODE.json" "$INVENTORY"
"$ROOT/03-join/wait-active.sh" "https://$GENESIS_PUBLIC_HOST" "$(jq -er .address "$ACCOUNTS/$NODE-cold.json")"
record_join_state "$NODE" ACTIVE "$(jq -er .address "$ACCOUNTS/$NODE-cold.json")"
mkdir -p "$STATE/joined"
touch "$STATE/joined/$NODE"
persist_runtime_topology
printf '\nGenesis launched with %s as the only participant.\n' "$NODE"

if [[ "$GENESIS_DEFER_SERVICES" == true ]]; then
  printf 'READY Genesis candidate applied and participant ACTIVE; deferred faucet, gateway, access, monitoring, and site services were not run\n'
  exit 0
fi
continue_genesis_bootstrap
