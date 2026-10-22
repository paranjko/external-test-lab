#!/usr/bin/env bash
# Read-only proof that a Host stopped after temporary JOIN identity creation,
# before a deployment, chain database, or signature was created.
set -Eeuo pipefail

usage() {
  echo 'Usage: check-join-identity-ready-target.sh NODE NODE_ID CONSENSUS_PUBKEY CHAIN_ID [--root DIR]' >&2
  exit 2
}

[[ $# -ge 4 ]] || usage
node="$1"; expected_node_id="$2"; expected_consensus="$3"; expected_chain="$4"
shift 4
root=/srv/dai
while (($#)); do
  case "$1" in
    --root) [[ -n "${2:-}" ]] || usage; root="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$EUID" == 0 ]] || { echo 'identity-ready target check requires root' >&2; exit 1; }
[[ "$node" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ && "$expected_node_id" =~ ^[0-9a-f]{40}$ \
  && "$expected_consensus" =~ ^[A-Za-z0-9+/]{43}=$ \
  && "$expected_chain" =~ ^[a-z0-9][a-z0-9-]{0,127}$ \
  && "$root" =~ ^/[A-Za-z0-9_./-]+$ && -d "$root" && ! -L "$root" ]] \
  || { echo 'invalid identity-ready target check input' >&2; exit 2; }

refuse() { printf 'JOIN_IDENTITY_READY_TARGET_NOT_CLEAN %s\n' "$1" >&2; exit 1; }
require_regular() {
  local path="$1"
  [[ -f "$path" && ! -L "$path" && -s "$path" ]] || refuse "missing_or_unsafe_identity_file=$path"
}

identity="$root/identity"
signer="$root/signer/tmkms"
node_key="$identity/p2p/node_key.json"
softsign="$signer/secrets/priv_validator_key.softsign"
signer_state="$signer/state/priv_validator_state.json"
warm_keyring="$identity/warm/keyring-file"
require_regular "$node_key"
require_regular "$softsign"
require_regular "$signer_state"
[[ -d "$warm_keyring" && ! -L "$warm_keyring" ]] || refuse 'warm_keyring_missing_or_unsafe=true'
[[ -d "$identity" && ! -L "$identity" && -d "$root/signer" && ! -L "$root/signer" ]] \
  || refuse 'retained_identity_root_missing_or_unsafe=true'
for directory in "$identity" "$identity/p2p" "$identity/warm" "$root/signer" "$signer" \
  "$signer/secrets" "$signer/state" "$root/inference" "$root/inference/config"; do
  [[ -d "$directory" && ! -L "$directory" ]] || refuse "identity_bootstrap_directory_missing_or_unsafe=$directory"
done
[[ -n "$(find "$warm_keyring" -mindepth 1 -maxdepth 2 -type f -print -quit)" ]] \
  || refuse 'warm_keyring_contents_missing=true'
[[ -z "$(find "$identity" "$root/signer" "$root/inference" "$root/identity-bootstrap" -type l -print -quit)" ]] \
  || refuse 'symlink_found_in_identity_ready_roots=true'
[[ "$(find "$identity" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')" == 'p2p warm ' ]] \
  || refuse 'unrecognized_identity_root_residue=true'
[[ "$(find "$identity/p2p" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')" == 'node_key.json ' ]] \
  || refuse 'unrecognized_p2p_identity_residue=true'
[[ "$(find "$identity/warm" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')" == 'keyring-file ' ]] \
  || refuse 'unrecognized_warm_identity_residue=true'
[[ "$(find "$root/signer" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')" == 'tmkms ' ]] \
  || refuse 'unrecognized_signer_root_residue=true'
for directory in "$signer/secrets" "$signer/state"; do
  [[ ! -L "$directory" ]] || refuse "unsafe_signer_directory=$directory"
done
while IFS= read -r entry; do
  case "${entry##*/}" in
    secrets|state|tmkms.toml) ;;
    # The pinned softsign image creates this empty directory under its
    # persistent config root during identity initialization.
    schema)
      [[ -d "$entry" && ! -L "$entry" \
        && -z "$(find "$entry" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
        || refuse 'unexpected_tmkms_schema_residue=true' ;;
    *) refuse "unrecognized_tmkms_residue=$entry" ;;
  esac
done < <(find "$signer" -mindepth 1 -maxdepth 1 -print)
while IFS= read -r entry; do
  case "${entry##*/}" in priv_validator_key.softsign|kms-identity.key)
    [[ -f "$entry" && ! -L "$entry" ]] || refuse 'unsafe_tmkms_secret_entry=true' ;;
    *) refuse 'unrecognized_tmkms_secret_residue=true' ;;
  esac
done < <(find "$signer/secrets" -mindepth 1 -maxdepth 1 -print)
while IFS= read -r entry; do
  case "${entry##*/}" in priv_validator_state.json)
    [[ -f "$entry" && ! -L "$entry" ]] || refuse 'unsafe_tmkms_state_entry=true' ;;
    *) refuse 'unrecognized_tmkms_state_residue=true' ;;
  esac
done < <(find "$signer/state" -mindepth 1 -maxdepth 1 -print)
[[ -d "$root/identity-bootstrap" && ! -L "$root/identity-bootstrap" ]] \
  || refuse 'identity_bootstrap_workspace_missing_or_unsafe=true'
[[ "$(find "$root/identity-bootstrap" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')" == '02-node ' ]] \
  || refuse 'unrecognized_identity_bootstrap_workspace_residue=true'
for transient in "$root/identity-bootstrap/bootstrap.env" "$root/identity-bootstrap/$node.json" \
  "$root/identity-bootstrap/$node-warm.mnemonic" "$root/identity-bootstrap/$node-warm.restore.mnemonic"; do
  [[ ! -e "$transient" && ! -L "$transient" ]] || refuse 'identity_bootstrap_secret_or_transient_remains=true'
done

# The only validator data accepted at IDENTITY_READY is init-only output from
# the temporary key bootstrap. This mirrors install-node.sh's fresh-Genesis
# guard, but does not invoke the installer or mutate any path.
check_init_root() {
  local base="$1" config="$1/inference/config" data="$1/inference/data" path
  local -a expected_config=(app.toml client.toml config.toml genesis.json node_key.json priv_validator_key.json)
  [[ ! -e "$base/deploy" && ! -L "$base/deploy" ]] || refuse "deployment_exists=$base/deploy"
  [[ ! -e "$base/shared/genesis.json" && ! -L "$base/shared/genesis.json" ]] || refuse "shared_genesis_exists=$base/shared/genesis.json"
  [[ ! -e "$base/inference/cosmovisor" && ! -L "$base/inference/cosmovisor" \
    && ! -e "$base/dapi/cosmovisor" && ! -L "$base/dapi/cosmovisor" ]] \
    || refuse "cosmovisor_state_exists=$base"
  [[ ! -e "$base/inference/.node_initialized" && ! -L "$base/inference/.node_initialized" ]] \
    || refuse "node_initialized_marker_exists=$base/inference/.node_initialized"
  if [[ -e "$base/inference" || -L "$base/inference" ]]; then
    [[ -d "$base/inference" && ! -L "$base/inference" ]] || refuse "unsafe_inference_root=$base/inference"
  fi
  if [[ -d "$data" ]]; then
    [[ ! -L "$data" ]] || refuse "unsafe_inference_data=$data"
    mapfile -t entries < <(find "$data" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
    if ((${#entries[@]})); then
      [[ ${#entries[@]} == 1 && "${entries[0]}" == priv_validator_state.json \
        && -f "$data/priv_validator_state.json" && ! -L "$data/priv_validator_state.json" ]] \
        || refuse "application_or_consensus_database_exists=$data"
      jq -e 'type == "object" and (keys | sort) == ["height","round","step"]
        and .height == "0" and .round == 0 and .step == 0' "$data/priv_validator_state.json" >/dev/null \
        || refuse "nonzero_init_validator_state=$data/priv_validator_state.json"
    fi
  elif [[ -e "$data" || -L "$data" ]]; then
    refuse "unsafe_inference_data=$data"
  fi
  [[ -d "$config" && ! -L "$config" ]] || refuse "init_inference_config_missing_or_unsafe=$config"
  mapfile -t entries < <(find "$config" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
  expected_sorted="$(printf '%s\n' "${expected_config[@]}" | LC_ALL=C sort)"
  [[ "$(printf '%s\n' "${entries[@]}")" == "$expected_sorted" ]] \
    || refuse "non_init_inference_config_inventory=$config"
  for name in "${entries[@]}"; do
    path="$config/$name"
    [[ -f "$path" && ! -L "$path" ]] || refuse "unsafe_init_inference_config=$path"
  done
  jq -e --arg chain "$expected_chain" '
    .chain_id == $chain and .initial_height == 1 and .app_hash == null and
    .app_state.genutil.gen_txs == [] and .app_state.auth.accounts == [] and
    .app_state.staking.validators == []
  ' "$config/genesis.json" >/dev/null || refuse "non_default_init_genesis=$config/genesis.json"
  cmp -s "$config/node_key.json" "$node_key" || refuse 'init_p2p_key_differs_from_retained_identity=true'
}

check_init_root "$root"
[[ "$(find "$root/inference" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')" == 'config data ' ]] \
  || refuse 'unrecognized_inference_root_residue=true'
# Legacy per-alias deployments/data are never resumed. Even a directory left
# by an older stack requires its explicit migration/recovery workflow.
legacy="$root/$node"
if [[ -e "$legacy" || -L "$legacy" ]]; then
  [[ -d "$legacy" && ! -L "$legacy" ]] || refuse 'legacy_alias_root_unsafe=true'
  for path in deploy data shared inference dapi agent node; do
    [[ ! -e "$legacy/$path" && ! -L "$legacy/$path" ]] || refuse "legacy_runtime_residue=$legacy/$path"
  done
  [[ -z "$(find "$legacy" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
    || refuse 'legacy_alias_root_has_unrecognized_residue=true'
fi

for path in "$root/data" "$root/dapi" "$root/agent" "$root/node" "$root/edge"; do
  [[ ! -e "$path" && ! -L "$path" ]] || refuse "runtime_or_independent_layout_exists=$path"
done
if [[ -e "$root/shared" || -L "$root/shared" ]]; then
  [[ -d "$root/shared" && ! -L "$root/shared" \
    && -z "$(find "$root/shared" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
    || refuse 'shared_root_has_runtime_or_unrecognized_content=true'
fi
while IFS= read -r entry; do
  case "${entry##*/}" in
    agent|backups|data|data.generations|dapi|deploy|edge|hf-cache|identity|identity-bootstrap|inference|monitoring-agent|node|ops|shared|signer) ;;
    *) refuse "unrecognized_validator_root_residue=$entry" ;;
  esac
done < <(find "$root" -mindepth 1 -maxdepth 1 -print)
for preserved in backups hf-cache monitoring-agent ops shared; do
  if [[ -e "$root/$preserved" || -L "$root/$preserved" ]]; then
    [[ -d "$root/$preserved" && ! -L "$root/$preserved" ]] \
      || refuse "preserved_root_unsafe=$preserved"
  fi
done
if [[ -e "$root/data.generations" || -L "$root/data.generations" ]]; then
  [[ -d "$root/data.generations" && ! -L "$root/data.generations" ]] \
    || refuse 'unsafe_data_generations_parent=true'
  [[ "$(stat -c %m -- "$root/data.generations")" != "$root/data.generations" ]] \
    || refuse 'mounted_data_generations_parent=true'
  [[ -z "$(find "$root/data.generations" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
    || refuse 'nonempty_data_generations_parent=true'
fi

# Validate both retained keys without ever printing private material.
jq -e 'type == "object" and (keys == ["priv_key"]) and
  (.priv_key | type == "object" and (keys | sort) == ["type","value"]) and
  .priv_key.type == "tendermint/PrivKeyEd25519" and (.priv_key.value | type == "string")' \
  "$node_key" >/dev/null || refuse 'retained_p2p_key_schema_invalid=true'
key_work="$(mktemp -d)"
trap 'rm -rf -- "$key_work"' EXIT
jq -er .priv_key.value "$node_key" >"$key_work/node-key.b64"
base64 -d "$key_work/node-key.b64" >"$key_work/node-key.raw" 2>/dev/null \
  || refuse 'retained_p2p_key_encoding_invalid=true'
[[ "$(wc -c <"$key_work/node-key.raw" | tr -d ' ')" == 64 ]] || refuse 'retained_p2p_key_size_invalid=true'
tail -c 32 "$key_work/node-key.raw" >"$key_work/node-public.raw"
actual_node_id="$(sha256sum "$key_work/node-public.raw" | awk '{print substr($1,1,40)}')"
[[ "$actual_node_id" == "$expected_node_id" ]] || refuse 'retained_p2p_key_identity_mismatch=true'

base64 -d "$softsign" >"$key_work/softsign.raw" 2>/dev/null \
  || refuse 'retained_tmkms_key_encoding_invalid=true'
softsign_size="$(wc -c <"$key_work/softsign.raw" | tr -d ' ')"
[[ "$softsign_size" == 32 || "$softsign_size" == 64 ]] || refuse 'retained_tmkms_key_size_invalid=true'
head -c 32 "$key_work/softsign.raw" >"$key_work/softsign-seed.raw"
printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x70\x04\x22\x04\x20' >"$key_work/softsign.der"
cat "$key_work/softsign-seed.raw" >>"$key_work/softsign.der"
openssl pkey -inform DER -in "$key_work/softsign.der" -pubout -outform DER >"$key_work/softsign-public.der" 2>/dev/null \
  || refuse 'retained_tmkms_key_public_derivation_failed=true'
actual_consensus="$(tail -c 32 "$key_work/softsign-public.der" | base64 | tr -d '\n')"
[[ "$actual_consensus" == "$expected_consensus" ]] || refuse 'retained_tmkms_key_identity_mismatch=true'
jq -e 'type == "object" and ((.height | tostring | tonumber) == 0) and
  ((.round | tostring | tonumber) == 0) and ((.step | tostring | tonumber) == 0) and
  ((.block_id.hash // "") == "" or (.block_id.hash | test("^0+$")))' "$signer_state" >/dev/null \
  || refuse 'tmkms_signing_state_not_zero=true'

# Only the stopped, temporary tmkms created by identity bootstrap may remain.
command -v docker >/dev/null 2>&1 || refuse 'docker_unavailable=true'
running_ids="$(docker ps -q --no-trunc)" || refuse 'cannot_inspect_running_containers=true'
while IFS= read -r container_id; do
  [[ -n "$container_id" ]] || continue
  mounts="$(docker inspect --format '{{json .Mounts}}' "$container_id")" || refuse 'cannot_inspect_running_container_mounts=true'
  jq -e --arg root "$root" 'all(.[]; (.Source | type == "string") and (.Source != $root) and ((.Source | startswith($root + "/")) | not))' \
    <<<"$mounts" >/dev/null || refuse 'running_container_uses_validator_root=true'
done <<<"$running_ids"
container_ids="$(docker ps -aq --no-trunc --filter "label=com.docker.compose.project=$node")" \
  || refuse 'cannot_inspect_join_project_containers=true'
while IFS= read -r container_id; do
  [[ -n "$container_id" ]] || continue
  inspect="$(docker inspect --format '{{.State.Status}}|{{.State.Running}}|{{index .Config.Labels "com.docker.compose.service"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$container_id")" \
    || refuse 'cannot_inspect_join_project_container=true'
  [[ "$inspect" == "exited|false|tmkms|$root/identity-bootstrap/02-node" ]] \
    || refuse 'unexpected_join_project_container=true'
done <<<"$container_ids"

printf 'PASS JOIN IDENTITY_READY target verified node=%s; no deployment, chain state, or signature found\n' "$node"
