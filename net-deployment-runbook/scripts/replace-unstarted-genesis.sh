#!/usr/bin/env bash
set -Eeuo pipefail

# Narrow recovery for a fresh chain that failed in InitGenesis before its first
# block. This script never deletes chain databases or edits validator/signer keys.
ROOT_DIR="${1:-}"
OLD_SHA256="${2:-}"
NEW_GENESIS="${3:-}"
EXPECTED_NEW_SHA256="${4:-}"
NODE_ALIAS="${5:-}"
ARCHIVE_ROOT="${6:-}"
MODE="${7:-replace-proposed-by}"
[[ "$ROOT_DIR" == /* && "$ARCHIVE_ROOT" == /* && "$NEW_GENESIS" == /* \
  && "$NODE_ALIAS" =~ ^[a-z0-9][a-z0-9_-]*$ \
  && "$OLD_SHA256" =~ ^[0-9a-f]{64}$ && "$EXPECTED_NEW_SHA256" =~ ^[0-9a-f]{64}$ \
  && ( "$MODE" == replace-proposed-by || "$MODE" == --refresh-zero-height-db ) ]] \
  || { echo 'invalid Genesis replacement arguments' >&2; exit 2; }

DEPLOY="$ROOT_DIR/deploy"
COMPOSE_FILE="$DEPLOY/compose.yaml"
ENV_FILE="$DEPLOY/.env"
SHARED_GENESIS="$ROOT_DIR/shared/genesis.json"
NODE_GENESIS="$ROOT_DIR/inference/config/genesis.json"
VALIDATOR_STATE="$ROOT_DIR/inference/data/priv_validator_state.json"
TMKMS_CONFIG="$ROOT_DIR/signer/tmkms/tmkms.toml"
TMKMS_STATE="$ROOT_DIR/signer/tmkms/state/priv_validator_state.json"
for path in "$ROOT_DIR" "$DEPLOY" "$COMPOSE_FILE" "$ENV_FILE" "$SHARED_GENESIS" \
  "$NODE_GENESIS" "$VALIDATOR_STATE" "$TMKMS_CONFIG" "$NEW_GENESIS"; do
  [[ -e "$path" && ! -L "$path" ]] || { echo "missing or unsafe required path: $path" >&2; exit 1; }
done
[[ -d "$ROOT_DIR" && -d "$DEPLOY" && -f "$COMPOSE_FILE" && -f "$ENV_FILE" \
  && -f "$SHARED_GENESIS" && -f "$NODE_GENESIS" && -f "$VALIDATOR_STATE" \
  && -f "$TMKMS_CONFIG" && -f "$NEW_GENESIS" ]] || { echo 'Genesis replacement paths have wrong types' >&2; exit 1; }
for path in "$ROOT_DIR/shared" "$ROOT_DIR/inference" "$ROOT_DIR/inference/config" \
  "$ROOT_DIR/inference/data" "$ROOT_DIR/identity" "$ROOT_DIR/dapi" \
  "$ROOT_DIR/signer" "$ROOT_DIR/signer/tmkms" \
  "$ROOT_DIR/signer/tmkms/state"; do
  [[ -d "$path" && ! -L "$path" ]] || { echo "unsafe Genesis replacement directory: $path" >&2; exit 1; }
done
[[ "$(sha256sum "$SHARED_GENESIS" | awk '{print $1}')" == "$OLD_SHA256" \
  && "$(sha256sum "$NODE_GENESIS" | awk '{print $1}')" == "$OLD_SHA256" ]] \
  || { echo 'both installed Genesis files must match the exact reviewed old hash' >&2; exit 1; }
[[ "$(sha256sum "$NEW_GENESIS" | awk '{print $1}')" == "$EXPECTED_NEW_SHA256" ]] \
  || { echo 'replacement Genesis does not match its approved hash' >&2; exit 1; }
[[ "$(awk -F= '$1 == "NODE_NAME" {print $2; exit}' "$ENV_FILE")" == "$NODE_ALIAS" \
  && "$(awk -F= '$1 == "IS_GENESIS" {print $2; exit}' "$ENV_FILE")" == true ]] \
  || { echo 'deployment is not the expected Genesis host' >&2; exit 1; }

# Enforce exactly one semantic change: every existing model proposed_by value
# becomes "genesis". Canonical ordering/whitespace is ignored; all other JSON
# content, including chain ID, time, validator set, keys and parameters, must
# remain identical.
jq -e 'type == "object" and (.app_state.inference.model_list | type == "array" and length > 0)
  and all(.app_state.inference.model_list[]; type == "object" and (.proposed_by | type == "string" and length > 0))' \
  "$SHARED_GENESIS" >/dev/null || { echo 'old Genesis has no valid model proposed_by fields' >&2; exit 1; }
jq -e 'type == "object" and (.app_state.inference.model_list | type == "array" and length > 0)
  and all(.app_state.inference.model_list[]; type == "object" and .proposed_by == "genesis")' \
  "$NEW_GENESIS" >/dev/null || { echo 'replacement Genesis does not set all model proposed_by values to genesis' >&2; exit 1; }
old_normalized="$(jq -cS '(.app_state.inference.model_list) |= map(del(.proposed_by))' "$SHARED_GENESIS")"
new_normalized="$(jq -cS '(.app_state.inference.model_list) |= map(del(.proposed_by))' "$NEW_GENESIS")"
[[ "$old_normalized" == "$new_normalized" ]] \
  || { echo 'replacement Genesis changes fields beyond model proposed_by' >&2; exit 1; }
changed_model_count="$(jq '[.app_state.inference.model_list[] | select(.proposed_by != "genesis")] | length' "$SHARED_GENESIS")"
if [[ "$MODE" == replace-proposed-by ]]; then
  (( changed_model_count > 0 )) || { echo 'replacement Genesis would not correct any model proposed_by values' >&2; exit 1; }
else
  [[ "$OLD_SHA256" == "$EXPECTED_NEW_SHA256" && "$changed_model_count" == 0 ]] \
    || { echo 'zero-height database refresh requires already-corrected identical Genesis hashes' >&2; exit 1; }
fi

jq -e 'type == "object" and (keys | sort) == ["height","round","step"]
  and .height == "0" and .round == 0 and .step == 0' "$VALIDATOR_STATE" >/dev/null \
  || { echo 'validator state is not at height/round/step zero' >&2; exit 1; }
grep -Eq '^state_file[[:space:]]*=[[:space:]]*"/root/\.tmkms/state/priv_validator_state\.json"[[:space:]]*$' "$TMKMS_CONFIG" \
  || { echo 'TMKMS state path is not the expected signer-owned file' >&2; exit 1; }
if [[ -e "$TMKMS_STATE" || -L "$TMKMS_STATE" ]]; then
  [[ -f "$TMKMS_STATE" && ! -L "$TMKMS_STATE" ]] \
    || { echo 'TMKMS state path is unsafe' >&2; exit 1; }
  jq -e 'type == "object" and .height == "0" and (.round | . == 0 or . == "0")
    and (.step | . == 0 or . == "0")' "$TMKMS_STATE" >/dev/null \
    || { echo 'external TMKMS state is not zero; refusing Genesis replacement' >&2; exit 1; }
fi

compose=(docker compose --env-file "$ENV_FILE" --profile '*' -f "$COMPOSE_FILE")
effective_compose="$("${compose[@]}" config --format json)"
jq -e --arg root "$ROOT_DIR" '
  def source_for($service; $target; $source):
    [.services[$service].volumes[]? | select(.target == $target and .type == "bind") | .source] == [$root + $source];
  source_for("node"; "/root/.inference"; "/inference")
  and source_for("node"; "/gdc-identity"; "/identity")
  and source_for("api"; "/root/.inference"; "/inference")
  and source_for("api"; "/root/.dapi"; "/dapi")
  and source_for("tmkms"; "/root/.tmkms"; "/signer/tmkms")
  and source_for("node"; "/root/genesis.json"; "/shared/genesis.json")
' <<<"$effective_compose" >/dev/null \
  || { echo 'effective Compose mounts are not the exact canonical Genesis, node, API and signer roots' >&2; exit 1; }
running="$("${compose[@]}" ps --status running -q node api tmkms)"
[[ -z "$running" ]] || { echo 'node, API or TMKMS is running; stop it before Genesis replacement' >&2; exit 1; }
logs="$("${compose[@]}" logs --no-color --tail=500 node 2>&1 | sed -E $'s/\033\\[[0-9;]*[[:alpha:]]//g')"
replay_line="$(grep -E 'ABCI Replay Blocks.*appHeight=' <<<"$logs" | tail -n 1 || true)"
grep -Eiq 'appHeight=0 .*stateHeight=0 .*storeHeight=0' <<<"$replay_line" \
  && grep -Eiq 'InitChain|InitGenesis' <<<"$logs" \
  && grep -Eiq 'proposed_by|ProposedBy' <<<"$logs" \
  || { echo 'stopped Core logs do not prove zero-height InitGenesis proposed_by failure' >&2; exit 1; }

validator_state_sha="$(sha256sum "$VALIDATOR_STATE" | awk '{print $1}')"
tmkms_state_sha=absent
[[ ! -f "$TMKMS_STATE" ]] || tmkms_state_sha="$(sha256sum "$TMKMS_STATE" | awk '{print $1}')"
tree_hash() {
  local root="$1" excluded="${2:-}"
  [[ -d "$root" && ! -L "$root" ]] || { printf 'absent\n'; return; }
  if [[ -n "$excluded" ]]; then excluded="./${excluded##*/}"; fi
  (
    cd "$root"
    if [[ -n "$excluded" ]]; then
      find . -xdev -type f ! -path "$excluded" -print0
    else
      find . -xdev -type f -print0
    fi | LC_ALL=C sort -z | xargs -0 -r sha256sum | sha256sum | awk '{print $1}'
  )
}
data_tree_sha="$(tree_hash "$ROOT_DIR/inference/data")"
config_tree_sha="$(tree_hash "$ROOT_DIR/inference/config" "$NODE_GENESIS")"
identity_tree_sha="$(tree_hash "$ROOT_DIR/identity")"
signer_tree_sha="$(tree_hash "$ROOT_DIR/signer")"
mkdir -p -- "$ARCHIVE_ROOT"
[[ -d "$ARCHIVE_ROOT" && ! -L "$ARCHIVE_ROOT" ]] || { echo 'archive root is unsafe' >&2; exit 1; }
replacement_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
archive_dir="$(mktemp -d "$ARCHIVE_ROOT/${replacement_id}-${NODE_ALIAS}-unstarted-genesis.XXXXXX")"
if [[ "$MODE" == replace-proposed-by ]]; then
  cp -p -- "$SHARED_GENESIS" "$archive_dir/shared-genesis.before.json"
  cp -p -- "$NODE_GENESIS" "$archive_dir/node-genesis.before.json"
fi
receipt="$archive_dir/replace-receipt.json"
jq -n -S --arg host "$NODE_ALIAS" --arg old "$OLD_SHA256" --arg new "$EXPECTED_NEW_SHA256" \
  --arg old_model_diff_count "$changed_model_count" \
  --arg validator_state "$validator_state_sha" --arg tmkms_state "$tmkms_state_sha" \
  --arg archive_data "data.before" \
  --arg timestamp "$replacement_id" \
  --arg mode "$MODE" --arg data_tree "$data_tree_sha" \
  '{schema_version:1,kind:"gdc-unstarted-genesis-replacement",host:$host,timestamp:$timestamp,mode:$mode,
    status:"intent",
    old_genesis_sha256:$old,new_genesis_sha256:$new,changed_model_proposed_by_count:($old_model_diff_count|tonumber),
    validator_state_sha256:$validator_state,tmkms_state_sha256:$tmkms_state,
    data_tree_sha256_before:$data_tree,
    evidence:{stopped_core_zero_height_initgenesis_panic:true,validator_state_zero:true,tmkms_state_zero:true},
    archived_data_path:(if $mode == "--refresh-zero-height-db" then $archive_data else null end),
    archived_shared_genesis:(if $mode == "replace-proposed-by" then "shared-genesis.before.json" else null end),
    archived_node_genesis:(if $mode == "replace-proposed-by" then "node-genesis.before.json" else null end)}' \
  >"$receipt"
chmod 0600 "$receipt"

shared_tmp=''; node_tmp=''
if [[ "$MODE" == replace-proposed-by ]]; then
  shared_tmp="$(mktemp "$ROOT_DIR/shared/.genesis-replacement.XXXXXX")"
  node_tmp="$(mktemp "$(dirname "$NODE_GENESIS")/.genesis-replacement.XXXXXX")"
  install -m "$(stat -c '%a' "$SHARED_GENESIS")" "$NEW_GENESIS" "$shared_tmp"
  install -m "$(stat -c '%a' "$NODE_GENESIS")" "$NEW_GENESIS" "$node_tmp"
  [[ "$(sha256sum "$shared_tmp" | awk '{print $1}')" == "$EXPECTED_NEW_SHA256" \
    && "$(sha256sum "$node_tmp" | awk '{print $1}')" == "$EXPECTED_NEW_SHA256" ]] \
    || { echo 'staged Genesis copy changed' >&2; exit 1; }
fi
data_archived=false

rollback() {
  local status=$?
  if (( status != 0 )) && [[ "$MODE" == replace-proposed-by ]] && { [[ "$(sha256sum "$SHARED_GENESIS" 2>/dev/null | awk '{print $1}')" == "$EXPECTED_NEW_SHA256" ]] \
     || [[ "$(sha256sum "$NODE_GENESIS" 2>/dev/null | awk '{print $1}')" == "$EXPECTED_NEW_SHA256" ]]; }; then
    cp -p -- "$archive_dir/shared-genesis.before.json" "$SHARED_GENESIS.rollback"
    cp -p -- "$archive_dir/node-genesis.before.json" "$NODE_GENESIS.rollback"
    mv -f -- "$SHARED_GENESIS.rollback" "$SHARED_GENESIS"
    mv -f -- "$NODE_GENESIS.rollback" "$NODE_GENESIS"
    printf '{"schema_version":1,"kind":"gdc-unstarted-genesis-replacement-rollback","reason":"replacement-incomplete"}\n' \
      >"$archive_dir/rollback-receipt.json"
  fi
  if (( status != 0 )) && [[ "$MODE" == --refresh-zero-height-db && "$data_archived" == true ]]; then
    if [[ -e "$ROOT_DIR/inference/data" && ! -L "$ROOT_DIR/inference/data" ]]; then
      mv -- "$ROOT_DIR/inference/data" "$archive_dir/data.zeroheight-recreated-failed"
    fi
    if [[ -d "$archive_dir/data.before" && ! -e "$ROOT_DIR/inference/data" ]]; then
      mv -- "$archive_dir/data.before" "$ROOT_DIR/inference/data"
    fi
    printf '{"schema_version":1,"kind":"gdc-unstarted-genesis-data-refresh-rollback","reason":"refresh-incomplete"}\n' \
      >"$archive_dir/rollback-receipt.json"
  fi
  rm -f -- "$shared_tmp" "$node_tmp"
  exit "$status"
}
trap rollback EXIT
if [[ "$MODE" == replace-proposed-by ]]; then
  mv -f -- "$shared_tmp" "$SHARED_GENESIS"
  mv -f -- "$node_tmp" "$NODE_GENESIS"
fi
if [[ "$MODE" == --refresh-zero-height-db ]]; then
  mv -- "$ROOT_DIR/inference/data" "$archive_dir/data.before"
  data_archived=true
  install -d -o "$(stat -c '%u' "$archive_dir/data.before")" \
    -g "$(stat -c '%g' "$archive_dir/data.before")" \
    -m "$(stat -c '%a' "$archive_dir/data.before")" "$ROOT_DIR/inference/data"
  cp -p -- "$archive_dir/data.before/priv_validator_state.json" "$VALIDATOR_STATE"
  [[ "$(find "$ROOT_DIR/inference/data" -mindepth 1 -print -quit)" == "$VALIDATOR_STATE" ]] \
    || { echo 'refreshed data directory contains unexpected files' >&2; exit 1; }
fi
data_tree_valid=true
if [[ "$MODE" == replace-proposed-by ]]; then
  [[ "$(tree_hash "$ROOT_DIR/inference/data")" == "$data_tree_sha" ]] || data_tree_valid=false
else
  [[ "$(tree_hash "$archive_dir/data.before")" == "$data_tree_sha" ]] || data_tree_valid=false
fi
if [[ "$(sha256sum "$SHARED_GENESIS" | awk '{print $1}')" != "$EXPECTED_NEW_SHA256" \
  || "$(sha256sum "$NODE_GENESIS" | awk '{print $1}')" != "$EXPECTED_NEW_SHA256" \
  || "$(sha256sum "$VALIDATOR_STATE" | awk '{print $1}')" != "$validator_state_sha" \
  || "$data_tree_valid" != true \
  || "$(tree_hash "$ROOT_DIR/inference/config" "$NODE_GENESIS")" != "$config_tree_sha" \
  || "$(tree_hash "$ROOT_DIR/identity")" != "$identity_tree_sha" \
  || "$(tree_hash "$ROOT_DIR/signer")" != "$signer_tree_sha" ]]; then
  echo 'post-replacement hash or preserved validator-state check failed' >&2
  exit 1
fi
jq -n -S --arg intent "replace-receipt.json" --arg new "$EXPECTED_NEW_SHA256" --arg mode "$MODE" \
  --arg data "$data_tree_sha" --arg config "$config_tree_sha" \
  --arg identity "$identity_tree_sha" --arg signer "$signer_tree_sha" \
  --arg data_current "$(tree_hash "$ROOT_DIR/inference/data")" \
  --arg data_archive "$(if [[ "$MODE" == --refresh-zero-height-db ]]; then printf '%s' 'data.before'; else printf '%s' 'not-moved'; fi)" \
  --arg timestamp "$(date -u +%Y%m%dT%H%M%SZ)" \
  '{schema_version:1,kind:"gdc-unstarted-genesis-replacement-complete",timestamp:$timestamp,mode:$mode,
    intent_receipt:$intent,installed_genesis_sha256:$new,inference_data_before_sha256:$data,
    inference_data_current_sha256:$data_current,archived_data_path:$data_archive,identity_state_preserved:true,
    config_except_genesis_tree_sha256:$config,
    identity_tree_sha256:$identity,signer_tree_sha256:$signer}' \
  >"$archive_dir/completion-receipt.json"
chmod 0600 "$archive_dir/completion-receipt.json"
printf 'READY replaced only proposed_by metadata in zero-height Genesis; archive=%s\n' "$archive_dir"
