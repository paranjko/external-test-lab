#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="${1:-}"
EXPECTED_GENESIS_SHA256="${2:-}"
FRAGMENT_SHA256="${3:-}"
NODE_ALIAS="${4:-}"
ARCHIVE_ROOT="${5:-}"
BASE_COMPOSE_SHA256="${6:-}"
BOOTSTRAP_JQ_BASE64="${7:-}"
ALLOWED_OLD_CORE_SHA256="${8:-01b443aa6c5c23ea85ecb2c6053957b3a1acf5e10f2bc7ef77f5fc8531c4a5a2}"
[[ "$ROOT_DIR" == /* && "$ARCHIVE_ROOT" == /* \
  && "$NODE_ALIAS" =~ ^[a-z0-9][a-z0-9_-]*$ \
  && "$EXPECTED_GENESIS_SHA256" =~ ^[0-9a-f]{64}$ \
  && "$FRAGMENT_SHA256" =~ ^[0-9a-f]{64}$ \
  && "$BASE_COMPOSE_SHA256" =~ ^[0-9a-f]{64}$ \
  && "$ALLOWED_OLD_CORE_SHA256" =~ ^[0-9a-f]{64}$ \
  && -n "$BOOTSTRAP_JQ_BASE64" ]] || { echo 'invalid Genesis repair arguments' >&2; exit 2; }

DEPLOY="$ROOT_DIR/deploy"
ENV_FILE="$DEPLOY/.env"
COMPOSE_FILE="$DEPLOY/compose.yaml"
GENESIS="$ROOT_DIR/shared/genesis.json"
SOFTWARE="$DEPLOY/genesis-software.json"
RECEIPT="$DEPLOY/.gdc-genesis-software"
[[ -d "$ROOT_DIR" && ! -L "$ROOT_DIR" && -d "$DEPLOY" && ! -L "$DEPLOY" \
  && -f "$ENV_FILE" && ! -L "$ENV_FILE" && -f "$COMPOSE_FILE" && ! -L "$COMPOSE_FILE" \
  && -f "$GENESIS" && ! -L "$GENESIS" && -f "$SOFTWARE" && ! -L "$SOFTWARE" \
  && -f "$RECEIPT" && ! -L "$RECEIPT" ]] \
  || { echo 'Genesis startup repair requires installed deployment, Genesis and pinned software receipt' >&2; exit 1; }
[[ "$(sha256sum "$GENESIS" | awk '{print $1}')" == "$EXPECTED_GENESIS_SHA256" ]] \
  || { echo 'installed Genesis does not match the approved raw Genesis SHA-256' >&2; exit 1; }
[[ "$(sha256sum "$SOFTWARE" | awk '{print $1}')" == "$FRAGMENT_SHA256" ]] \
  || { echo 'installed Genesis software fragment changed from reviewed pins' >&2; exit 1; }
compose_is_base=false
[[ "$(sha256sum "$COMPOSE_FILE" | awk '{print $1}')" != "$BASE_COMPOSE_SHA256" ]] \
  || compose_is_base=true

jq -e '
  .schema_version == 1 and .kind == "gdc-genesis-software-fragment"
  and .source.release_profile == "v2026.10.06"
  and (.spec.deployment.software.components.node.version | type == "string" and length > 0)
  and (.spec.deployment.software.components.api.version | type == "string" and length > 0)
  and (.spec.deployment.software.components.node.commit | test("^[0-9a-f]{40}$"))
  and (.spec.deployment.software.components.api.commit | test("^[0-9a-f]{40}$"))
  and (.spec.deployment.software.components.node.image | test("^[a-z0-9][a-z0-9./:_-]*@sha256:[0-9a-f]{64}$"))
  and (.spec.deployment.software.components.api.image | test("^[a-z0-9][a-z0-9./:_-]*@sha256:[0-9a-f]{64}$"))
  and (.binary_sha256.inferenced | test("^[0-9a-f]{64}$"))
  and (.binary_sha256.decentralized_api | test("^[0-9a-f]{64}$"))
' "$SOFTWARE" >/dev/null || { echo 'installed Genesis software fragment is malformed' >&2; exit 1; }

core_version="$(jq -er '.spec.deployment.software.components.node.version' "$SOFTWARE")"
core_commit="$(jq -er '.spec.deployment.software.components.node.commit' "$SOFTWARE")"
dapi_version="$(jq -er '.spec.deployment.software.components.api.version' "$SOFTWARE")"
dapi_commit="$(jq -er '.spec.deployment.software.components.api.commit' "$SOFTWARE")"
core_image="$(jq -er '.spec.deployment.software.components.node.image' "$SOFTWARE")"
dapi_image="$(jq -er '.spec.deployment.software.components.api.image' "$SOFTWARE")"
core_binary_sha="$(jq -er '.binary_sha256.inferenced' "$SOFTWARE")"
dapi_binary_sha="$(jq -er '.binary_sha256.decentralized_api' "$SOFTWARE")"
jq -e --arg fragment "$FRAGMENT_SHA256" --arg cv "$core_version" --arg cc "$core_commit" \
  --arg dv "$dapi_version" --arg dc "$dapi_commit" --arg cb "$core_binary_sha" --arg db "$dapi_binary_sha" \
  --arg ci "$core_image" --arg di "$dapi_image" '
  .kind == "gdc-genesis-runtime-install" and .fragment_sha256 == $fragment
  and .core.version == $cv and .core.commit == $cc and .core.image == $ci and .core.binary_sha256 == $cb
  and .dapi.version == $dv and .dapi.commit == $dc and .dapi.image == $di and .dapi.binary_sha256 == $db
' "$RECEIPT" >/dev/null || { echo 'installed Genesis runtime receipt differs from approved software pins' >&2; exit 1; }

for pair in node:inferenced api:decentralized-api; do
  role="${pair%%:*}"; executable="${pair#*:}"
  expected="$core_binary_sha"; [[ "$role" != api ]] || expected="$dapi_binary_sha"
  package="$DEPLOY/bootstrap-runtime/$role"
  binary="$package/bin/$executable"
  [[ -f "$binary" && ! -L "$binary" && "$(sha256sum "$binary" | awk '{print $1}')" == "$expected" ]] \
    || { echo "staged $role executable does not match approved Genesis binary hash" >&2; exit 1; }
  (cd "$package/bin" && sha256sum -c ../SHA256SUMS) >/dev/null \
    || { echo "staged $role runtime package is corrupt" >&2; exit 1; }
done

[[ "$(awk -F= '$1 == "NODE_NAME" {print $2; exit}' "$ENV_FILE")" == "$NODE_ALIAS" \
  && "$(awk -F= '$1 == "GDC_PROFILE_KIND" {print $2; exit}' "$ENV_FILE")" == release \
  && "$(awk -F= '$1 == "IS_GENESIS" {print $2; exit}' "$ENV_FILE")" == true \
  && "$(awk -F= '$1 == "GDC_BOOTSTRAP_SOFTWARE" {print $2; exit}' "$ENV_FILE")" == true \
  && "$(awk -F= '$1 == "INFERENCED_IMAGE" {print substr($0,index($0,"=")+1); exit}' "$ENV_FILE")" == "$core_image" \
  && "$(awk -F= '$1 == "DAPI_IMAGE" {print substr($0,index($0,"=")+1); exit}' "$ENV_FILE")" == "$dapi_image" ]] \
  || { echo 'installed environment is not the expected fresh release-profile Genesis deployment' >&2; exit 1; }

repair_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
env_backup="$DEPLOY/.env.genesis-startup-repair.$repair_id.before"
compose_backup="$DEPLOY/compose.yaml.genesis-startup-repair.$repair_id.before"
temporary_env="$(mktemp "$DEPLOY/.env.genesis-startup-repair.XXXXXX")"
temporary_compose="$(mktemp "$DEPLOY/.compose-genesis-startup-repair.XXXXXX")"
temporary_effective="$(mktemp "$DEPLOY/.compose-genesis-startup-effective.XXXXXX")"
temporary_filter="$(mktemp "$DEPLOY/.bootstrap-compose-repair.XXXXXX")"
cleanup_temporary() { rm -f -- "$temporary_env" "$temporary_compose" "$temporary_effective" "$temporary_filter"; }
trap cleanup_temporary EXIT
printf '%s' "$BOOTSTRAP_JQ_BASE64" | base64 -d >"$temporary_filter"
# The reviewed jq program is compiled and exercised by the uninterpolated
# Compose transformation below; do not attempt to evaluate it on dummy JSON.

for key in DAPI_EXPECTED_VERSION DAPI_EXPECTED_COMMIT GDC_JOIN_STATESYNC_ENABLE SYNC_WITH_SNAPSHOTS; do
  count="$(awk -F= -v key="$key" '$1 == key {n++} END {print n+0}' "$ENV_FILE")"
  [[ "$count" == 1 ]] || { echo "expected exactly one $key in installed Genesis environment" >&2; exit 1; }
done
awk -v dv="$dapi_version" -v dc="$dapi_commit" '
  /^DAPI_EXPECTED_VERSION=/ {print "DAPI_EXPECTED_VERSION=" dv; next}
  /^DAPI_EXPECTED_COMMIT=/ {print "DAPI_EXPECTED_COMMIT=" dc; next}
  /^GDC_JOIN_STATESYNC_ENABLE=/ {print "GDC_JOIN_STATESYNC_ENABLE=false"; next}
  /^SYNC_WITH_SNAPSHOTS=/ {print "SYNC_WITH_SNAPSHOTS=false"; next}
  {print}
' "$ENV_FILE" >"$temporary_env"
chmod --reference="$ENV_FILE" "$temporary_env"

if [[ "$compose_is_base" == true ]]; then
  sed -E 's/\$\{([A-Z_][A-Z0-9_]*):\?/\${\1?/g' "$COMPOSE_FILE" |
    docker compose --env-file "$temporary_env" --profile '*' -f - config \
      --no-interpolate --no-normalize --no-path-resolution --format json |
    jq 'walk(if type == "string" then gsub("\\$\\{(?<name>[A-Z_][A-Z0-9_]*)\\?"; "${\(.name):?") else . end)' |
    jq -f "$temporary_filter" >"$temporary_compose"
else
  # Resume only from the exact pinned bootstrap Compose shape. A prior attempt
  # may have installed this file before stopping services/runtime replacement.
  docker compose --env-file "$temporary_env" --profile '*' -f "$COMPOSE_FILE" config --format json \
    >"$temporary_effective"
  jq -e --arg dv "$dapi_version" --arg dc "$dapi_commit" --arg ci "$core_image" --arg di "$dapi_image" '
    .services.node.environment.GDC_BOOTSTRAP_SOFTWARE == "true"
    and .services.api.environment.GDC_BOOTSTRAP_SOFTWARE == "true"
    and .services.node.environment.CONFIG_statesync__enable == "false"
    and .services.node.environment.SYNC_WITH_SNAPSHOTS == "false"
    and .services.api.environment.GDC_JOIN_DAPI_EXPECTED_VERSION == $dv
    and .services.api.environment.GDC_JOIN_DAPI_EXPECTED_COMMIT == $dc
    and .services.node.image == $ci and .services.api.image == $di
    and any(.services.node.volumes[]; .target == "/gdc-bootstrap-runtime" and .read_only == true)
    and any(.services.api.volumes[]; .target == "/gdc-bootstrap-runtime" and .read_only == true)
    and any(.services.node.volumes[]; .target == "/usr/local/bin/gdc-bootstrap-runtime" and .read_only == true)
    and any(.services.api.volumes[]; .target == "/usr/local/bin/gdc-bootstrap-runtime" and .read_only == true)
  ' "$temporary_effective" >/dev/null \
    || { echo 'refusing Compose that is neither the reviewed base nor the pinned Genesis bootstrap rendering' >&2; exit 1; }
  cp -p -- "$COMPOSE_FILE" "$temporary_compose"
fi
chmod --reference="$COMPOSE_FILE" "$temporary_compose"

docker compose --env-file "$temporary_env" --profile '*' -f "$temporary_compose" config --format json >"$temporary_effective"
jq -e --arg dv "$dapi_version" --arg dc "$dapi_commit" --arg ci "$core_image" --arg di "$dapi_image" '
  .services.node.environment.GDC_BOOTSTRAP_SOFTWARE == "true"
  and .services.api.environment.GDC_BOOTSTRAP_SOFTWARE == "true"
  and .services.node.environment.CONFIG_statesync__enable == "false"
  and .services.node.environment.SYNC_WITH_SNAPSHOTS == "false"
  and .services.api.environment.GDC_JOIN_DAPI_EXPECTED_VERSION == $dv
  and .services.api.environment.GDC_JOIN_DAPI_EXPECTED_COMMIT == $dc
  and .services.node.image == $ci and .services.api.image == $di
  and any(.services.node.volumes[]; .target == "/gdc-bootstrap-runtime" and .read_only == true)
  and any(.services.api.volumes[]; .target == "/gdc-bootstrap-runtime" and .read_only == true)
  and any(.services.node.volumes[]; .target == "/usr/local/bin/gdc-bootstrap-runtime" and .read_only == true)
  and any(.services.api.volumes[]; .target == "/usr/local/bin/gdc-bootstrap-runtime" and .read_only == true)
' "$temporary_effective" >/dev/null || { echo 'rendered Compose does not bind the pinned runtime to Core and DAPI' >&2; exit 1; }

node_state="$(jq -er '.services.node.volumes[] | select(.target == "/root/.inference") | .source' "$temporary_effective")"
api_state="$(jq -er '.services.api.volumes[] | select(.target == "/root/.dapi") | .source' "$temporary_effective")"
identity_dir="$(awk -F= '$1 == "IDENTITY_DIR" {print substr($0,index($0,"=")+1); exit}' "$temporary_env")"
signer_dir="$(awk -F= '$1 == "SIGNER_DIR" {print substr($0,index($0,"=")+1); exit}' "$temporary_env")"
[[ "$node_state" == "$ROOT_DIR/inference" && "$api_state" == "$ROOT_DIR/dapi" \
  && "$identity_dir" == "$ROOT_DIR/identity" && "$signer_dir" == "$ROOT_DIR/signer" ]] \
  || { echo 'Genesis repair refuses unexpected node, DAPI, identity or signer mount roots' >&2; exit 1; }

node_genesis="$node_state/config/genesis.json"
node_key="$node_state/config/node_key.json"
validator_key="$node_state/config/priv_validator_key.json"
validator_state="$node_state/data/priv_validator_state.json"
p2p_identity="$identity_dir/p2p/node_key.json"
[[ -f "$node_genesis" && ! -L "$node_genesis" \
  && "$(sha256sum "$node_genesis" | awk '{print $1}')" == "$EXPECTED_GENESIS_SHA256" \
  && -f "$node_key" && ! -L "$node_key" && -f "$p2p_identity" && ! -L "$p2p_identity" \
  && -f "$validator_key" && ! -L "$validator_key" \
  && -f "$validator_state" && ! -L "$validator_state" ]] \
  || { echo 'Genesis repair refuses mismatched Genesis or identity/validator files' >&2; exit 1; }
cmp -s "$node_key" "$p2p_identity" \
  || { echo 'Genesis repair refuses mismatched P2P identity files' >&2; exit 1; }
jq -e 'type == "object" and (keys | sort) == ["height","round","step"] and .height == "0" and .round == 0 and .step == 0' \
  "$validator_state" >/dev/null || { echo 'Genesis repair requires zero-height validator state' >&2; exit 1; }
cosmo_archive_needed() {
  local home="$1" expected="$2" executable="$3" package="$4" old_allowed="${5:-}" current actual
  [[ -e "$home" || -L "$home" ]] || return 0
  [[ -d "$home" && ! -L "$home" && -L "$home/current" && -d "$home/genesis" \
    && ! -L "$home/genesis" && -f "$home/genesis/bin/$executable" \
    && ! -L "$home/genesis/bin/$executable" ]] \
    || { echo "unsafe or incomplete Cosmovisor home: $home" >&2; return 2; }
  current="$(readlink -f "$home/current")" || { echo "Cosmovisor current is unresolved: $home" >&2; return 2; }
  [[ "$current" == "$home/genesis" ]] || { echo "Cosmovisor current is not genesis: $home" >&2; return 2; }
  if [[ -e "$home/upgrades" || -L "$home/upgrades" ]]; then
    [[ -d "$home/upgrades" && ! -L "$home/upgrades" \
      && -z "$(find "$home/upgrades" -mindepth 1 -print -quit)" ]] \
      || { echo "Cosmovisor upgrade state exists; refusing runtime replacement: $home" >&2; return 2; }
  fi
  actual="$(sha256sum "$home/genesis/bin/$executable" | awk '{print $1}')"
  if [[ "$actual" == "$expected" ]]; then
    (cd "$home/genesis/bin" && sha256sum -c "$package/SHA256SUMS") >/dev/null 2>&1 && return 1
    # The executable is pinned but the existing Cosmovisor payload is partial
    # (for example, API ZIP sidecars are missing); archive and reinstall all
    # package entries so the bootstrap guard can verify the complete runtime.
    return 0
  fi
  [[ -n "$old_allowed" && "$actual" == "$old_allowed" ]] \
    || { echo "Cosmovisor executable is neither approved nor the explicitly recoverable prior runtime: $home" >&2; return 2; }
  return 0
}

tree_hash() {
  local root="$1"
  [[ -d "$root" && ! -L "$root" ]] || { printf 'absent\n'; return; }
  find "$root" -xdev -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum | sha256sum | awk '{print $1}'
}
genesis_hash_before="$(sha256sum "$GENESIS" | awk '{print $1}')"
node_genesis_hash_before="$(sha256sum "$node_genesis" | awk '{print $1}')"
node_key_hash_before="$(sha256sum "$node_key" | awk '{print $1}')"
validator_key_hash_before="$(sha256sum "$validator_key" | awk '{print $1}')"
validator_state_hash_before="$(sha256sum "$validator_state" | awk '{print $1}')"
signer_hash_before="$(tree_hash "$signer_dir")"
p2p_hash_before="$(sha256sum "$p2p_identity" | awk '{print $1}')"
node_runtime_before=absent
api_runtime_before=absent
[[ ! -f "$node_state/cosmovisor/genesis/bin/inferenced" ]] \
  || node_runtime_before="$(sha256sum "$node_state/cosmovisor/genesis/bin/inferenced" | awk '{print $1}')"
[[ ! -f "$api_state/cosmovisor/genesis/bin/decentralized-api" ]] \
  || api_runtime_before="$(sha256sum "$api_state/cosmovisor/genesis/bin/decentralized-api" | awk '{print $1}')"

mkdir -p -- "$ARCHIVE_ROOT"
[[ -d "$ARCHIVE_ROOT" && ! -L "$ARCHIVE_ROOT" ]] || { echo 'archive root is unsafe' >&2; exit 1; }
archive_dir="$(mktemp -d "$ARCHIVE_ROOT/${repair_id}-${NODE_ALIAS}-genesis-runtime.XXXXXX")"
env_backup="$DEPLOY/.env.genesis-startup-repair.$repair_id.before"
compose_backup="$DEPLOY/compose.yaml.genesis-startup-repair.$repair_id.before"
[[ ! -e "$env_backup" && ! -e "$compose_backup" ]] || { echo 'repair backup path already exists' >&2; exit 1; }
cp -p -- "$ENV_FILE" "$env_backup"
cp -p -- "$COMPOSE_FILE" "$compose_backup"
mv -f -- "$temporary_env" "$ENV_FILE"
mv -f -- "$temporary_compose" "$COMPOSE_FILE"
rm -f -- "$temporary_effective" "$temporary_filter"
trap - EXIT

compose=(docker compose --env-file "$ENV_FILE" --profile '*' -f "$COMPOSE_FILE")
if ! "${compose[@]}" config --format json | jq -e --arg dv "$dapi_version" --arg dc "$dapi_commit" '
  .services.node.environment.CONFIG_statesync__enable == "false"
  and .services.node.environment.SYNC_WITH_SNAPSHOTS == "false"
  and .services.api.environment.GDC_JOIN_DAPI_EXPECTED_VERSION == $dv
  and .services.api.environment.GDC_JOIN_DAPI_EXPECTED_COMMIT == $dc
' >/dev/null; then
  cp -p -- "$env_backup" "$ENV_FILE"
  cp -p -- "$compose_backup" "$COMPOSE_FILE"
  echo 'Compose verification failed; restored the original env and Compose files' >&2
  exit 1
fi

"${compose[@]}" stop node api
running="$("${compose[@]}" ps --status running -q node api)"
[[ -z "$running" ]] || { echo 'node/api remain running; refusing Cosmovisor replacement' >&2; exit 1; }

repair_cosmovisor() {
  local role="$1" executable="$2" state="$3" expected="$4" old_allowed="${5:-}"
  local home="$state/cosmovisor" package="$DEPLOY/bootstrap-runtime/$role"
  local needed=1 archived="$archive_dir/$role-cosmovisor"
  if cosmo_archive_needed "$home" "$expected" "$executable" "$package" "$old_allowed"; then needed=1; else
    rc=$?
    [[ $rc -eq 1 ]] || return "$rc"
    needed=0
  fi
  if (( needed == 0 )); then
    # A binary match alone is insufficient for the container bootstrap guard:
    # Cosmovisor's archive receipt must also bind it to this verified package.
    (cd "$home/genesis/bin" && sha256sum -c "$package/SHA256SUMS") >/dev/null \
      || { echo "existing $role runtime files do not match the approved package" >&2; return 1; }
    if ! cmp -s "$home/genesis/archive.sha256" "$package/archive.sha256"; then
      if [[ -e "$home/genesis/archive.sha256" || -L "$home/genesis/archive.sha256" ]]; then
        [[ -f "$home/genesis/archive.sha256" && ! -L "$home/genesis/archive.sha256" ]] \
          || { echo "existing $role archive receipt is unsafe" >&2; return 1; }
        cp -p -- "$home/genesis/archive.sha256" "$archive_dir/$role-archive.sha256.before"
      fi
      cp -- "$package/archive.sha256" "$home/genesis/archive.sha256"
      chmod 0644 "$home/genesis/archive.sha256"
    fi
    return 0
  fi
  if (( needed == 1 )); then
  [[ ! -e "$archived" && ! -L "$archived" ]] || { echo "runtime archive destination exists: $archived" >&2; return 1; }
    if [[ -e "$home" || -L "$home" ]]; then mv -- "$home" "$archived"; fi
  fi
  if ! sh "$DEPLOY/bootstrap-runtime.sh" "$state" "$package" "$executable"; then
    if (( needed == 1 )) && [[ -e "$archived" && ! -e "$home" ]]; then mv -- "$archived" "$home"; fi
    return 1
  fi
  [[ -f "$home/current/bin/$executable" && ! -L "$home/current/bin/$executable" \
    && "$(sha256sum "$home/current/bin/$executable" | awk '{print $1}')" == "$expected" ]] \
    || { echo "reinstalled $role Cosmovisor binary does not match its approved hash" >&2; return 1; }
}
repair_cosmovisor node inferenced "$node_state" "$core_binary_sha" "$ALLOWED_OLD_CORE_SHA256"
repair_cosmovisor api decentralized-api "$api_state" "$dapi_binary_sha"

[[ "$(sha256sum "$GENESIS" | awk '{print $1}')" == "$genesis_hash_before" \
  && "$(sha256sum "$node_genesis" | awk '{print $1}')" == "$node_genesis_hash_before" \
  && "$(sha256sum "$node_key" | awk '{print $1}')" == "$node_key_hash_before" \
  && "$(sha256sum "$validator_key" | awk '{print $1}')" == "$validator_key_hash_before" \
  && "$(sha256sum "$validator_state" | awk '{print $1}')" == "$validator_state_hash_before" \
  && "$(sha256sum "$p2p_identity" | awk '{print $1}')" == "$p2p_hash_before" \
  && "$(tree_hash "$signer_dir")" == "$signer_hash_before" ]] \
  || { echo 'Genesis, identity or signer state changed during runtime repair; services remain stopped' >&2; exit 1; }

jq -n -S --arg host "$NODE_ALIAS" --arg genesis "$EXPECTED_GENESIS_SHA256" --arg fragment "$FRAGMENT_SHA256" \
  --arg core_binary "$core_binary_sha" --arg dapi_binary "$dapi_binary_sha" \
  --arg before_node "$node_runtime_before" --arg after_node "$core_binary_sha" \
  --arg before_api "$api_runtime_before" \
  --arg signer "$signer_hash_before" --arg env_backup "$env_backup" --arg compose_backup "$compose_backup" \
  --arg original_cosmo "$archive_dir/node-cosmovisor" --arg timestamp "$repair_id" \
  '{schema_version:1,kind:"gdc-genesis-startup-repair",host:$host,timestamp:$timestamp,
    approved_genesis_sha256:$genesis,software_fragment_sha256:$fragment,
    node_cosmovisor_genesis_before_sha256:$before_node,node_cosmovisor_genesis_after_sha256:$after_node,
    api_cosmovisor_genesis_before_sha256:$before_api,
    core_binary_sha256:$core_binary,dapi_binary_sha256:$dapi_binary,signer_tree_sha256:$signer,
    env_backup:$env_backup,compose_backup:$compose_backup,archived_node_cosmovisor:$original_cosmo}' \
  >"$archive_dir/repair-receipt.json"
chmod 0600 "$archive_dir/repair-receipt.json"
"${compose[@]}" up -d --no-deps --force-recreate node api
[[ "$(sha256sum "$GENESIS" | awk '{print $1}')" == "$EXPECTED_GENESIS_SHA256" ]] \
  || { echo 'approved Genesis bytes changed during runtime repair' >&2; exit 1; }
printf 'READY repaired pinned Genesis runtimes and bootstrap Compose; archive=%s\n' "$archive_dir"
