#!/usr/bin/env bash
set -Eeuo pipefail
usage(){ echo "Usage: sudo $0 --node-name ssh-alias --env FILE --node-config FILE --genesis FILE [--join-profile FILE | --genesis-software FILE --genesis-software-sha256 SHA256] [--local-ml] [--allow-release-change]" >&2; }
NODE=""; ENV_FILE=""; NODE_CONFIG=""; GENESIS=""; JOIN_PROFILE=""; GENESIS_SOFTWARE=""; GENESIS_SOFTWARE_SHA256=""; LOCAL_ML=false; ALLOW_RELEASE_CHANGE=false
while (($#)); do
  case "$1" in
    --node-name) NODE="$2"; shift 2;; --env) ENV_FILE="$2"; shift 2;;
    --node-config) NODE_CONFIG="$2"; shift 2;; --genesis) GENESIS="$2"; shift 2;; --join-profile) JOIN_PROFILE="$2"; shift 2;;
    --genesis-software) GENESIS_SOFTWARE="$2"; shift 2;; --genesis-software-sha256) GENESIS_SOFTWARE_SHA256="$2"; shift 2;;
    --local-ml) LOCAL_ML=true; shift;; --allow-release-change) ALLOW_RELEASE_CHANGE=true; shift;; *) usage; exit 2;;
  esac
done
[[ $EUID -eq 0 ]] || { echo 'Run with sudo' >&2; exit 1; }
[[ "$NODE" =~ ^[a-z0-9][a-z0-9_-]*$ && -s "$ENV_FILE" && -s "$NODE_CONFIG" && -s "$GENESIS" ]] || { usage; exit 2; }
DEST="/srv/dai/deploy"
PARENT="$(dirname "$DEST")"
BACKUP="${DEST}.gdc-rollback.$$"
profile_kind="$(awk -F= '$1 == "GDC_PROFILE_KIND" {print $2; exit}' "$ENV_FILE")"
is_genesis="$(awk -F= '$1 == "IS_GENESIS" {print $2; exit}' "$ENV_FILE")"
data_dir="$(awk -F= '$1 == "DATA_DIR" {print substr($0, index($0, "=") + 1); exit}' "$ENV_FILE")"
genesis_software_mode=false
if [[ -n "$GENESIS_SOFTWARE" || -n "$GENESIS_SOFTWARE_SHA256" ]]; then
  [[ -n "$GENESIS_SOFTWARE" && -n "$GENESIS_SOFTWARE_SHA256" && -z "$JOIN_PROFILE" ]] \
    || { echo 'Genesis software fragment and its SHA-256 must be provided together and cannot be combined with a JOIN profile' >&2; exit 1; }
  [[ "$profile_kind" == release && "$is_genesis" == true ]] \
    || { echo 'Genesis software fragments are supported only for a fresh release-profile Genesis install' >&2; exit 1; }
  [[ -f "$GENESIS_SOFTWARE" && ! -L "$GENESIS_SOFTWARE" && -r "$GENESIS_SOFTWARE" \
    && "$GENESIS_SOFTWARE_SHA256" =~ ^[0-9a-f]{64}$ \
    && "$(sha256sum "$GENESIS_SOFTWARE" | awk '{print $1}')" == "$GENESIS_SOFTWARE_SHA256" ]] \
    || { echo 'Genesis software fragment is missing, unsafe, or does not match its SHA-256 guard' >&2; exit 1; }
  jq -e '
    .schema_version == 1 and .kind == "gdc-genesis-software-fragment"
    and .source.release_profile == "v2026.10.06"
    and (.source.release_lock_sha256 | test("^[0-9a-f]{64}$"))
    and (.source.model_profile | test("^[a-z0-9][a-z0-9.-]*[a-z0-9]$"))
    and (.source.model_lock_sha256 | test("^[0-9a-f]{64}$"))
    and (.binary_sha256 | type == "object" and keys == ["decentralized_api","inferenced"]
      and (.inferenced | test("^[0-9a-f]{64}$"))
      and (.decentralized_api | test("^[0-9a-f]{64}$")))
    and (.spec.deployment.software | .components.node.version == "0.2.16-post1"
      and .components.api.version == "0.2.16-post1"
      and .components.node.commit == .components.api.commit
      and .components.node.upgrade.name == "v0.2.16"
      and .components.api.upgrade.name == "v0.2.16"
      and .components.node.upgrade.artifact.executable == "inferenced"
      and .components.api.upgrade.artifact.executable == "decentralized-api")
  ' "$GENESIS_SOFTWARE" >/dev/null \
    || { echo 'Genesis software fragment has an invalid pinned Core/DAPI identity' >&2; exit 1; }
  jq -e '
    .spec.deployment.software as $s |
    $s.schema_version == 1 and $s.platform == "linux/amd64"
    and ($s.deployment.commit | test("^[0-9a-f]{40}$"))
    and ($s.components.node.image | test("^[a-z0-9][a-z0-9./:_-]*@sha256:[0-9a-f]{64}$"))
    and ($s.components.api.image | test("^[a-z0-9][a-z0-9./:_-]*@sha256:[0-9a-f]{64}$"))
    and ($s.components.node.upgrade.artifact |
      .format == "zip" and .executable == "inferenced" and (.url | startswith("https://"))
      and (.sha256 | test("^[0-9a-f]{64}$")))
    and ($s.components.api.upgrade.artifact |
      .format == "zip" and .executable == "decentralized-api" and (.url | startswith("https://"))
      and (.sha256 | test("^[0-9a-f]{64}$")))
  ' "$GENESIS_SOFTWARE" >/dev/null \
    || { echo 'Genesis software fragment violates the pinned Core/DAPI artifact contract' >&2; exit 1; }
  fragment_release="$(jq -er '.source.release_profile' "$GENESIS_SOFTWARE")"
  rendered_release="$(awk -F= '$1 == "GDC_RELEASE_PROFILE" {print $2; exit}' "$ENV_FILE")"
  [[ "$fragment_release" == "$rendered_release" ]] \
    || { echo 'Genesis software fragment release differs from the rendered release profile' >&2; exit 1; }
  for pair in INFERENCED_IMAGE:node DAPI_IMAGE:api; do
    variable="${pair%%:*}"; role="${pair#*:}"
    rendered_image="$(awk -F= -v key="$variable" '$1 == key {print substr($0, index($0, "=") + 1); exit}' "$ENV_FILE")"
    fragment_image="$(jq -er --arg role "$role" '.spec.deployment.software.components[$role].image' "$GENESIS_SOFTWARE")"
    [[ "$rendered_image" == "$fragment_image" ]] \
      || { echo "Genesis software fragment image differs from rendered $variable" >&2; exit 1; }
  done
  genesis_software_mode=true
elif [[ "$profile_kind" == release && "$is_genesis" == true ]]; then
  echo 'Fresh release-profile Genesis install requires a pinned Genesis software fragment' >&2
  exit 1
fi

# Fresh Genesis installation is supported only in the current canonical Host
# layout. Identity bootstrap may leave its config and key files, but runtime,
# chain data, or another deployment must never be overwritten.
if [[ "$genesis_software_mode" == true ]]; then
  [[ "$data_dir" == /srv/dai ]] \
    || { echo 'Fresh Genesis runtime install requires canonical DATA_DIR=/srv/dai; migrate legacy layouts explicitly' >&2; exit 1; }
  [[ ! -e "$DEST" && ! -L "$DEST" ]] \
    || { echo "fresh Genesis install refuses an existing deployment directory on $NODE" >&2; exit 1; }
  [[ ! -e /srv/dai/shared/genesis.json && ! -L /srv/dai/shared/genesis.json ]] \
    || { echo 'fresh Genesis install refuses an existing shared Genesis' >&2; exit 1; }
  [[ ! -e "$BACKUP" && ! -L "$BACKUP" ]] \
    || { echo "stale rollback path exists: $BACKUP" >&2; exit 1; }
  check_fresh_genesis_root() {
    local root="$1" inference="$1/inference" dapi="$1/dapi" path entry name expected_chain_id
    local -a entries expected_config=(app.toml client.toml config.toml genesis.json node_key.json priv_validator_key.json)
    [[ ! -e "$root/deploy" && ! -L "$root/deploy" ]] \
      || { echo "fresh Genesis install refuses an existing deployment directory: $root/deploy" >&2; return 1; }
    [[ ! -e "$root/shared/genesis.json" && ! -L "$root/shared/genesis.json" ]] \
      || { echo "fresh Genesis install refuses an existing shared Genesis: $root/shared/genesis.json" >&2; return 1; }
    for path in "$inference/cosmovisor" "$dapi/cosmovisor"; do
      [[ ! -e "$path" && ! -L "$path" ]] \
        || { echo "fresh Genesis install refuses an existing Cosmovisor home: $path" >&2; return 1; }
    done
    [[ ! -e "$inference/.node_initialized" ]] \
      || { echo "fresh Genesis install refuses an initialized inference deployment: $inference" >&2; return 1; }
    if [[ -e "$inference" || -L "$inference" ]]; then
      [[ -d "$inference" && ! -L "$inference" ]] \
        || { echo "fresh Genesis install refuses an unsafe inference home: $inference" >&2; return 1; }
    fi
    if [[ -e "$inference/data" || -L "$inference/data" ]]; then
      [[ -d "$inference/data" && ! -L "$inference/data" ]] \
        || { echo "fresh Genesis install refuses unsafe inference data: $inference/data" >&2; return 1; }
      mapfile -t entries < <(find "$inference/data" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
      if ((${#entries[@]} != 0)); then
        [[ ${#entries[@]} -eq 1 && "${entries[0]}" == priv_validator_state.json \
          && -f "$inference/data/priv_validator_state.json" && ! -L "$inference/data/priv_validator_state.json" ]] \
          || { echo "fresh Genesis install refuses existing consensus/application database state: $inference/data" >&2; return 1; }
        jq -e 'type == "object" and (keys | sort) == ["height","round","step"]
          and .height == "0" and .round == 0 and .step == 0' \
          "$inference/data/priv_validator_state.json" >/dev/null \
          || { echo "fresh Genesis install refuses nonzero or malformed validator state: $inference/data/priv_validator_state.json" >&2; return 1; }
      fi
    fi
    if [[ -d "$inference/config" ]]; then
      [[ ! -L "$inference/config" ]] \
        || { echo "fresh Genesis install refuses a symlinked inference config: $inference/config" >&2; return 1; }
      mapfile -t entries < <(find "$inference/config" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)
      local expected_sorted
      expected_sorted="$(printf '%s\n' "${expected_config[@]}" | LC_ALL=C sort)"
      [[ "$(printf '%s\n' "${entries[@]}")" == "$expected_sorted" ]] \
        || { echo "fresh Genesis install refuses a non-init inference config inventory: $inference/config" >&2; return 1; }
      for name in "${entries[@]}"; do
        entry="$inference/config/$name"
        name="${entry##*/}"
        [[ -f "$entry" && ! -L "$entry" ]] || {
          echo "fresh Genesis install refuses an unexpected identity bootstrap entry: $entry" >&2
          return 1
        }
      done
      if [[ -e "$inference/config/genesis.json" ]]; then
        expected_chain_id="$(awk -F= '$1 == "CHAIN_ID" {print substr($0,index($0,"=")+1); exit}' "$ENV_FILE")"
        [[ -n "$expected_chain_id" ]] \
          || { echo 'Fresh Genesis installer environment lacks CHAIN_ID for init-only verification' >&2; return 1; }
        jq -e --arg chain_id "$expected_chain_id" '
          .chain_id == $chain_id and .initial_height == 1 and .app_hash == null
          and (.app_state.genutil.gen_txs == [])
          and (.app_state.auth.accounts == [])
          and (.app_state.staking.validators == [])
        ' "$inference/config/genesis.json" >/dev/null \
          || { echo "fresh Genesis install refuses a non-default or populated init Genesis: $inference/config/genesis.json" >&2; return 1; }
      fi
      if [[ -e "$inference/config/node_key.json" ]]; then
        [[ -f /srv/dai/identity/p2p/node_key.json && ! -L /srv/dai/identity/p2p/node_key.json \
          && "$(sha256sum "$inference/config/node_key.json" | awk '{print $1}')" == \
             "$(sha256sum /srv/dai/identity/p2p/node_key.json | awk '{print $1}')" ]] \
          || { echo "fresh Genesis install refuses a node key that differs from stable P2P identity: $inference/config/node_key.json" >&2; return 1; }
      fi
    fi
  }
  check_fresh_genesis_root /srv/dai
  check_fresh_genesis_root "/srv/dai/$NODE"
fi
mkdir -p "$PARENT"
STAGE="$(mktemp -d "$PARENT/.gdc-stage.XXXXXX")"
activated=false
backup_made=false
backup_move_started=false
deployment_move_started=false
rollback() {
  local rc="$?"
  trap - ERR INT TERM EXIT
  if [[ "$activated" == true || "$backup_made" == true || "$backup_move_started" == true || "$deployment_move_started" == true ]]; then
    if [[ -e "$BACKUP" ]]; then
      rm -rf "$DEST"
      mv "$BACKUP" "$DEST"
    elif [[ "$deployment_move_started" == true ]]; then
      rm -rf "$DEST"
    fi
  fi
  rm -rf "$STAGE"
  exit "$rc"
}
trap rollback ERR INT TERM EXIT
case "$profile_kind" in
  generated_join)
    new_join_profile="$(awk -F= '$1 == "GDC_JOIN_PROFILE_SHA256" {print $2}' "$ENV_FILE")"
    [[ "$new_join_profile" =~ ^[0-9a-f]{64}$ ]] || { echo 'rendered environment lacks generated JOIN profile identity' >&2; exit 1; }
    [[ -r "$JOIN_PROFILE" && "$(sha256sum "$JOIN_PROFILE" | awk '{print $1}')" == "$new_join_profile" ]] || { echo 'generated JOIN profile file is missing or does not match the rendered environment' >&2; exit 1; }
    if [[ -s "$DEST/.gdc-release" ]]; then
      [[ "$ALLOW_RELEASE_CHANGE" == true ]] || { echo "legacy release deployment exists on $NODE; use the explicit migration path" >&2; exit 1; }
    fi
    if [[ -s "$DEST/.gdc-join-profile" ]] && ! grep -qx "$new_join_profile" "$DEST/.gdc-join-profile"; then
      [[ "$ALLOW_RELEASE_CHANGE" == true ]] || { echo "different generated JOIN profile exists on $NODE; use receipt-bound resume or migration" >&2; exit 1; }
    fi
    ;;
  release)
    new_release="$(awk -F= '$1 == "GDC_RELEASE_PROFILE" {print $2}' "$ENV_FILE")"
    new_hash="$(awk -F= '$1 == "GDC_PROFILE_HASH" {print $2}' "$ENV_FILE")"
    [[ -n "$new_release" && "$new_hash" =~ ^[0-9a-f]{64}$ ]] || { echo 'rendered environment lacks release identity' >&2; exit 1; }
    if [[ -s "$DEST/.gdc-join-profile" ]]; then
      [[ "$ALLOW_RELEASE_CHANGE" == true ]] || { echo "generated JOIN deployment exists on $NODE; use the explicit migration path" >&2; exit 1; }
    fi
    if [[ -s "$DEST/.gdc-release" ]] && ! cmp -s <(printf '%s %s\n' "$new_release" "$new_hash") "$DEST/.gdc-release"; then
      [[ "$ALLOW_RELEASE_CHANGE" == true ]] || { echo "mixed release family on $NODE; use the explicit upgrade phase" >&2; exit 1; }
    fi
    ;;
  *) echo 'rendered environment lacks a known profile kind' >&2; exit 1 ;;
esac
install -m 0644 "$(dirname "$0")/compose.yaml" "$STAGE/compose.yaml"
install -m 0644 "$(dirname "$0")/compose.ml-local.yaml" "$STAGE/compose.ml-local.yaml"
install -m 0644 "$(dirname "$0")/compose.ml-amd.yaml" "$STAGE/compose.ml-amd.yaml"
install -m 0644 "$(dirname "$0")/compose.ml-amd-single-group.yaml" "$STAGE/compose.ml-amd-single-group.yaml"
install -m 0644 "$(dirname "$0")/compose.devshard-ha.yaml" "$STAGE/compose.devshard-ha.yaml"
install -m 0644 "$(dirname "$0")/compose.bridge-sepolia.yaml" "$STAGE/compose.bridge-sepolia.yaml"
install -d -m 0755 "$STAGE/versiond-router"
install -m 0644 "$(dirname "$0")/vendor-router/nginx.conf.template" "$STAGE/versiond-router/nginx.conf.template"
install -m 0644 "$(dirname "$0")/nginx-mlnode.conf" "$STAGE/nginx-mlnode.conf"
install -m 0755 "$(dirname "$0")/node-entrypoint.sh" "$STAGE/node-entrypoint.sh"
install -m 0755 "$(dirname "$0")/api-entrypoint.sh" "$STAGE/api-entrypoint.sh"
install -m 0755 "$(dirname "$0")/tmkms-entrypoint.sh" "$STAGE/tmkms-entrypoint.sh"
install -m 0755 "$(dirname "$0")/start-node.sh" "$STAGE/start-node.sh"
install -m 0755 "$(dirname "$0")/ensure-warm-key.sh" "$STAGE/ensure-warm-key.sh"
install -m 0755 "$(dirname "$0")/verify-canonical-join-state.sh" "$STAGE/verify-canonical-join-state.sh"
install -m 0755 "$(dirname "$0")/verify-active-signer-state.sh" "$STAGE/verify-active-signer-state.sh"
install -m 0755 "$(dirname "$0")/wait-state-sync-canary.sh" "$STAGE/wait-state-sync-canary.sh"
install -m 0755 "$(dirname "$0")/stop-state-sync-canary.sh" "$STAGE/stop-state-sync-canary.sh"
install -m 0755 "$(dirname "$0")/record-state-sync-canary.sh" "$STAGE/record-state-sync-canary.sh"
install -m 0755 "$(dirname "$0")/verify-state-sync-config.sh" "$STAGE/verify-state-sync-config.sh"
install -m 0755 "$(dirname "$0")/fence-existing-signer.sh" "$STAGE/fence-existing-signer.sh"
install -m 0755 "$(dirname "$0")/promote-state-sync-generation.sh" "$STAGE/promote-state-sync-generation.sh"
install -m 0755 "$(dirname "$0")/sync-node-config.sh" "$STAGE/sync-node-config.sh"
install -m 0755 "$(dirname "$0")/mlnode-max_concurrent.sh" "$STAGE/mlnode-max_concurrent.sh"
if [[ "$LOCAL_ML" == true ]]; then
  install -m 0755 "$(dirname "$0")/poc-winddown-watch.sh" "$STAGE/poc-winddown-watch.sh"
fi
if [[ -f "$(dirname "$0")/../03-join/register-participant.sh" ]]; then
  install -m 0755 "$(dirname "$0")/../03-join/register-participant.sh" "$STAGE/register-participant.sh"
fi
install -m 0600 "$ENV_FILE" "$STAGE/.env"
if [[ "$profile_kind" == generated_join ]]; then
  printf '%s\n' "$new_join_profile" >"$STAGE/.gdc-join-profile"
  chmod 600 "$STAGE/.gdc-join-profile"
  install -m 0600 "$JOIN_PROFILE" "$STAGE/gdc-join-profile.v1.json"
else
  printf '%s %s\n' "$new_release" "$new_hash" >"$STAGE/.gdc-release"
  chmod 600 "$STAGE/.gdc-release"
fi
install -m 0644 "$NODE_CONFIG" "$STAGE/node-config.json"
if [[ "$profile_kind" == generated_join ]] && jq -e '.spec.deployment | has("software")' "$JOIN_PROFILE" >/dev/null; then
  bash "$(dirname "$0")/prepare-bootstrap-runtime.sh" "$JOIN_PROFILE" "$STAGE"
  install -m 0755 "$(dirname "$0")/bootstrap-runtime.sh" "$STAGE/bootstrap-runtime.sh"
  # Keep variables and relative bind paths intact. This is a complete Compose
  # document, not an overlay that can retain incompatible proxy settings.
  bash "$(dirname "$0")/render-bootstrap-compose.sh" "$STAGE/compose.yaml" "$STAGE/.env" >"$STAGE/compose.bootstrap.json"
  mv "$STAGE/compose.bootstrap.json" "$STAGE/compose.yaml"
  chmod 0600 "$STAGE/compose.yaml"
fi
if [[ "$genesis_software_mode" == true ]]; then
  bash "$(dirname "$0")/prepare-bootstrap-runtime.sh" "$GENESIS_SOFTWARE" "$STAGE" --genesis-software-fragment
  install -m 0755 "$(dirname "$0")/bootstrap-runtime.sh" "$STAGE/bootstrap-runtime.sh"
  core_binary_sha="$(cat "$STAGE/bootstrap-runtime/node/binary.sha256")"
  dapi_binary_sha="$(cat "$STAGE/bootstrap-runtime/api/binary.sha256")"
  core_actual_sha="$(sha256sum "$STAGE/bootstrap-runtime/node/bin/inferenced" | awk '{print $1}')"
  dapi_actual_sha="$(sha256sum "$STAGE/bootstrap-runtime/api/bin/decentralized-api" | awk '{print $1}')"
  [[ "$core_binary_sha" == "$core_actual_sha" && "$dapi_binary_sha" == "$dapi_actual_sha" ]] \
    || { echo 'staged Genesis runtime executable hashes differ from their fragment pins' >&2; exit 1; }
  install -m 0444 "$GENESIS_SOFTWARE" "$STAGE/genesis-software.json"
  jq -n -S \
    --arg fragment_sha256 "$GENESIS_SOFTWARE_SHA256" \
    --arg release_profile "$new_release" \
    --arg release_lock_sha256 "$(jq -er '.source.release_lock_sha256' "$GENESIS_SOFTWARE")" \
    --arg model_profile "$(jq -er '.source.model_profile' "$GENESIS_SOFTWARE")" \
    --arg model_lock_sha256 "$(jq -er '.source.model_lock_sha256' "$GENESIS_SOFTWARE")" \
    --arg core_version "$(jq -er '.spec.deployment.software.components.node.version' "$GENESIS_SOFTWARE")" \
    --arg dapi_version "$(jq -er '.spec.deployment.software.components.api.version' "$GENESIS_SOFTWARE")" \
    --arg core_commit "$(jq -er '.spec.deployment.software.components.node.commit' "$GENESIS_SOFTWARE")" \
    --arg dapi_commit "$(jq -er '.spec.deployment.software.components.api.commit' "$GENESIS_SOFTWARE")" \
    --arg core_image "$(jq -er '.spec.deployment.software.components.node.image' "$GENESIS_SOFTWARE")" \
    --arg dapi_image "$(jq -er '.spec.deployment.software.components.api.image' "$GENESIS_SOFTWARE")" \
    --arg core_archive_sha256 "$(jq -er '.spec.deployment.software.components.node.upgrade.artifact.sha256' "$GENESIS_SOFTWARE")" \
    --arg dapi_archive_sha256 "$(jq -er '.spec.deployment.software.components.api.upgrade.artifact.sha256' "$GENESIS_SOFTWARE")" \
    --arg core_binary_sha256 "$core_binary_sha" --arg dapi_binary_sha256 "$dapi_binary_sha" \
    '{schema_version:1,kind:"gdc-genesis-runtime-install",fragment_sha256:$fragment_sha256,
      release:{profile:$release_profile,lock_sha256:$release_lock_sha256},
      model:{profile:$model_profile,lock_sha256:$model_lock_sha256},
      core:{version:$core_version,commit:$core_commit,image:$core_image,archive_sha256:$core_archive_sha256,binary_sha256:$core_binary_sha256},
      dapi:{version:$dapi_version,commit:$dapi_commit,image:$dapi_image,archive_sha256:$dapi_archive_sha256,binary_sha256:$dapi_binary_sha256}}' \
    >"$STAGE/.gdc-genesis-software"
  chmod 0444 "$STAGE/.gdc-genesis-software"
  # The reviewed runtime archives are mounted into the official Core/DAPI
  # images by the same complete Compose transformation used for JOIN. Without
  # this transformation the staged pins remain inert and the base image runs.
  bash "$(dirname "$0")/render-bootstrap-compose.sh" "$STAGE/compose.yaml" "$STAGE/.env" >"$STAGE/compose.bootstrap.json"
  mv "$STAGE/compose.bootstrap.json" "$STAGE/compose.yaml"
  chmod 0600 "$STAGE/compose.yaml"
fi
printf '%s\n' "$LOCAL_ML" > "$STAGE/.local-ml"
chown -R "${SUDO_USER:-root}:${SUDO_USER:-root}" "$STAGE"
# Validate the complete staged Compose configuration before it can replace the
# runbook-owned deployment directory. Data and TMKMS state live outside this
# directory and are never moved or recreated here.
docker compose --env-file "$STAGE/.env" -f "$STAGE/compose.yaml" config --quiet
[[ ! -e "$BACKUP" ]] || { echo "stale rollback path exists: $BACKUP" >&2; exit 1; }
if [[ -e "$DEST" ]]; then
  backup_move_started=true
  mv "$DEST" "$BACKUP"
fi
if [[ -e "$BACKUP" ]]; then backup_made=true; fi
deployment_move_started=true
mv "$STAGE" "$DEST"
activated=true
install -d -m 0755 /srv/dai/shared
install -m 0444 "$GENESIS" /srv/dai/shared/.genesis.json.gdc-stage
mv -f /srv/dai/shared/.genesis.json.gdc-stage /srv/dai/shared/genesis.json
(cd /srv/dai/shared && sha256sum genesis.json > genesis.sha256)
if [[ "$LOCAL_ML" == true ]]; then
  install -m 0644 "$(dirname "$0")/gdc-poc-winddown-watch@.service" /etc/systemd/system/gdc-poc-winddown-watch@.service
  systemctl daemon-reload
  systemctl enable --now "gdc-poc-winddown-watch@$NODE.service" >/dev/null
fi
rm -rf "$BACKUP"
trap - ERR INT TERM EXIT
printf 'READY installed %s deployment in %s\n' "$NODE" "$DEST"
