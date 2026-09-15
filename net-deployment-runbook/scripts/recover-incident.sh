#!/usr/bin/env bash
# GNK-LAB-2026-0001 only. The normal JOIN and recovery phase API are unchanged.
set +x
set -Eeuo pipefail
umask 077
INCIDENT=GNK-LAB-2026-0001
HALTED_HEIGHT=306552
HALTED_HASH=50144a1fd8afcdd14b7085a3915e0503fc305583c0dec29ec8fde46468e4882d
CHAIN=gonka-devnet-community
LOST='["gonka17dlt8p0ystz54s2p50wllzfg8kjq9afresjd67","gonka15u464xe9ytk7psnpyslc8eudnggnzk3jeqrwae"]'
report_incident_error() {
  if [[ "${recovery_action:-}" == handoff ]]; then
    printf 'END handoff FAILED exit=%s function=%s line=%s\n' "$1" "$3" "$2" >&2
  fi
}
fail() {
  printf 'recovery: %s\n' "$*" >&2
  report_incident_error 3 "${BASH_LINENO[0]}" "${FUNCNAME[1]:-main}"
  exit 3
}
sha() { sha256sum "$1" | awk '{print $1}'; }
valid_node() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; }
valid_alias() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
# SDK group membership, including model subgroups, is the input to PoC.
# Merely replacing the staking validators does not repair that input.
bootstrap_group_messages() {
  jq -e --arg authority "$1" --arg address "$2" --arg key "$3" '
    if length == 0 or any(.[]; ([.validation_weights[]? | select(.member_address==$address and (.weight|tonumber)>0)]|length)!=1)
    then error("the backup must retain positive source weight in every PoC group") else
    [.[] | {"@type":"/cosmos.group.v1.MsgUpdateGroupMembers",admin:$authority,group_id:.epoch_group_id,
      member_updates:[.validation_weights[] | {address:.member_address,
        weight:(if .member_address==$address then (.weight|tostring) else "0" end),
        metadata:(if .member_address==$address then $key else "" end)}]}]
    + [{"@type":"/cosmos.group.v1.MsgUpdateGroupMetadata",admin:$authority,group_id:.[0].epoch_group_id,metadata:"changed"}]
    end' "$4"
}
valid_source_location() {
  local node="$1" source="$2" resolved="$3"
  valid_node "$node" || return 1
  [[ "$source" == "/srv/dai/$node/inference" || "$source" == "/srv/dai/data/$node/inference" ]] || return 1
  [[ "$source" == "$resolved" || ( "$source" == "/srv/dai/data/$node/inference" \
    && "$resolved" =~ ^/srv/dai/data/$node\.generations/[A-Za-z0-9_-]+/inference$ ) ]]
}
valid_incident_binary() {
  [[ "$1" == source || "$1" == returning ]] || return 1
  [[ "$2" == /root/.inference/cosmovisor/upgrades/v0.2.15/bin/inferenced \
    || ( "$1" == returning && "$2" == /root/.inference/cosmovisor/genesis/bin/inferenced ) ]]
}
discover_deployment() {
  local containers=()
  mapfile -t containers < <(docker ps --no-trunc --filter label=com.docker.compose.service=node -q)
  (( ${#containers[@]} > 0 )) || fail 'no running Compose node found'
  docker inspect "${containers[@]}" | jq -ce '
    map(select(.State.Running == true)
      | {container:.Id, deploy:.Config.Labels["com.docker.compose.project.working_dir"]}
      | select(.deploy | type == "string")
      | select(.deploy | test("^/srv/dai/deploy/[A-Za-z0-9][A-Za-z0-9_-]*$")))
    | if length == 1 then .[0] else error("expected one managed node deployment") end'
}

check_backup_resume() {
  local member
  [[ -f "$saved/backup.started" && -f "$saved/services.running" ]] || fail 'no interrupted stop to resume'
  for member in inference tmkms deploy backup.complete boot.started reset.started; do
    [[ ! -e "$saved/$member" && ! -L "$saved/$member" ]] || fail 'backup or recovery already advanced; automatic resume refused'
  done
  docker inspect "$(jq -er .container "$saved/context.json")" \
    | jq -e 'length == 1 and .[0].State.Running == false' >/dev/null || fail 'source container was restarted; automatic resume refused'
  [[ "$(sha "$source/config/genesis.json")" == "$(jq -er .genesis_file_sha256 "$saved/context.json")" ]] || fail 'source Genesis changed'
}

isolate_testnet_config() {
  sed -i 's|^priv_validator_laddr *=.*|priv_validator_laddr = ""|; s|^persistent_peers *=.*|persistent_peers = ""|; s|^seeds *=.*|seeds = ""|; s|^pex *=.*|pex = false|; s|^[[:space:]]*external_address[[:space:]]*=.*|external_address = ""|' "$1"
}

restore_genesis_bytes() {
  [[ "$(sha "$1")" == "$3" ]] || fail 'original Genesis checksum changed'
  jq -en --slurpfile original "$1" --slurpfile working "$2" \
    '($original|length) == 1 and ($working|length) == 1 and $original[0] == $working[0]' >/dev/null \
    || fail 'Genesis content changed'
  if ! cmp -s "$1" "$2"; then
    [[ -e "$2.before-restore" ]] || cp -a "$2" "$2.before-restore"
    install -m 0600 "$1" "$2"
  fi
}

check_genesis_resume() {
  [[ "$role" == source && -f "$saved/backup.complete" && -f "$saved/boot.started" \
    && ! -e "$saved/boot.complete" && ! -e "$saved/pre-fork-home" ]] || fail 'not an unpromoted working copy'
  [[ -z "$(docker ps -a --filter 'name=^/gdc-incident-transition$' -q)" ]] || fail 'transition container still exists'
  docker inspect "$(jq -er .container "$saved/context.json")" \
    | jq -e 'length == 1 and .[0].State.Running == false' >/dev/null || fail 'original node was restarted'
  [[ "$(sha "$source/config/genesis.json")" == "$(jq -er .genesis_file_sha256 "$saved/context.json")" \
    && "$(sha "$saved/inference/config/genesis.json")" == "$(sha "$source/config/genesis.json")" ]] || fail 'original Genesis changed'
  jq -en --slurpfile original "$saved/inference/config/genesis.json" --slurpfile working "$saved/working/config/genesis.json" \
    '($original|length) == 1 and ($working|length) == 1 and $original[0] == $working[0]' >/dev/null || fail 'Genesis content changed'
  jq -en --slurpfile key "$saved/new-key/config/priv_validator_key.json" --slurpfile working "$saved/working/config/priv_validator_key.json" \
    '($key|length) == 1 and ($working|length) == 1 and $key[0] == $working[0]' >/dev/null \
    || fail 'working copy does not retain the temporary signer'
}

restore_external_address() {
  awk 'FNR == NR { if (/^[[:space:]]*external_address[[:space:]]*=/) address = $0; next }
    /^[[:space:]]*external_address[[:space:]]*=/ { print address; next } { print }' "$1" "$2" >"$2.next"
  mv "$2.next" "$2"
}

configure_recovery_statesync() {
  local config="$1" rpc_url="$2" height="$3" hash="$4"
  [[ "$rpc_url" =~ ^https?://[A-Za-z0-9.-]+(:[1-9][0-9]{0,4})?(/[A-Za-z0-9/_-]*)?$ \
    && "$height" =~ ^[1-9][0-9]*$ && "$hash" =~ ^[A-Fa-f0-9]{64}$ ]] || fail 'invalid state-sync trust settings'
  awk -v rpc="$rpc_url" -v height="$height" -v hash="$hash" '
    /^\[/ { syncing = ($0 == "[statesync]") }
    syncing && /^enable[[:space:]]*=/ { print "enable = true"; next }
    syncing && /^rpc_servers[[:space:]]*=/ { print "rpc_servers = \"" rpc "," rpc "\""; next }
    syncing && /^trust_height[[:space:]]*=/ { print "trust_height = " height; next }
    syncing && /^trust_hash[[:space:]]*=/ { print "trust_hash = \"" hash "\""; next }
    syncing && /^trust_period[[:space:]]*=/ { print "trust_period = \"24h0m0s\""; next }
    { print }
  ' "$config" >"$config.next"
  mv "$config.next" "$config"
}

check_statesync_rpc() {
  local rpc_url="$1" height="$2" hash="$3" request
  request="$(jq -cn --arg height "$height" '{jsonrpc:"2.0",id:1,method:"commit",params:{height:$height}}')"
  # Exercise the same JSON-RPC POST as CometBFT, not only the GET /block route.
  # Never follow a redirect that can downgrade HTTPS or discard the POST body.
  curl -fsS --max-time 15 -H 'Content-Type: application/json' --data "$request" "$rpc_url" \
    | jq -e --arg height "$height" --arg hash "$hash" '.error == null
      and .result.signed_header.header.height == $height
      and .result.signed_header.commit.block_id.hash == $hash' >/dev/null \
    || fail 'source JSON-RPC POST does not match the authenticated trust checkpoint'
}

resume_native_sync() {
  local rpc_url="$1" height="$2" hash="$3" config="$source/config/config.toml"
  cp -p "$config" "$config.rpc-next"
  configure_recovery_statesync "$config.rpc-next" "$rpc_url" "$height" "$hash"
  if cmp -s "$config" "$config.rpc-next"; then
    rm -f -- "$config.rpc-next"
  else
    printf 'Correcting the state-sync RPC endpoint; restarting only this unsigned node. No reset or key replacement.\n'
    recovered_compose stop node >/dev/null
    mv "$config.rpc-next" "$config"
  fi
  recovered_compose up -d --no-deps --pull never node >/dev/null
}

check_recovered_source() {
  [[ "$role" == source && -f "$saved/boot.complete" ]] || fail 'source boot is not complete'
  [[ "$(sha "$source/config/genesis.json")" == "$(jq -er .genesis_file_sha256 "$saved/context.json")" ]] || fail 'source Genesis changed'
  rpc status | jq -e --arg chain "$CHAIN" --argjson height "$HALTED_HEIGHT" \
    '.result.node_info.network == $chain and .result.sync_info.catching_up == false
      and (.result.sync_info.latest_block_height|tonumber) > $height' >/dev/null || fail 'recovered source is not running'
}

prepare_native_snapshot() {
  local height container end current hash public_host peer
  check_recovered_source
  curl -fsS --max-time 10 http://127.0.0.1:1317/productscience/inference/inference/params \
    | jq -e --argjson lost "$LOST" '.params.participant_access_params.blocked_participant_addresses as $blocked
      | all($lost[]; . as $address | $blocked | index($address) != null)' >/dev/null || fail 'lost-key retirement is not applied'
  if [[ ! -f "$saved/native-snapshot.height" ]]; then
    height="$(rpc status | jq -er .result.sync_info.latest_block_height)"
    [[ "$height" =~ ^[1-9][0-9]*$ ]] && (( height > HALTED_HEIGHT )) || fail 'invalid recovered snapshot height'
    container="$(compose ps -a -q node)"
    [[ "$container" =~ ^[0-9a-f]{64}$ ]] || fail 'expected one recovered node container'
    printf 'Creating a native state-sync snapshot on this Host; briefly stopping only node. No database archive or local download.\n'
    docker stop --time 30 "$container" >/dev/null
    if ! docker run --rm --pull never --network none --name gdc-incident-snapshot \
      -v "$source:/root/.inference" --entrypoint "$binary" "$image" \
      snapshots export --height "$height" --home /root/.inference >"$saved/native-snapshot.log" 2>&1; then
      docker start "$container" >/dev/null
      tail -n 15 "$saved/native-snapshot.log" >&2
      fail 'native snapshot export failed; recovered node restarted, inspect the snapshot log'
    fi
    printf '%s\n' "$height" >"$saved/native-snapshot.height"
    docker start "$container" >/dev/null
  fi
  height="$(<"$saved/native-snapshot.height")"
  [[ "$height" =~ ^[1-9][0-9]*$ && -d "$source/data/snapshots/$height" ]] && (( height > HALTED_HEIGHT )) \
    || fail 'post-fork native snapshot is unavailable'
  end=$((SECONDS + 180)); current=0
  while (( SECONDS < end )); do
    current="$(rpc status 2>/dev/null | jq -r '.result.sync_info.latest_block_height // 0' 2>/dev/null || true)"
    if [[ "$current" =~ ^[0-9]+$ ]] && (( current >= height + 2 )); then break; fi
    sleep 2
  done
  [[ "$current" =~ ^[0-9]+$ ]] && (( current >= height + 2 )) || fail 'source did not advance after native snapshot creation'
  hash="$(rpc "block?height=$current" | jq -er .result.block_id.hash)"
  public_host="$(jq -er .public_host "$saved/context.json")"
  peer="$(jq -er '.node_id + "@" + .public_host + ":" + .p2p_port' "$saved/context.json")"
  jq -cn --arg chain "$CHAIN" --arg genesis "$(jq -er .genesis_sha256 "$saved/context.json")" \
    --arg rpc "https://$public_host/chain-rpc/" --arg peer "$peer" --argjson snapshot "$height" \
    --argjson height "$current" --arg hash "$hash" \
    '{chain_id:$chain,genesis_sha256:$genesis,rpc_url:$rpc,peer:$peer,snapshot_height:$snapshot,trust_height:$height,trust_hash:$hash}' \
    >"$saved/state-sync.json"
  printf 'Native snapshot ready; returning Hosts will obtain state directly over P2P.\n'
}

compose() { docker compose --project-directory "$deploy" --env-file "$deploy/.env" -f "$deploy/compose.yaml" "$@"; }
recovered_compose() { compose -f "$saved/override.json" "$@"; }
persist_compose() {
  # A previous render may have omitted a profiled service while retaining its
  # optional depends_on entry. Repair only absent OPTIONAL dependencies, then
  # run normal validation before replacing the deployed file.
  recovered_compose --profile '*' config --no-consistency --format json | jq '
    .services as $services | .services |= with_entries(
      if .value.depends_on then .value.depends_on |= with_entries(
        select(.value.required != false or (.key as $dependency | $services | has($dependency))))
      else . end)' >"$deploy/compose.next.json" || fail 'cannot render recovery Compose configuration'
  docker compose --project-directory "$deploy" --env-file "$deploy/.env" \
    -f "$deploy/compose.next.json" --profile '*' config --quiet || fail 'recovery Compose configuration is invalid'
  chmod 0600 "$deploy/compose.next.json"
  mv "$deploy/compose.next.json" "$deploy/compose.yaml"
}

source_override() {
  jq -cn --arg image "$image" --arg binary "$binary" --arg deadline "$1" \
    '{services:{node:{image:$image,restart:"no",entrypoint:[$binary],command:["start","--home","/root/.inference",
      "--priv_validator_laddr","","--p2p.pex=false","--p2p.seeds=","--p2p.persistent_peers=","--rpc.laddr","tcp://0.0.0.0:26657",
      "--api.enable","--api.address","tcp://0.0.0.0:1317","--halt-time",$deadline]}}}'
}

check_promoted_resume() {
  local deadline original
  [[ "$role" == source && -f "$saved/backup.complete" && -f "$saved/boot.started" \
    && -d "$saved/pre-fork-home" && ! -e "$saved/working" && ! -e "$saved/boot.complete" ]] \
    || fail 'not a promoted chain awaiting ordinary startup'
  [[ -z "$(docker ps -a --filter 'name=^/gdc-incident-transition$' -q)" ]] || fail 'transition container still exists'
  docker inspect "$(jq -er .container "$saved/context.json")" \
    | jq -e 'length == 1 and .[0].State.Running == false' >/dev/null || fail 'original node was restarted'
  for original in "$source" "$saved/inference" "$saved/pre-fork-home"; do
    [[ "$(sha "$original/config/genesis.json")" == "$(jq -er .genesis_file_sha256 "$saved/context.json")" ]] || fail 'promoted Genesis changed'
  done
  jq -en --slurpfile key "$saved/new-key/config/priv_validator_key.json" --slurpfile active "$source/config/priv_validator_key.json" \
    '($key|length) == 1 and $key == $active' >/dev/null || fail 'promoted chain does not retain the temporary signer'
  [[ "$(sha "$source/${binary#/root/.inference/}")" == "$(jq -er .binary_sha256 "$saved/context.json")" ]] || fail 'promoted binary changed'
  deadline="$(jq -er '.services.node.command[-1]' "$saved/override.json")"
  [[ "$deadline" =~ ^[1-9][0-9]{0,9}$ ]] && (( deadline > $(date +%s) + 180 )) || fail 'transition startup deadline expired'
  source_override "$deadline" | jq -e --slurpfile actual "$saved/override.json" '. == $actual[0]' >/dev/null || fail 'unexpected promoted startup command'
}

start_promoted_source() {
  check_promoted_resume
  printf 'Starting the promoted recovered chain; no copying or in-place-testnet.\n'
  persist_compose
  recovered_compose up -d --no-deps --pull never --force-recreate node >/dev/null
  jq -er .pub_key.value "$saved/new-key/config/priv_validator_key.json" >"$saved/transition-key.public"
  touch "$saved/boot.complete"
}

check_dns_boot_retry() {
  local logs
  [[ "$role" == source && -f "$saved/backup.complete" && -f "$saved/boot.started" \
    && -d "$saved/working" && ! -e "$saved/boot.complete" && ! -e "$saved/pre-fork-home" ]] \
    || fail 'not an unpublished failed testnet boot'
  docker inspect gdc-incident-transition | jq -e --arg working "$saved/working" '
    length == 1 and .[0].State.Status == "exited" and .[0].State.ExitCode == 1
    and .[0].HostConfig.NetworkMode == "none" and .[0].Config.Cmd[0] == "in-place-testnet"
    and any(.[0].Mounts[]; .Type == "bind" and .Source == $working and .Destination == "/root/.inference")
  ' >/dev/null || fail 'failed container does not match the isolated recovery attempt'
  logs="$(docker logs gdc-incident-transition 2>&1)"
  [[ "$logs" == *'error looking up host'* && "$logs" == *'network is unreachable'* ]] || fail 'not the isolated DNS startup failure'
  docker inspect "$(jq -er .container "$saved/context.json")" \
    | jq -e 'length == 1 and .[0].State.Running == false' >/dev/null || fail 'original node was restarted'
  [[ "$(sha "$source/config/genesis.json")" == "$(jq -er .genesis_file_sha256 "$saved/context.json")" ]] || fail 'original Genesis changed'
  cmp "$source/config/genesis.json" "$saved/inference/config/genesis.json" || fail 'backup Genesis differs'
}

archive_dns_boot() {
  local failed member
  check_dns_boot_retry
  failed="$(mktemp -d "$saved/failed-dns.XXXXXX")"
  docker inspect gdc-incident-transition >"$failed/container.json"
  docker logs gdc-incident-transition >"$failed/container.log" 2>&1
  # Remove only the exited container, never its data. Preserve the modified
  # copy and keys before the ordinary boot path copies the untouched backup.
  docker rm gdc-incident-transition >/dev/null
  for member in working new-key addrbook.before.json boot.started; do
    [[ ! -e "$saved/$member" ]] || mv "$saved/$member" "$failed/$member"
  done
  printf 'Preserved failed isolated boot at %s; retrying from the original backup.\n' "$failed"
}

stop_deployment() {
  local defined containers=()
  mapfile -t containers < <(compose ps -a -q)
  (( ${#containers[@]} > 0 )) || fail 'no owned deployment containers'
  defined="$(compose --profile '*' config --services | jq -Rsc 'split("\n") | map(select(length > 0))')"
  # Retain running services omitted from today's Compose file by container ID.
  # This also handles attempts stopped by the previous compose-only stop.
  if [[ ! -e "$saved/orphans.running" ]]; then
    docker inspect "${containers[@]}" | jq -r --argjson defined "$defined" '
      .[] | select(.State.Running == true)
      | select(.Config.Labels["com.docker.compose.service"] as $service | $defined | index($service) | not)
      | .Id' >"$saved/orphans.running"
  fi
  printf 'Stopping deployment containers, including retained orphan services...\n'
  docker update --restart=no "${containers[@]}" >/dev/null
  docker stop --time 30 "${containers[@]}" >/dev/null
  docker inspect "${containers[@]}" | jq -e 'all(.[]; .State.Running == false)' >/dev/null || fail 'a deployment container is still running'
}

restore_previous_orphan_recipe() {
  local generation="$1" previous
  [[ "$generation" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || fail 'invalid recovery generation'
  previous="$saved.previous-$generation/orphans.compose.json"
  if [[ ! -e "$saved/orphans.compose.json" && -f "$previous" ]]; then
    cp -p "$previous" "$saved/orphans.compose.json"
  fi
}

start_orphans() {
  local id file metadata project files=() ids=()
  [[ -s "$saved/orphans.running" ]] || return 0
  [[ ! -e "$saved/orphans.complete" ]] || return 0
  # Capture everything before Compose replaces the old container IDs. A retry
  # then uses this small local recipe, even after a partially successful start.
  if [[ ! -f "$saved/orphans.compose.json" ]]; then
    mapfile -t ids <"$saved/orphans.running"
    for id in "${ids[@]}"; do
      [[ "$id" =~ ^[0-9a-f]{64}$ ]] || fail 'invalid retained orphan container ID'
    done
    metadata="$(docker inspect "${ids[@]}")"
    jq -e --arg deploy "$deploy" 'all(.[];
      .Config.Labels["com.docker.compose.project.working_dir"] == $deploy
      and (.Config.Labels["com.docker.compose.service"] | test("^[A-Za-z0-9][A-Za-z0-9_-]*$"))
      and (.Config.Labels["com.docker.compose.service"] != "node")
      and (.Config.Labels["com.docker.compose.service"] != "tmkms"))' <<<"$metadata" >/dev/null \
      || fail 'retained orphan belongs to another deployment or is a chain service'
    project="$(jq -er '[.[].Config.Labels["com.docker.compose.project"]] | unique
      | if length == 1 then .[0] else error("mixed orphan projects") end' <<<"$metadata")"
    while IFS= read -r file; do
      [[ "$file" == "$deploy/"* && -f "$file" && "$(realpath "$file")" == "$deploy/"* ]] \
        || fail 'retained orphan Compose file is missing or outside this deployment'
      files+=(-f "$file")
    done < <(jq -r 'reduce (.[].Config.Labels["com.docker.compose.project.config_files"] | split(",")[]) as $file
      ([]; if index($file) then . else . + [$file] end) | .[]' <<<"$metadata")
    (( ${#files[@]} > 0 )) || fail 'retained orphan has no Compose files'
    docker compose --project-directory "$deploy" --env-file "$deploy/.env" --project-name "$project" \
      "${files[@]}" --profile '*' config --format json \
      | jq --argjson metadata "$metadata" '
        ($metadata | map({key:.Config.Labels["com.docker.compose.service"],value:.Image}) | from_entries) as $images
        | .services |= with_entries(select(.key as $key | $images | has($key))
          | .value.image = $images[.key] | .value |= del(.build,.profiles))
        | .services |= with_entries(.value.depends_on //= {}
          | .value.depends_on |= with_entries(select(.key as $key | $images | has($key))))' \
      >"$saved/orphans.compose.next.json"
    mv "$saved/orphans.compose.next.json" "$saved/orphans.compose.json"
  fi
  printf 'Recreating retained auxiliary services on the current deployment network...\n'
  docker compose --project-directory "$deploy" --env-file "$deploy/.env" \
    -f "$saved/orphans.compose.json" up -d --pull never --force-recreate >/dev/null || return $?
  touch "$saved/orphans.complete"
}

check_enabled_signer() {
  local containers=()
  mapfile -t containers < <(recovered_compose --profile signer ps -q node tmkms)
  (( ${#containers[@]} == 2 )) || fail 'signer activation was interrupted before both chain services started; inspect before retrying'
  docker inspect "${containers[@]}" | jq -e '
    all(.[]; .State.Running == true)
    and ([.[] | select(.Config.Labels["com.docker.compose.service"] == "tmkms")] | length == 1)
    and ([.[] | select(.Config.Labels["com.docker.compose.service"] == "node")
      | .Config.Cmd | index("--priv_validator_laddr") as $i
      | select($i != null and .[$i+1] == "tcp://0.0.0.0:26658")] | length == 1)' >/dev/null \
    || fail 'existing node is not running with its external signer; inspect before retrying'
}

resume_enabled_services() {
  check_enabled_signer
  printf 'Finishing services for the already synchronized node; no chain restart or key replacement.\n'
  start_services || return $?
  touch "$saved/enable.complete"
}

restart_native_source() {
  local previous container member
  [[ "$role" == source && -f "$saved/backup.complete" && -f "$saved/boot.complete" ]] || fail 'original source backup is required'
  [[ "$(sha "$saved/inference/config/genesis.json")" == "$(jq -er .genesis_file_sha256 "$saved/context.json")" ]] || fail 'original backup Genesis changed'
  previous="$(mktemp -d "$saved/previous.XXXXXX")"
  cp -p "$saved/context.json" "$previous/context.json"
  compose --profile signer ps --services --status running >"$saved/services.running"
  container="$(compose ps -q node)"
  [[ "$container" =~ ^[0-9a-f]{64}$ ]] || fail 'expected one running source'
  stop_deployment
  for member in boot.started boot.complete pre-fork-home working new-key transition-key.public override.json \
    native-snapshot.height state-sync.json enable.started enable.complete orphans.complete poc-cache.complete poc-before-native; do
    [[ ! -e "$saved/$member" ]] || mv "$saved/$member" "$previous/"
  done
  jq --arg container "$container" '.container=$container' "$saved/context.json" >"$saved/context.next.json"
  mv "$saved/context.next.json" "$saved/context.json"
  touch "$saved/native-prepared"
  printf 'Previous attempt retained at %s; the original incident backup is unchanged.\n' "$previous"
}

archive_native_poc_cache() {
  local dapi="$1" cache="$2" table present
  install -d -m 0700 "$cache"
  if [[ -f "$dapi/gonka.db" ]]; then
    [[ -f "$cache/gonka.db" ]] || sqlite3 "$dapi/gonka.db" ".backup '$cache/gonka.db'"
    for table in poc_early_checkpoints poc_early_capture_runs poc_early_guard_state seed_info; do
      present="$(sqlite3 "$dapi/gonka.db" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='$table';")"
      [[ "$present" != 1 ]] || sqlite3 "$dapi/gonka.db" "DELETE FROM $table;"
    done
  fi
  if [[ -d "$dapi/data/poc-artifacts" && ! -e "$cache/poc-artifacts" ]]; then
    mv "$dapi/data/poc-artifacts" "$cache/poc-artifacts"
  fi
  install -d -m 0700 "$dapi/data/poc-artifacts"
}

resume_temporary_source() {
  local temporary current retained
  [[ "$role" == source ]] || fail 'temporary signer belongs only to the recovery source'
  temporary="$(<"$saved/transition-key.public")"
  [[ "$(jq -er .pub_key.value "$source/config/priv_validator_key.json")" == "$temporary" ]] || fail 'temporary signer file changed'
  current="$(rpc status)"
  if [[ "$(jq -er .result.validator_info.pub_key.value <<<"$current")" == "$temporary" ]]; then return; fi
  rpc 'validators?per_page=100' | jq -e --arg key "$temporary" \
    'any(.result.validators[]; .pub_key.value==$key and (.voting_power|tonumber)>0)' >/dev/null || fail 'temporary key is not an active validator'
  retained="$(mktemp -d "$saved/key-handoff.XXXXXX")"
  recovered_compose --profile signer stop node tmkms >/dev/null
  cp -p "$signer/state/priv_validator_state.json" "$retained/original-signer-state.json"
  for current in enable.started enable.complete; do
    [[ ! -e "$saved/$current" ]] || mv "$saved/$current" "$retained/"
  done
  jq '(.services.node.command|index("--priv_validator_laddr")) as $i | .services.node.command[$i+1]=""' \
    "$saved/override.json" >"$saved/override.next.json"
  mv "$saved/override.next.json" "$saved/override.json"
  persist_compose
  recovered_compose up -d --no-deps --pull never --force-recreate node >/dev/null
  printf 'Resumed the retained temporary signer; no fork, rollback or signer-state reset.\n'
}

reset_native_poc_cache() {
  local api dapi cache="$saved/poc-before-native"
  [[ ! -e "$saved/poc-cache.complete" ]] || return 0
  api="$(compose ps -a -q api)"
  if [[ -n "$api" ]]; then
    [[ "$api" =~ ^[0-9a-f]{64}$ ]] || fail 'expected one retained API container'
    dapi="$(docker inspect "$api" | jq -er '.[0].Mounts[] | select(.Type=="bind" and .Destination=="/root/.dapi") | .Source')"
  else
    # host reset removes the API container, not its retained bind-mounted data.
    dapi="$(compose --profile '*' config --format json | jq -er '.services.api.volumes[] |
      select(.type=="bind" and .target=="/root/.dapi") | .source')"
  fi
  [[ "$dapi" == "/srv/dai/$node/dapi" || "$dapi" == "/srv/dai/data/$node/dapi" ]] || fail 'unexpected API state location'
  # sqlite3 is only an operational utility. The deployed chain/API binaries
  # and images remain unchanged; do not replace the API database wholesale.
  if [[ -f "$dapi/gonka.db" ]] && ! command -v sqlite3 >/dev/null; then
    command -v apt-get >/dev/null || fail 'sqlite3 is required to reset the retained PoC cache'
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get install -y --no-install-recommends sqlite3 </dev/null
  fi
  [[ -z "$api" ]] || compose stop api >/dev/null
  archive_native_poc_cache "$dapi" "$cache"
  touch "$saved/poc-cache.complete"
  printf 'Preserved the old off-chain PoC cache on this Host; keys and chain data are unchanged.\n'
}

# The same reviewed file is streamed over SSH; no installed daemon or second
# orchestration layer is required. All paths below belong to this incident.
if [[ "${1:-}" == --remote ]]; then
  operation="${2:-}"; node="${3:-}"; role="${4:-}"
  valid_node "$node" && [[ $EUID == 0 && ( "$role" == source || "$role" == returning ) ]] || fail 'invalid remote Host or missing sudo authority'
  deploy="/srv/dai/deploy/$node"
  saved="/srv/dai/recovery/$INCIDENT/$node"
  rpc() { curl -fsS --connect-timeout 3 --max-time 10 "http://127.0.0.1:26657/$1"; }
  start_services() {
    local service defined services=()
    reset_native_poc_cache
    defined="$(compose --profile '*' config --services)"
    while IFS= read -r service; do
      case "$service" in node|tmkms|'') continue ;; esac
      [[ "$service" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || fail 'invalid retained service name'
      grep -Fxq "$service" <<<"$defined" || continue
      services+=("$service")
    done <"$saved/services.running"
    (( ${#services[@]} == 0 )) || recovered_compose up -d --no-deps --pull never --force-recreate "${services[@]}" >/dev/null || return $?
    start_orphans
  }
  case "$operation" in
    inspect)
      for dependency in docker curl jq nsenter tar sha256sum openssl; do command -v "$dependency" >/dev/null || fail "missing Host dependency: $dependency"; done
      discovered="$(discover_deployment)" || fail 'cannot identify the deployed node'
      container="$(jq -er .container <<<"$discovered")"
      deploy="$(jq -er .deploy <<<"$discovered")"
      node="${deploy##*/}"
      [[ "$container" =~ ^[0-9a-f]{64}$ ]] || fail 'expected one running node container'
      source="$(docker inspect "$container" | jq -er '.[0].Mounts[] | select(.Destination == "/root/.inference" and .Type == "bind") | .Source')"
      signer="$(compose ps -a -q tmkms)"
      [[ "$signer" =~ ^[0-9a-f]{64}$ ]] || fail 'expected one TMKMS container'
      signer="$(docker inspect "$signer" | jq -er '.[0].Mounts[] | select(.Destination == "/root/.tmkms" and .Type == "bind") | .Source')"
      [[ "$source" == "/srv/dai/$node/inference" || "$source" == "/srv/dai/data/$node/inference" ]] || fail 'unexpected node data path'
      [[ "$signer" == "/srv/dai/$node/tmkms" || "$signer" == "/srv/dai/signer/$node/tmkms" ]] || fail 'unexpected signer path'
      source_realpath="$(realpath -e "$source")"
      valid_source_location "$node" "$source" "$source_realpath" \
        && [[ "$signer" == "$(realpath -e "$signer")" ]] || fail 'unexpected linked state directory'
      binary="$(docker exec "$container" readlink -f /root/.inference/cosmovisor/current/bin/inferenced)"
      valid_incident_binary "$role" "$binary" \
        && [[ "$(docker exec "$container" "$binary" version)" =~ ^v?0\.2\.15$ ]] || fail 'expected the deployed v0.2.15 binary'
      status="$(rpc status)"
      jq -e --arg role "$role" --arg chain "$CHAIN" --arg hash "$HALTED_HASH" --arg height "$HALTED_HEIGHT" '
        .result.node_info.network == $chain and
        (if $role == "source" then .result.sync_info.latest_block_height == $height
          and (.result.sync_info.latest_block_hash|ascii_downcase) == $hash
         else (.result.sync_info.latest_block_height|tonumber) >= ($height|tonumber) end)
      ' <<<"$status" >/dev/null || fail 'this is not the halted incident state'
      [[ "$role" != source ]] || jq -e '.result.sync_info.earliest_block_height == "1"' <<<"$status" >/dev/null \
        || fail 'recovery source does not retain the full block history'
      public_host="$(awk -F= '$1 == "PUBLIC_HOST" {print $2}' "$deploy/.env")"
      p2p_port="$(awk -F= '$1 == "P2P_PORT" {print $2}' "$deploy/.env")"
      [[ "$public_host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ && "$p2p_port" =~ ^[1-9][0-9]{0,4}$ && "$p2p_port" -le 65535 ]] \
        || fail 'deployed public host or P2P port is missing or invalid'
      jq -cn --arg source "$source" --arg source_realpath "$source_realpath" --arg signer "$signer" --arg container "$container" \
        --arg node_name "$node" --arg role "$role" --arg public_host "$public_host" --arg p2p_port "$p2p_port" \
        --arg image "$(docker inspect -f '{{.Image}}' "$container")" --arg binary "$binary" \
        --arg binary_sha "$(docker exec "$container" sha256sum "$binary" | awk '{print $1}')" \
        --arg machine "$(sha /etc/machine-id)" --arg genesis "$(sha "$source/config/genesis.json")" \
        --arg node_id "$(jq -r .result.node_info.id <<<"$status")" \
        '{node_name:$node_name,role:$role,public_host:$public_host,p2p_port:$p2p_port,
          source:$source,source_realpath:$source_realpath,signer:$signer,container:$container,image:$image,binary:$binary,binary_sha256:$binary_sha,
          machine_sha256:$machine,genesis_file_sha256:$genesis,node_id:$node_id}'
      exit
      ;;
  esac
  [[ -f "$saved/context.json" && ! -L "$saved/context.json" ]] || fail 'retained incident context is missing'
  [[ "$role" == "$(jq -er .role "$saved/context.json")" && "$node" == "$(jq -er .node_name "$saved/context.json")" ]] || fail 'recovery role changed'
  source="$(jq -er .source "$saved/context.json")"; signer="$(jq -er .signer "$saved/context.json")"
  image="$(jq -er .image "$saved/context.json")"; binary="$(jq -er .binary "$saved/context.json")"
  [[ "$source" == "/srv/dai/$node/inference" || "$source" == "/srv/dai/data/$node/inference" ]] || fail 'unsafe source path'
  [[ "$(realpath -e "$source")" == "$(jq -er .source_realpath "$saved/context.json")" ]] || fail 'active data generation changed'
  [[ "$signer" == "/srv/dai/$node/tmkms" || "$signer" == "/srv/dai/signer/$node/tmkms" ]] || fail 'unsafe signer path'
  [[ "$image" =~ ^sha256:[0-9a-f]{64}$ ]] && valid_incident_binary "$role" "$binary" || fail 'unsafe runtime binding'
  [[ "$saved" == "$(realpath -e "$saved")" && "$(sha /etc/machine-id)" == "$(jq -r .machine_sha256 "$saved/context.json")" ]] || fail 'Host identity changed'
  case "$operation" in
    restart-native) restart_native_source ;;
    resume-temporary) resume_temporary_source ;;
    restore-recipe) restore_previous_orphan_recipe "${5:-}" ;;
    prepare-poc)
      reset_native_poc_cache
      recovered_compose up -d --no-deps --pull never api >/dev/null
      ;;
    normal-pace)
      [[ "$role" == source && -e "$saved/boot.complete" ]] || fail 'source boot is incomplete'
      awk 'FNR==NR {if (/^timeout_commit[[:space:]]*=/) pace=$0; next}
        /^timeout_commit[[:space:]]*=/ {print pace; next} {print}' \
        "$saved/inference/config/config.toml" "$source/config/config.toml" >"$source/config/config.toml.next"
      mv "$source/config/config.toml.next" "$source/config/config.toml"
      recovered_compose restart --no-deps node >/dev/null
      ;;
    check-source-resume)
      if [[ -f "$saved/native-prepared" && ! -e "$saved/boot.started" ]]; then
        printf 'boot\n'
      elif [[ -f "$saved/boot.complete" ]]; then
        check_recovered_source
        printf 'running\n'
      elif [[ -f "$saved/backup.complete" ]]; then
        if [[ -n "$(docker ps -a --filter 'name=^/gdc-incident-transition$' -q)" ]]; then
          check_dns_boot_retry
          printf 'dns-boot\n'
        elif [[ -d "$saved/pre-fork-home" ]]; then
          check_promoted_resume
          printf 'promoted\n'
        else
          check_genesis_resume
          printf 'genesis\n'
        fi
      else
        check_backup_resume
        printf 'backup\n'
      fi
      exit
      ;;
    prepare-sync) prepare_native_snapshot ;;
    sync-info)
      check_recovered_source
      [[ -f "$saved/native-snapshot.height" && -f "$saved/state-sync.json" ]] || fail 'native state-sync preparation is missing'
      cat "$saved/state-sync.json"
      exit
      ;;
    archive-dns-boot) archive_dns_boot ;;
    resume-promoted) start_promoted_source ;;
    check-backup-resume) check_backup_resume ;;
    backup|resume-backup)
      if [[ "$operation" == resume-backup ]]; then
        check_backup_resume
      else
        [[ ! -e "$saved/backup.started" ]] || fail 'backup already attempted; inspect the retained files'
        rpc status | jq -e --arg role "$role" --arg chain "$CHAIN" --arg height "$HALTED_HEIGHT" --arg hash "$HALTED_HASH" \
          '.result.node_info.network == $chain and (if $role=="source" then
            .result.sync_info.latest_block_height == $height and (.result.sync_info.latest_block_hash|ascii_downcase) == $hash
            else (.result.sync_info.latest_block_height|tonumber) >= ($height|tonumber) end)' >/dev/null || fail 'unexpected chain before stop'
      fi
      required="$(du -s -B1 "$source" | awk '{print $1}')"; free="$(df -B1 --output=avail /srv/dai | tail -n1 | tr -d ' ')"
      (( free > required * 3 + 1073741824 )) || fail 'not enough space for the backup and recovery copy'
      if [[ "$operation" == backup ]]; then
        touch "$saved/backup.started"
        compose --profile signer ps --services --status running >"$saved/services.running"
      fi
      stop_deployment
      printf 'Copying stopped chain data and signer backup; this may take several minutes...\n'
      cp -a --reflink=auto "$source" "$saved/inference"
      cp -a --reflink=auto "$signer" "$saved/tmkms"
      cp -a "$deploy" "$saved/deploy"
      [[ "$(sha "$saved/inference/config/genesis.json")" == "$(jq -r .genesis_file_sha256 "$saved/context.json")" ]] || fail 'backup Genesis mismatch'
      touch "$saved/backup.complete"
      ;;
    boot|resume-genesis)
      if [[ "$operation" == boot ]]; then
      [[ "$role" == source && -e "$saved/backup.complete" && ! -e "$saved/boot.started" ]] || fail 'in-place-testnet must run only once on the recovery source'
      valoper="${5:-}"
      [[ "$valoper" =~ ^gonkavaloper1[0-9a-z]{20,90}$ ]] || fail 'invalid transition operator'
      touch "$saved/boot.started"
      cp -a --reflink=auto "$saved/inference" "$saved/working"
      [[ "$(sha "$saved/working/${binary#/root/.inference/}")" == "$(jq -r .binary_sha256 "$saved/context.json")" ]] || fail 'upgrade binary changed'
      install -d -m 0700 "$saved/new-key"
      docker run --rm --pull never --network none -v "$saved/working:/root/.inference:ro" -v "$saved/new-key:/new-key" \
        --entrypoint "$binary" "$image" init recovery --chain-id "$CHAIN" --home /new-key >/dev/null 2>&1
      new_key="$(jq -er .pub_key.value "$saved/new-key/config/priv_validator_key.json")"
      [[ "$new_key" != "$(jq -r .pub_key.value "$saved/inference/config/priv_validator_key.json")" ]] || fail 'transition key was not replaced'
      install -m 0600 "$saved/new-key/config/priv_validator_key.json" "$saved/working/config/priv_validator_key.json"
      install -m 0600 "$saved/new-key/data/priv_validator_state.json" "$saved/working/data/priv_validator_state.json"
      isolate_testnet_config "$saved/working/config/config.toml"
      # Give native governance and the retained API/ML services time to start
      # before the next PoC boundary. Restore the original pace afterwards.
      sed -i 's/^timeout_commit *=.*/timeout_commit = "30s"/' "$saved/working/config/config.toml"
      docker run --rm --pull never --network none -v "$saved/working:/root/.inference" --entrypoint "$binary" "$image" \
        set-statesync /root/.inference/config/config.toml false >/dev/null
      [[ ! -e "$saved/working/config/addrbook.json" ]] || mv "$saved/working/config/addrbook.json" "$saved/addrbook.before.json"
      temporary=gdc-incident-transition
      deadline="$(($(date +%s) + 86400))"
      docker run -d --pull never --restart=no --network none --name "$temporary" -v "$saved/working:/root/.inference" \
        --entrypoint "$binary" "$image" in-place-testnet "$CHAIN" "$valoper" --home /root/.inference --skip-confirmation --halt-time "$deadline" >/dev/null
      else
        check_genesis_resume
        temporary=gdc-incident-transition
        deadline="$(($(date +%s) + 86400))"
        new_key="$(jq -er .pub_key.value "$saved/new-key/config/priv_validator_key.json")"
        printf 'Rechecking the existing recovered chain with ordinary start; no in-place-testnet.\n'
        docker run -d --pull never --restart=no --network none --name "$temporary" -v "$saved/working:/root/.inference" \
          --entrypoint "$binary" "$image" start --home /root/.inference --halt-time "$deadline" >/dev/null
      fi
      pid="$(docker inspect -f '{{.State.Pid}}' "$temporary")"
      isolated_rpc() { nsenter -t "$pid" -n curl -fsS --max-time 5 "http://127.0.0.1:26657/$1"; }
      end=$((SECONDS + 180)); height=0
      while (( SECONDS < end )); do
        if [[ "$(docker inspect -f '{{.State.Running}}' "$temporary")" != true ]]; then
          docker logs --tail 20 "$temporary" >&2
          fail 'isolated testnet exited before recovery verification; inspect the container log'
        fi
        height="$(isolated_rpc status 2>/dev/null | jq -r '.result.sync_info.latest_block_height // 0' 2>/dev/null || true)"
        if [[ "$height" =~ ^[0-9]+$ ]] && (( height > HALTED_HEIGHT + 2 )); then break; fi
        sleep 2
      done
      [[ "$height" =~ ^[0-9]+$ ]] && (( height > HALTED_HEIGHT + 2 )) || fail 'no new committed blocks'
      isolated_rpc "block?height=$HALTED_HEIGHT" \
        | jq -e --arg hash "$HALTED_HASH" '.result.block_id.hash | ascii_downcase == $hash' >/dev/null || fail 'confirmed history changed'
      isolated_rpc "validators?height=$((HALTED_HEIGHT + 1))" \
        | jq -e --arg key "$new_key" '.result.total == "1" and (.result.validators|length) == 1
          and .result.validators[0].pub_key.value == $key' >/dev/null || fail 'in-place-testnet did not install the transition validator'
      docker stop --time 30 "$temporary" >/dev/null
      docker rm "$temporary" >/dev/null
      restore_genesis_bytes "$saved/inference/config/genesis.json" "$saved/working/config/genesis.json" "$(jq -er .genesis_file_sha256 "$saved/context.json")"
      restore_external_address "$saved/inference/config/config.toml" "$saved/working/config/config.toml"
      mv "$source" "$saved/pre-fork-home"
      mv "$saved/working" "$source"
      source_override "$deadline" >"$saved/override.json"
      start_promoted_source
      ;;
    services)
      [[ "$role" == source && -e "$saved/boot.complete" ]] || fail 'source is not recovered'
      start_services
      ;;
    reset)
      [[ -e "$saved/backup.complete" && "$role" == returning ]] || fail 'returning Host backup is missing'
      [[ ! -e "$saved/reset.started" ]] || fail 'reset already attempted'
      [[ -z "$(compose ps -q)" ]] || fail 'old deployment was started after the recovery freeze'
      cmp "$signer/state/priv_validator_state.json" "$saved/tmkms/state/priv_validator_state.json" || fail 'old signer state changed'
      touch "$saved/reset.started"
      compose --profile signer down >/dev/null
      mv "$source/data" "$saved/pre-reset-data"
      install -d -m 0700 "$source/data"
      touch "$saved/reset.complete"
      ;;
    import)
      [[ "$role" == returning && -e "$saved/reset.complete" ]] || fail 'restore requires a completed incident reset'
      if [[ -e "$saved/enable.started" ]]; then
        [[ -e "$saved/import.complete" ]] || fail 'signer activation has no completed state sync'
        check_enabled_signer
        printf 'State sync and signer activation already completed; continuing service recovery.\n'
        exit
      fi
      cmp "$signer/state/priv_validator_state.json" "$saved/tmkms/state/priv_validator_state.json" || fail 'old signer state changed'
      jq -e --arg chain "$CHAIN" --arg genesis "$(jq -er .genesis_sha256 "$saved/context.json")" --argjson halted "$HALTED_HEIGHT" '
        .chain_id == $chain and .genesis_sha256 == $genesis and .snapshot_height > $halted
        and .trust_height >= (.snapshot_height + 2) and (.trust_hash|test("^[A-Fa-f0-9]{64}$"))
        and (.rpc_url|test("^https://[A-Za-z0-9.-]+/chain-rpc/?$"))
        and (.peer|test("^[0-9a-f]{40}@[A-Za-z0-9.-]+:[1-9][0-9]{0,4}$"))' "$saved/state-sync.json" >/dev/null \
        || fail 'invalid recovered state-sync metadata'
      trust_height="$(jq -er .trust_height "$saved/state-sync.json")"
      trust_hash="$(jq -er .trust_hash "$saved/state-sync.json")"
      rpc_url="$(jq -er .rpc_url "$saved/state-sync.json")"
      # Accept older retained metadata, but always use the non-redirecting URL.
      rpc_url="${rpc_url%/}/"
      check_statesync_rpc "$rpc_url" "$trust_height" "$trust_hash"
      if [[ -e "$saved/import.complete" ]]; then
        printf 'Continuing the existing native state sync; no reset or key replacement.\n'
        resume_native_sync "$rpc_url" "$trust_height" "$trust_hash"
        exit
      fi
      [[ ! -e "$saved/import.started" ]] || fail 'state-sync initialization was interrupted; inspect before retrying'
      touch "$saved/import.started"
      install -d -m 0700 "$saved/unsigned-key"
      docker run --rm --pull never --network none -v "$source:/root/.inference:ro" -v "$saved/unsigned-key:/unsigned-key" \
        --entrypoint "$binary" "$image" init recovery-full-node --chain-id "$CHAIN" --home /unsigned-key >/dev/null 2>&1
      install -m 0600 "$saved/unsigned-key/config/priv_validator_key.json" "$source/config/priv_validator_key.json"
      install -m 0600 "$saved/unsigned-key/data/priv_validator_state.json" "$source/data/priv_validator_state.json"
      configure_recovery_statesync "$source/config/config.toml" "$rpc_url" "$trust_height" "$trust_hash"
      peer="$(jq -er .peer "$saved/state-sync.json")"
      [[ "$peer" =~ ^[0-9a-f]{40}@[A-Za-z0-9.-]+:[1-9][0-9]{0,4}$ ]] || fail 'invalid recovery peer'
      jq -cn --arg image "$image" --arg binary "$binary" --arg peer "$peer" \
        '{services:{node:{image:$image,restart:"unless-stopped",entrypoint:[$binary],command:["start","--home","/root/.inference",
          "--priv_validator_laddr","","--p2p.persistent_peers",$peer,"--p2p.seeds","","--p2p.pex=false",
          "--rpc.laddr","tcp://0.0.0.0:26657","--api.enable","--api.address","tcp://0.0.0.0:1317"]}}}' >"$saved/override.json"
      persist_compose
      recovered_compose up -d --no-deps --pull never --force-recreate node >/dev/null
      touch "$saved/import.complete"
      ;;
    enable)
      [[ -e "$saved/import.complete" || ( "$role" == source && -e "$saved/boot.complete" ) ]] || fail 'Host has not been restored'
      if [[ -e "$saved/enable.complete" ]]; then
        check_enabled_signer
        exit
      fi
      if [[ -e "$saved/enable.started" ]]; then
        resume_enabled_services
        exit
      fi
      cmp "$signer/state/priv_validator_state.json" "$saved/tmkms/state/priv_validator_state.json" || fail 'signer state changed before activation'
      current="$(rpc status)"
      jq -e --slurpfile state "$saved/tmkms/state/priv_validator_state.json" \
        '.result.sync_info.catching_up == false and (.result.sync_info.latest_block_height|tonumber) > ($state[0].height|tonumber)' \
        <<<"$current" >/dev/null || fail 'node has not passed the last height signed before the recovery'
      touch "$saved/enable.started"
      jq '(.services.node.command | index("--priv_validator_laddr")) as $i
        | .services.node.command[$i+1] = "tcp://0.0.0.0:26658"
        | (.services.node.command | index("--halt-time")) as $h
        | if $h != null then del(.services.node.command[$h:$h+2]) else . end
        | .services.node.restart = "unless-stopped"' "$saved/override.json" >"$saved/override.next.json"
      recovered_compose stop node >/dev/null
      mv "$saved/override.next.json" "$saved/override.json"
      persist_compose
      recovered_compose --profile signer up -d --no-deps --pull never --force-recreate tmkms node >/dev/null
      # The existing deployment retains the account, model, proxy and runtime
      # configuration. No new participant registration or software upgrade.
      start_services
      touch "$saved/enable.complete"
      ;;
    *) fail 'unknown remote operation' ;;
  esac
  printf 'PASS %s %s\n' "$node" "$operation"
  exit
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/validator-backup.sh
source "$ROOT/scripts/validator-backup.sh"
init_gdc_data_root
RUN="$GDC_DATA_ROOT/recovery-$INCIDENT"
host_context() { printf '%s/hosts/%s.json\n' "$RUN" "$1"; }
host_name() {
  local node
  node="$(jq -er .node_name "$(host_context "$1")")"
  valid_node "$node" || fail 'invalid retained deployment name'
  printf '%s\n' "$node"
}
saved_path() { printf '/srv/dai/recovery/%s/%s\n' "$INCIDENT" "$(host_name "$1")"; }
load_recovery() {
  [[ -s "$RUN/source-alias" && -e "$RUN/ready" && -e "$RUN/retired" && -s "$RUN/state-sync.json" ]] \
    || fail 'recovery is not ready; update gdc and rerun network recover with the same source alias to prepare native state sync'
  SOURCE_ALIAS="$(<"$RUN/source-alias")"
  valid_alias "$SOURCE_ALIAS" || fail 'invalid retained source alias'
}
remote() {
  local operation="$1" alias="$2" extra="${3:-}" node=discover role=returning
  valid_alias "$alias" && [[ "$extra" =~ ^[A-Za-z0-9._-]*$ ]] || fail 'invalid remote argument'
  [[ "$alias" != "$SOURCE_ALIAS" ]] || role=source
  [[ "$operation" == inspect ]] || node="$(host_name "$alias")"
  ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$alias" "sudo -n bash -s -- --remote '$operation' '$node' '$role' '$extra'" <"${BASH_SOURCE[0]}"
}
verify_incident_archive() {
  local alias="$1" archive="$2" context source identity node
  context="${3:-$(host_context "$alias")}"; node="$(jq -er .node_name "$context")"
  source="$(jq -er .source "$context")"
  valid_node "$node" && [[ "$source" == "/srv/dai/$node/inference" || "$source" == "/srv/dai/data/$node/inference" ]] \
    || fail 'unsafe Genesis source path'
  ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$alias" "sudo -n cat '$source/config/genesis.json'" >"$context.genesis" \
    || fail "$alias Genesis download failed"
  [[ "$(sha "$context.genesis")" == "$(jq -er .genesis_file_sha256 "$context")" ]] \
    || fail "$alias Genesis file changed since inspection"
  # Archives bind the canonical chain identity, not the JSON file's bytes.
  # Keep both hashes: raw integrity for the retained copy, identity for JOIN.
  identity="$(genesis_sha256 "$context.genesis")" || fail "$alias Genesis is invalid"
  verify_backup_archive "$archive" "$node" "$CHAIN" "$identity" || return
  jq --arg identity "$identity" '. + {genesis_sha256:$identity}' "$context" >"$context.next"
  mv "$context.next" "$context"
}
inspect_host() (
  local alias="$1" context node archive signer public_key existing stage
  valid_alias "$alias" || fail 'invalid SSH alias'
  mkdir -p "$RUN/hosts"
  [[ ! -e "$(host_context "$alias")" ]] || fail 'inspection already retained; inspect the previous attempt before retrying'
  stage="$(mktemp -d "$RUN/.inspect.XXXXXX")"
  trap 'rm -rf -- "$stage"' EXIT
  context="$stage/context.json"
  remote inspect "$alias" >"$context"
  node="$(jq -er .node_name "$context")"
  valid_node "$node" || fail 'invalid deployed node name'
  archive="$GDC_DATA_ROOT/$node-validator-backup.tar"
  verify_incident_archive "$alias" "$archive" "$context"
  if [[ "$alias" != "$SOURCE_ALIAS" ]]; then
    [[ "$(jq -er .genesis_sha256 "$context")" == "$(jq -er .genesis_sha256 "$(host_context "$SOURCE_ALIAS")")" ]] \
      || fail 'returning Host belongs to a different Genesis'
  fi
  # Two aliases for the same physical Host must not permit resetting the
  # source, or running a second restore of an already registered signer.
  for existing in "$RUN"/hosts/*.json; do
    [[ -f "$existing" ]] || continue
    [[ "$(jq -er .machine_sha256 "$existing")" != "$(jq -er .machine_sha256 "$context")" ]] \
      || fail 'this machine is already registered under another alias'
  done
  safe_extract "$archive" "$stage/backup" backup "$node"
  verify_checksum_manifest "$stage/backup"
  signer="$(jq -er .signer "$context")"
  public_key="$(ssh -T "$alias" "sudo -n bash -s -- '$signer/secrets/priv_validator_key.softsign'" <"$ROOT/scripts/tmkms-softsign-public-key.sh")"
  [[ "$public_key" == "$(jq -r .consensus_pubkey "$stage/backup/identity.json")" ]] || fail 'archive does not match the deployed signer'
  sha "$archive" >"$RUN/$alias-archive.sha256"
  mv "$stage/backup" "$RUN/$alias-backup"
  mv "$context.genesis" "$RUN/$alias-genesis.json"
  mv "$context" "$(host_context "$alias")"
)
backup_host() {
  local alias="$1" mode="${2:-backup}" saved peer
  saved="$(saved_path "$alias")"
  if [[ "$mode" == backup ]]; then
    peer="$(jq -er '.node_id + "@" + .public_host + ":" + .p2p_port' "$(host_context "$SOURCE_ALIAS")")"
    # A returning Host may already retain a backup from the failed fork. Keep
    # it on that Host, then capture its CURRENT signer state for this attempt.
    if [[ "$alias" != "$SOURCE_ALIAS" && -e "$RUN/native-prepared" ]]; then
      ssh -T "$alias" "if sudo -n test -e '$saved'; then sudo -n mv '$saved' '$saved.previous-$recovery_generation'; fi"
    fi
    ssh -T "$alias" "sudo -n test ! -e '$saved' && sudo -n install -d -m 0700 '$saved'"
    jq --arg peer "$peer" '. + {recovery_peer:$peer}' "$(host_context "$alias")" \
      | ssh -T "$alias" "sudo -n tee '$saved/context.json' >/dev/null"
  fi
  remote "$mode" "$alias"
  ssh -T "$alias" "sudo -n cat '$saved/tmkms/state/priv_validator_state.json'" >"$RUN/$alias-signer-state.json"
  "$ROOT/scripts/verify-tmkms-signing-state.sh" --minimum "$RUN/$alias-backup/remote-state/tmkms/state/priv_validator_state.json" \
    --observed "$RUN/$alias-signer-state.json" >/dev/null
}
status() { ssh -T "$1" 'curl -fsS --connect-timeout 3 --max-time 10 http://127.0.0.1:26657/status'; }
source_api() {
  local path="$1" response end=$((SECONDS+90))
  [[ "$path" =~ ^/[A-Za-z0-9_./-]+$ ]] || fail 'invalid chain query path'
  while (( SECONDS < end )); do
    if response="$(ssh -T -o ConnectTimeout=10 "$SOURCE_ALIAS" \
      "curl -fsS --max-time 10 'http://127.0.0.1:1317$path'" 2>"$RUN/api-last-error.log")"; then
      printf '%s\n' "$response"
      return
    fi
    sleep 2
  done
  fail 'chain query API did not become ready within 90 seconds'
}
progress() {
  local node="$1" before="$2" end=$((SECONDS + 180)) value
  while (( SECONDS < end )); do
    value="$(status "$node" 2>/dev/null | jq -r '.result.sync_info.latest_block_height // 0' 2>/dev/null || true)"
    if [[ "$value" =~ ^[0-9]+$ ]] && (( value > before )); then return; fi
    sleep 2
  done
  fail "$node did not produce or follow new blocks"
}
same_chain() {
  local node="$1" height='' left right end=$((SECONDS + 180))
  while (( SECONDS < end )); do
    height="$(status "$node" 2>/dev/null | jq -er '.result.sync_info | select(.catching_up == false) | .latest_block_height' 2>/dev/null || true)"
    [[ "$height" =~ ^[0-9]+$ ]] && (( height > HALTED_HEIGHT )) && break
    sleep 2
  done
  [[ "$height" =~ ^[0-9]+$ ]] && (( height > HALTED_HEIGHT )) || fail 'restored node is not caught up'
  left="$(ssh -T "$node" "curl -fsS --max-time 10 'http://127.0.0.1:26657/block?height=$height'")"
  right="$(ssh -T "$SOURCE_ALIAS" "curl -fsS --max-time 10 'http://127.0.0.1:26657/block?height=$height'")"
  jq -ne --slurpfile left <(printf '%s\n' "$left") --slurpfile right <(printf '%s\n' "$right") '
    $left[0] as $left | $right[0] as $right | $left.result.block_id.hash == $right.result.block_id.hash
    and ($left.result.block_id.hash|type) == "string" and ($left.result.block_id.hash|length) == 64
    and $left.result.block.header.app_hash == $right.result.block.header.app_hash' >/dev/null || fail "$node does not match the recovery source at a common height"
}
returning_quorum() {
  jq -ne --argjson keys "$1" --argjson c "$2" --argjson v "$3" '
    $v.result as $set | $set.validators as $vs
    | [$c.result.signed_header.commit.signatures[] | select(.block_id_flag == 2) | (.validator_address|ascii_downcase)] as $signed
    | [$vs[] | select(.pub_key.value as $key | $keys | index($key))
        | select((.address|ascii_downcase) as $address | $signed | index($address)) | (.voting_power|tonumber)] as $power
    | ($set.total|tonumber) == ($vs|length) and ($vs|length) > 0
      and $set.block_height == $c.result.signed_header.header.height
      and (($power|add // 0) * 3 > ([$vs[].voting_power|tonumber]|add) * 2)
  ' >/dev/null
}
wait_returning_quorum() {
  local keys="$1" height commit validators end=$((SECONDS+180))
  printf 'Waiting for a canonical block signed by the returning quorum (up to 180s)...\n' >&2
  while (( SECONDS < end )); do
    height="$(status "$SOURCE_ALIAS" | jq -er .result.sync_info.latest_block_height)" || return $?
    [[ "$height" =~ ^[1-9][0-9]*$ ]] && (( height > HALTED_HEIGHT+1 )) || return 1
    # The latest /commit is a non-canonical SeenCommit and can omit votes
    # subsequently included in the next block. Read that completed commit.
    height=$((height-1))
    commit="$(ssh -T "$SOURCE_ALIAS" "curl -fsS --max-time 10 'http://127.0.0.1:26657/commit?height=$height'")" || return $?
    validators="$(ssh -T "$SOURCE_ALIAS" "curl -fsS --max-time 10 'http://127.0.0.1:26657/validators?height=$height&per_page=100'")" || return $?
    if jq -e --arg height "$height" '.result.canonical == true and .result.signed_header.header.height == $height' <<<"$commit" >/dev/null \
      && returning_quorum "$keys" "$commit" "$validators"; then
      printf '%s\n' "$commit"
      return 0
    fi
    sleep 2
  done
  return 1
}
# Restore the source's original signer only after the Hosts that have joined
# actually commit more than two thirds of the live voting power without it.
finish_recovery() {
  local node height commit validators keys marker end original_key
  local joined=() identities=()
  [[ ! -e "$RUN/handoff.complete" ]] || return 0
  for marker in "$RUN"/*-joined; do
    [[ -f "$marker" ]] || continue
    node="${marker##*/}"; node="${node%-joined}"
    valid_alias "$node" || fail 'invalid retained returning alias'
    joined+=("$node"); identities+=("$RUN/$node-backup/identity.json")
  done
  (( ${#joined[@]} > 0 )) || return 0
  keys="$(jq -cs 'map(.consensus_pubkey)' "${identities[@]}")"
  if [[ -f "$RUN/expected-returning.json" ]]; then
    if ! jq -e --argjson joined "$keys" 'all(.[]; . as $key | $joined | index($key) != null)' "$RUN/expected-returning.json" >/dev/null; then
      printf 'Host restored. Continue reset and join for the remaining validator backups.\n'
      return
    fi
    if [[ ! -e "$RUN/native-key-removal/complete" ]]; then
      printf 'Waiting for the restored original signers to enter the native validator set...\n'
      end=$((SECONDS+2400))
      while (( SECONDS < end )); do
        validators="$(ssh -T "$SOURCE_ALIAS" 'curl -fsS --max-time 10 "http://127.0.0.1:26657/validators?per_page=100"')"
        if jq -e --argjson keys "$keys" '.result.validators as $vs |
          all($keys[]; . as $key | any($vs[]; .pub_key.value==$key and (.voting_power|tonumber)>0))' <<<"$validators" >/dev/null; then break; fi
        sleep 15
      done
      jq -e --argjson keys "$keys" '.result.validators as $vs |
        all($keys[]; . as $key | any($vs[]; .pub_key.value==$key and (.voting_power|tonumber)>0))' <<<"$validators" >/dev/null \
        || fail 'restored signers have not entered the native validator set'
      prepare_governance_key
      native_source_handoff
    fi
  fi
  if ! commit="$(wait_returning_quorum "$keys")"; then
    printf 'Host restored; returning signers do not yet commit a quorum. Continue with the next Host, or repeat the last join after validator activation to check again.\n'
    return 0
  fi
  printf '%s\n' "$commit" >"$RUN/returning-quorum.json"
  height="$(status "$SOURCE_ALIAS" | jq -er .result.sync_info.latest_block_height)"
  remote enable "$SOURCE_ALIAS"
  progress "$SOURCE_ALIAS" "$height"
  if [[ -e "$RUN/handoff-removed" ]]; then
    wait_native_epochs restored
    original_key="$(jq -er .consensus_pubkey "$RUN/$SOURCE_ALIAS-backup/identity.json")"
    ssh -T "$SOURCE_ALIAS" 'curl -fsS --max-time 10 "http://127.0.0.1:26657/validators?per_page=100"' >"$RUN/original-validators.json"
    jq -e --arg key "$original_key" --argjson returning "$keys" '.result.validators as $vs |
      all(($returning + [$key])[]; . as $key | any($vs[]; .pub_key.value==$key and (.voting_power|tonumber)>0))' \
      "$RUN/original-validators.json" >/dev/null || fail 'an original consensus key is missing from the validator set'
  fi
  for node in "${joined[@]}"; do same_chain "$node"; done
  touch "$RUN/handoff.complete"
  printf 'HANDOFF complete: original signers are active. Configure peers, then run network recover check.\n'
}
native_tx() {
  local receipt="$1" hash end response; shift
  if [[ ! -f "$receipt" ]]; then
    printf '%s\n' "$password" | "$CLI" --home "$key_home" tx "$@" \
      --from "${native_from:-recovery}" --keyring-backend file --chain-id "$CHAIN" --node "$rpc_url" --gas auto --gas-adjustment 1.5 \
      --gas-prices 0ngonka --broadcast-mode sync --output json --yes >"$receipt" \
      2> >(sed -u '/^gas estimate: [0-9][0-9]*$/d' >&2)
  fi
  hash="$(jq -er 'select(.code==0) | .txhash' "$receipt")" || fail 'native transaction was rejected'
  [[ "${native_wait:-true}" != false ]] || return 0
  end=$((SECONDS+180))
  while (( SECONDS < end )); do
    response="$("$CLI" query tx "$hash" --node "$rpc_url" --output json 2>/dev/null || true)"
    if jq -e '(.height|tonumber)>0' <<<"$response" >/dev/null 2>&1; then
      printf '%s\n' "$response" >"$receipt.committed"
      jq -e '.code==0' "$receipt.committed" >/dev/null || fail 'native transaction execution failed'
      return
    fi
    sleep 2
  done
  fail 'native transaction outcome is unknown; retain its receipt before retrying'
}
prepare_returning_governance_keys() {
  local marker alias node name address count=0
  printf '[]\n' >"$RUN/returning-voters.json"
  for marker in "$RUN"/*-joined; do
    [[ -f "$marker" ]] || continue
    alias="${marker##*/}"; alias="${alias%-joined}"
    node="$(host_name "$alias")"
    count=$((count+1)); name="returning-$count"
    printf '%s\n%s\n' "$(<"$RUN/$alias-backup/mnemonics/$node-cold.mnemonic")" "$password" \
      | "$CLI" --home "$key_home" keys add "$name" --recover --keyring-backend file >"$key_home/$name.private.log" 2>&1
    address="$(printf '%s\n' "$password" | "$CLI" --home "$key_home" keys show "$name" -a --keyring-backend file)"
    [[ "$address" == "$(jq -er .participant_address "$RUN/$alias-backup/manifest.json")" ]] || fail 'returning governance key does not match the verified backup'
    jq --arg name "$name" '. + [$name]' "$RUN/returning-voters.json" >"$RUN/returning-voters.next"
    mv "$RUN/returning-voters.next" "$RUN/returning-voters.json"
  done
}
vote_native_handoff() {
  local proposal="$1" evidence="$2" name
  local names=(recovery)
  mapfile -t -O 1 names < <(jq -r '.[]' "$RUN/returning-voters.json")
  # Different accounts can broadcast together. Waiting after every vote can
  # consume the short DevNet voting period before the last signer votes.
  for name in "${names[@]}"; do
    native_from="$name" native_wait=false native_tx "$evidence/vote-$name.json" gov vote "$proposal" yes
  done
  for name in "${names[@]}"; do
    native_from="$name" native_tx "$evidence/vote-$name.json" gov vote "$proposal" yes
  done
}
capture_native_groups() {
  local model epoch
  "$CLI" query inference current-epoch-group-data --node "$rpc_url" --output json >"$RUN/group-current.json"
  epoch="$(jq -er .epoch_group_data.epoch_index "$RUN/group-current.json")"
  jq '[.epoch_group_data]' "$RUN/group-current.json" >"$RUN/groups.json"
  while IFS= read -r model; do
    "$CLI" query inference show-epoch-group-data "$epoch" --model-id "$model" --node "$rpc_url" --output json >"$RUN/subgroup.json"
    jq --slurpfile sub "$RUN/subgroup.json" '. + [$sub[0].epoch_group_data]' "$RUN/groups.json" >"$RUN/groups.next"
    mv "$RUN/groups.next" "$RUN/groups.json"
  done < <(jq -r '.epoch_group_data.sub_group_models[]' "$RUN/group-current.json")
}

submit_native_governance() {
  local evidence="$1" messages="$2" deposit proposal response state deadline
  mkdir -p "$evidence"
  source_api /cosmos/gov/v1/params/deposit >"$evidence/deposit.json"
  deposit="$(jq -er '(.params.min_deposit // .deposit_params.min_deposit)[0] | .amount + .denom' "$evidence/deposit.json")"
  jq -n --argjson messages "$messages" --arg deposit "$deposit" '{messages:$messages,deposit:$deposit,metadata:"",
    title:"Complete Community DevNet validator recovery",summary:"Retire the temporary consensus key and restore the original signer using native governance."}' >"$evidence/proposal.json"
  native_tx "$evidence/submit.json" gov submit-proposal "$evidence/proposal.json"
  proposal="$(jq -er '[.events[]? | select(.type=="submit_proposal") | .attributes[]? | select(.key=="proposal_id") | .value] | unique | select(length==1) | .[0]' "$evidence/submit.json.committed")"
  vote_native_handoff "$proposal" "$evidence"
  printf 'Waiting for governance approval and execution...\n'
  deadline=$((SECONDS+300)); state=''
  while (( SECONDS<deadline )); do
    response="$(source_api "/cosmos/gov/v1/proposals/$proposal")"
    printf '%s\n' "$response" >"$evidence/status.json"
    state="$(jq -er .proposal.status <<<"$response")"
    [[ "$state" != PROPOSAL_STATUS_PASSED ]] || return 0
    [[ "$state" == PROPOSAL_STATUS_VOTING_PERIOD ]] || fail 'native recovery proposal did not execute'
    sleep 2
  done
  fail 'native recovery proposal timed out'
}

native_source_handoff() {
  local evidence="$RUN/native-key-removal" socket="$RUN/rpc.sock" port=$((30000+$$%20000))
  local authority address original_key source_operator key keys validators members messages info cons hex missed maximum=0 minimum matched=0
  local deadline height boundary response code
  [[ ! -e "$evidence/complete" ]] || return 0
  mkdir -p "$evidence"
  address="$(jq -er .participant_address "$RUN/$SOURCE_ALIAS-backup/manifest.json")"
  original_key="$(jq -er .consensus_pubkey "$RUN/$SOURCE_ALIAS-backup/identity.json")"
  source_operator="$valoper"
  key="$(ssh -T "$SOURCE_ALIAS" "sudo -n cat '$(saved_path "$SOURCE_ALIAS")/transition-key.public'")"
  keys="$(jq -c . "$RUN/expected-returning.json")"
  if [[ ! -e "$evidence/prepared" ]]; then
    remote resume-temporary "$SOURCE_ALIAS"
    height="$(status "$SOURCE_ALIAS" | jq -er .result.sync_info.latest_block_height)"
    progress "$SOURCE_ALIAS" "$height"
  fi
  ssh -fNT -M -S "$socket" -o BatchMode=yes -o ExitOnForwardFailure=yes -o ConnectTimeout=10 \
    -L "127.0.0.1:$port:127.0.0.1:26657" "$SOURCE_ALIAS"
  trap 'ssh -S "$RUN/rpc.sock" -O exit "$SOURCE_ALIAS" >/dev/null 2>&1 || true' EXIT
  rpc_url="tcp://127.0.0.1:$port"
  prepare_returning_governance_keys
  authority="$(source_api /cosmos/auth/v1beta1/module_accounts/gov | jq -er .account.base_account.address)"
  if [[ ! -e "$evidence/prepared" ]]; then
    [[ -s "$evidence/inference-before.json" ]] || source_api /productscience/inference/inference/params >"$evidence/inference-before.json"
    [[ -s "$evidence/slashing-before.json" ]] || source_api /cosmos/slashing/v1beta1/params >"$evidence/slashing-before.json"
    jq -e '.params.signed_blocks_window=="100"' "$evidence/slashing-before.json" >/dev/null || fail 'native handoff expects the retained 100-block signing window'
    validators="$(ssh -T "$SOURCE_ALIAS" 'curl -fsS --max-time 10 "http://127.0.0.1:26657/validators?per_page=100"')"
    source_api /cosmos/slashing/v1beta1/signing_infos >"$evidence/signing-info.json"
    while IFS= read -r info; do
      cons="$(jq -er .address <<<"$info")"
      hex="$("$CLI" debug addr "$cons" | awk '/^Address \(hex\):/ {print $3}')"
      if jq -e --arg hex "$hex" --argjson keys "$keys" 'any(.result.validators[]; .address==$hex and (.pub_key.value as $key | $keys | index($key)!=null))' <<<"$validators" >/dev/null; then
        matched=$((matched+1))
        missed="$(jq -er '.missed_blocks_counter|tonumber' <<<"$info")"
        (( missed<=maximum )) || maximum="$missed"
      fi
    done < <(jq -c '.info[]' "$evidence/signing-info.json")
    (( matched == $(jq length <<<"$keys") )) || fail 'missing signing counters for a returning validator'
    (( maximum<=35 )) || fail 'returning signers need a healthy signing window before native key removal'
    minimum="$(jq -nr --argjson maximum "$maximum" '(100-($maximum+10))/100|tostring')"
    jq --arg operator "$source_operator" '.params.genesis_guardian_params.guardian_addresses |= map(select(.!=$operator))' \
      "$evidence/inference-before.json" >"$evidence/inference-during.json"
    jq --arg minimum "$minimum" '.params.min_signed_per_window=$minimum | .params.slash_fraction_downtime="0.000000000000000000"' \
      "$evidence/slashing-before.json" >"$evidence/slashing-during.json"
    deadline=$((SECONDS+600))
    while (( SECONDS<deadline )); do
      capture_native_groups
      boundary="$(jq -nr --slurpfile g "$RUN/groups.json" --slurpfile p "$evidence/inference-before.json" \
        '($g[0][0].effective_block_height|tonumber)+($p[0].params.epoch_params.epoch_length|tonumber)')"
      height="$(status "$SOURCE_ALIAS" | jq -er .result.sync_info.latest_block_height)"
      (( boundary-height>=64 )) && break
      sleep 5
    done
    (( boundary-height>=64 )) || fail 'no safe epoch window for native key removal'
    members="$(jq --arg authority "$authority" --arg address "$address" --arg key "$original_key" \
      '[{"@type":"/cosmos.group.v1.MsgUpdateGroupMembers",admin:$authority,group_id:.[0].epoch_group_id,
        member_updates:[{address:$address,weight:"1",metadata:$key}]},
        {"@type":"/cosmos.group.v1.MsgUpdateGroupMetadata",admin:$authority,group_id:.[0].epoch_group_id,metadata:"changed"}]' "$RUN/groups.json")"
    messages="$(jq -n --arg authority "$authority" --argjson members "$members" --slurpfile i "$evidence/inference-during.json" --slurpfile s "$evidence/slashing-during.json" \
      '[{"@type":"/inference.inference.MsgUpdateParams",authority:$authority,params:$i[0].params},
        {"@type":"/cosmos.slashing.v1beta1.MsgUpdateParams",authority:$authority,params:$s[0].params}]+$members')"
    submit_native_governance "$evidence/prepare" "$messages"
    touch "$evidence/prepared"
  fi
  if [[ ! -e "$evidence/removed" ]]; then
    # The old SDK retains zero-power records, but deletes jailed records
    # immediately. Bound downtime to the temporary key with negligible power;
    # returning accounts keep consensus, and the downtime slash is zero.
    deadline=$((SECONDS+180))
    while (( SECONDS<deadline )); do
      response="$(ssh -T "$SOURCE_ALIAS" 'curl -fsS --max-time 10 "http://127.0.0.1:26657/validators?per_page=100"')"
      if jq -e --arg key "$key" '.result.validators as $vs | ([ $vs[]|select(.pub_key.value==$key)|(.voting_power|tonumber)]|add // 0)*3 < ([$vs[]|(.voting_power|tonumber)]|add)' <<<"$response" >/dev/null; then break; fi
      sleep 2
    done
    jq -e --arg key "$key" '.result.validators as $vs | ([ $vs[]|select(.pub_key.value==$key)|(.voting_power|tonumber)]|add // 0)*3 < ([$vs[]|(.voting_power|tonumber)]|add)' <<<"$response" >/dev/null || fail 'temporary signer still prevents returning quorum'
    response="$(wait_returning_quorum "$keys")" || fail 'canonical returning quorum not confirmed; temporary key unchanged, retry handoff'
    printf '%s\n' "$response" >"$evidence/returning-quorum.json"
    native_tx "$RUN/participant-original-key.json" inference submit-new-participant '' --validator-key "$original_key"
    remote enable "$SOURCE_ALIAS"
    deadline=$((SECONDS+900))
    while (( SECONDS<deadline )); do
      response="$(source_api "/cosmos/staking/v1beta1/validators/$source_operator")"
      printf '%s\n' "$response" >"$evidence/temporary-validator.json"
      jq -e '.validator.jailed==true' <<<"$response" >/dev/null && break
      sleep 5
    done
    jq -e '.validator.jailed==true' "$evidence/temporary-validator.json" >/dev/null || fail 'temporary validator was not jailed by native downtime handling'
    capture_native_groups
    messages="$(jq --arg authority "$authority" --arg address "$address" \
      '[.[]|select(any(.validation_weights[]?;.member_address==$address))|
        {"@type":"/cosmos.group.v1.MsgUpdateGroupMembers",admin:$authority,group_id:.epoch_group_id,member_updates:[{address:$address,weight:"0",metadata:""}]}]
        +[{"@type":"/cosmos.group.v1.MsgUpdateGroupMetadata",admin:$authority,group_id:.[0].epoch_group_id,metadata:"changed"}]' "$RUN/groups.json")"
    submit_native_governance "$evidence/remove" "$messages"
    deadline=$((SECONDS+60)); code=''
    while (( SECONDS<deadline )); do
      code="$(ssh -T "$SOURCE_ALIAS" "curl -sS --max-time 10 -o /dev/null -w '%{http_code}' 'http://127.0.0.1:1317/cosmos/staking/v1beta1/validators/$source_operator'")"
      [[ "$code" != 404 ]] || break
      sleep 2
    done
    [[ "$code" == 404 ]] || fail 'temporary staking record still exists; original key must not be declared restored'
    touch "$evidence/removed"
  fi
  messages="$(jq -n --arg authority "$authority" --slurpfile i "$evidence/inference-before.json" --slurpfile s "$evidence/slashing-before.json" \
    '[{"@type":"/inference.inference.MsgUpdateParams",authority:$authority,params:$i[0].params},
      {"@type":"/cosmos.slashing.v1beta1.MsgUpdateParams",authority:$authority,params:$s[0].params}]')"
  submit_native_governance "$evidence/restore-params" "$messages"
  source_api /productscience/inference/inference/params >"$evidence/inference-after.json"
  source_api /cosmos/slashing/v1beta1/params >"$evidence/slashing-after.json"
  jq -e --slurpfile before "$evidence/inference-before.json" '.params==$before[0].params' "$evidence/inference-after.json" >/dev/null || fail 'inference parameters were not restored'
  jq -e --slurpfile before "$evidence/slashing-before.json" '.params==$before[0].params' "$evidence/slashing-after.json" >/dev/null || fail 'slashing parameters were not restored'
  touch "$evidence/complete" "$RUN/handoff-removed"
  ssh -S "$socket" -O exit "$SOURCE_ALIAS" >/dev/null 2>&1
  trap - EXIT
}
retire_lost_keys() {
  local mode="${1:-bootstrap}" address key original_key messages evidence group boundary height
  local socket="$RUN/rpc.sock" port=$((30000 + $$ % 20000)) authority deposit hash proposal deadline response
  evidence="$RUN/governance-$mode"
  mkdir -p "$evidence"
  ssh -fNT -M -S "$socket" -o BatchMode=yes -o ExitOnForwardFailure=yes -o ConnectTimeout=10 \
    -L "127.0.0.1:$port:127.0.0.1:26657" "$SOURCE_ALIAS"
  trap 'ssh -S "$RUN/rpc.sock" -O exit "$SOURCE_ALIAS" >/dev/null 2>&1 || true' EXIT
  rpc_url="tcp://127.0.0.1:$port"
  source_api /productscience/inference/inference/params >"$evidence/params-before.json"
  ssh -T "$SOURCE_ALIAS" 'curl -fsS --max-time 10 http://127.0.0.1:1317/cosmos/auth/v1beta1/module_accounts/gov' >"$evidence/gov-authority.json"
  authority="$(jq -er '.account | select(.name == "gov") | .base_account.address' "$evidence/gov-authority.json")"
  [[ "$authority" =~ ^gonka1[0-9a-z]{20,90}$ ]] || fail 'governance authority is invalid'
  ssh -T "$SOURCE_ALIAS" 'curl -fsS --max-time 10 http://127.0.0.1:1317/cosmos/gov/v1/params/deposit' >"$evidence/gov-deposit.json"
  deposit="$(jq -er '(.params.min_deposit // .deposit_params.min_deposit) | select(length == 1) | .[0]
    | select(.denom == "ngonka" and (.amount|tonumber) > 0 and (.amount|tonumber) <= 1000000000) | .amount + .denom' "$evidence/gov-deposit.json")"
  address="$(jq -er .participant_address "$RUN/$SOURCE_ALIAS-backup/manifest.json")"
  original_key="$(jq -er .consensus_pubkey "$RUN/$SOURCE_ALIAS-backup/identity.json")"
  [[ "$mode" != handoff ]] || prepare_returning_governance_keys
  capture_native_groups
  # Target the current groups only while there is time for voting/execution
  # before their next replacement; otherwise observe the next epoch first.
  if [[ "$mode" == handoff ]]; then
    deadline=$((SECONDS+600))
    while (( SECONDS < deadline )); do
      boundary="$(jq -nr --slurpfile groups "$RUN/groups.json" --slurpfile params "$evidence/params-before.json" \
        '($groups[0][0].effective_block_height|tonumber)+($params[0].params.epoch_params.epoch_length|tonumber)')"
      height="$(status "$SOURCE_ALIAS" | jq -er .result.sync_info.latest_block_height)"
      (( boundary-height >= 20 )) && break
      sleep 10
      capture_native_groups
    done
    (( boundary-height >= 20 )) || fail 'no current-epoch window for native signer handoff'
  fi
  cp -p "$RUN/groups.json" "$evidence/groups-before.json"
  if [[ "$mode" == bootstrap ]]; then
    key="$(ssh -T "$SOURCE_ALIAS" "sudo -n cat '$(saved_path "$SOURCE_ALIAS")/transition-key.public'")"
    bootstrap_group_messages "$authority" "$address" "$key" "$RUN/groups.json" >"$evidence/group-messages.json"
    native_tx "$RUN/participant-bootstrap.json" inference submit-new-participant '' --validator-key "$key"
  else
    [[ "$mode" == handoff ]] || fail 'unknown governance recovery step'
    jq --arg authority "$authority" --arg address "$address" '
      [.[] | select(any(.validation_weights[]?; .member_address==$address)) |
        {"@type":"/cosmos.group.v1.MsgUpdateGroupMembers",admin:$authority,group_id:.epoch_group_id,
          member_updates:[{address:$address,weight:"0",metadata:""}]}]
      + [{"@type":"/cosmos.group.v1.MsgUpdateGroupMetadata",admin:$authority,group_id:.[0].epoch_group_id,metadata:"changed"}]' \
      "$RUN/groups.json" >"$evidence/group-messages.json"
  fi
  messages="$(<"$evidence/group-messages.json")"
  jq --arg authority "$authority" --arg deposit "$deposit" --argjson lost "$LOST" --argjson groups "$messages" '
    .params | .participant_access_params.blocked_participant_addresses |= ((. + $lost)|unique)
    | {messages:([{"@type":"/inference.inference.MsgUpdateParams",authority:$authority,params:.}] + $groups),deposit:$deposit,
       metadata:"",title:"Recover Community DevNet after consensus key loss",
       summary:"Block lost-key identities and repair native PoC group membership without replacing the binary."}
  ' "$evidence/params-before.json" >"$evidence/proposal.json"
  native_tx "$evidence/submit.json" gov submit-proposal "$evidence/proposal.json"
  jq -e '.code == 0' "$evidence/submit.json" >/dev/null || fail 'retirement submission failed'
  hash="$(jq -er .txhash "$evidence/submit.json")"
  deadline=$((SECONDS + 120)); proposal=''
  while (( SECONDS < deadline )); do
    response="$("$CLI" query tx "$hash" --node "$rpc_url" --output json 2>/dev/null || true)"
    if jq -e '.code == 0 and (.height|tonumber) > 0' <<<"$response" >/dev/null 2>&1; then
      printf '%s\n' "$response" >"$evidence/submission-committed.json"
      proposal="$(jq -r '[.events[]? | select(.type == "submit_proposal") | .attributes[]? | select(.key == "proposal_id") | .value] | unique | if length == 1 then .[0] else "" end' <<<"$response")"
      break
    fi
    sleep 2
  done
  [[ "$proposal" =~ ^[1-9][0-9]*$ ]] || fail 'submission outcome unknown; inspect the transaction before retrying'
  if [[ "$mode" == handoff ]]; then
    vote_native_handoff "$proposal" "$evidence"
  else
    native_tx "$evidence/vote.json" gov vote "$proposal" yes
  fi
  deadline=$((SECONDS + 300)); proposal_status=''
  while (( SECONDS < deadline )); do
    ssh -T "$SOURCE_ALIAS" "curl -fsS --max-time 10 'http://127.0.0.1:1317/cosmos/gov/v1/proposals/$proposal'" >"$evidence/proposal-status.json"
    proposal_status="$(jq -er .proposal.status "$evidence/proposal-status.json")"
    [[ "$proposal_status" == PROPOSAL_STATUS_PASSED ]] && break
    [[ "$proposal_status" == PROPOSAL_STATUS_VOTING_PERIOD ]] || fail 'retirement proposal failed'
    sleep 2
  done
  [[ "$proposal_status" == PROPOSAL_STATUS_PASSED ]] || fail 'retirement proposal did not pass within 300 seconds'
  ssh -T "$SOURCE_ALIAS" 'curl -fsS --max-time 10 http://127.0.0.1:1317/productscience/inference/inference/params' >"$evidence/params-after.json"
  jq -e --slurpfile expected "$evidence/proposal.json" '.params == $expected[0].messages[0].params' "$evidence/params-after.json" >/dev/null \
    || fail 'retirement parameters were not applied exactly'
  while IFS= read -r group; do
    "$CLI" query group group-members "$group" --node "$rpc_url" --output json >"$evidence/group-$group-after.json"
    if [[ "$mode" == bootstrap ]]; then
      jq -e --arg address "$address" --arg key "$key" '.members|length==1 and .[0].member.address==$address
        and .[0].member.metadata==$key and (.[0].member.weight|tonumber)>0' "$evidence/group-$group-after.json" >/dev/null \
        || fail 'native bootstrap group membership was not applied'
    else
      jq -e --arg address "$address" 'all(.members[]?; .member.address!=$address)' "$evidence/group-$group-after.json" >/dev/null \
        || fail 'temporary source is still in a native PoC group'
    fi
  done < <(jq -r '.messages[] | select(."@type"=="/cosmos.group.v1.MsgUpdateGroupMembers") | .group_id' "$evidence/proposal.json")
  if [[ "$mode" == handoff ]]; then
    native_tx "$RUN/participant-original-key.json" inference submit-new-participant '' --validator-key "$original_key"
    touch "$RUN/handoff-removed"
  fi
  ssh -S "$socket" -O exit "$SOURCE_ALIAS" >/dev/null 2>&1
  trap - EXIT
  touch "$RUN/retired"
}


prepare_governance_key() {
  local node
  CLI="$HOME/.local/bin/inferenced"
  [[ -x "$CLI" ]] || fail 'runbook-managed inferenced CLI is missing'
  node="$(host_name "$SOURCE_ALIAS")"
  key_home="$RUN/governance-keyring"
  # A previous process's random keyring password is deliberately not stored.
  [[ ! -e "$key_home" ]] || key_home="$(mktemp -d "$RUN/governance-keyring.XXXXXX")"
  mkdir -p "$key_home"
  password="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  printf '%s\n%s\n%s\n' "$(<"$RUN/$SOURCE_ALIAS-backup/mnemonics/$node-cold.mnemonic")" "$password" "$password" \
    | "$CLI" --home "$key_home" keys add recovery --recover --keyring-backend file >"$key_home/import.private.log" 2>&1
  valoper="$(printf '%s\n' "$password" | "$CLI" --home "$key_home" keys show recovery --bech val -a --keyring-backend file)"
}
record_returning_archives() {
  local archive key genesis source_key
  genesis="$(jq -er .genesis_sha256 "$(host_context "$SOURCE_ALIAS")")"
  source_key="$(jq -er .consensus_pubkey "$RUN/$SOURCE_ALIAS-backup/identity.json")"
  printf '[]\n' >"$RUN/expected-returning.json"
  for archive in "$GDC_DATA_ROOT"/*-validator-backup.tar; do
    [[ -f "$archive" && ! -L "$archive" ]] || continue
    key="$(tar -xOf "$archive" manifest.json | jq -er --arg genesis "$genesis" --arg source "$source_key" --argjson lost "$LOST" '
      select(.genesis_sha256==$genesis and .identity.consensus_pubkey!=$source)
      | select(.participant_address as $address | $lost | index($address) | not)
      | .identity.consensus_pubkey' || true)"
    [[ -n "$key" ]] || continue
    jq --arg key "$key" '. + [$key] | unique' "$RUN/expected-returning.json" >"$RUN/expected-returning.next"
    mv "$RUN/expected-returning.next" "$RUN/expected-returning.json"
  done
  jq -e 'length>0' "$RUN/expected-returning.json" >/dev/null || fail 'no returning validator archives were found'
}
restart_native_attempt() {
  local stage previous member
  recovery_generation="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  stage="$(mktemp -d "$GDC_DATA_ROOT/.recover-native.XXXXXX")"
  mkdir -p "$stage/hosts"
  cp -p "$(host_context "$SOURCE_ALIAS")" "$stage/hosts/"
  for member in "$SOURCE_ALIAS-backup" "$SOURCE_ALIAS-archive.sha256" "$SOURCE_ALIAS-genesis.json" \
    "$SOURCE_ALIAS-signer-state.json" source-alias confirmed; do
    cp -a "$RUN/$member" "$stage/"
  done
  printf '%s\n' "$recovery_generation" >"$stage/native-prepared"
  verify_checksum_manifest "$RUN/$SOURCE_ALIAS-backup"
  prepare_governance_key
  confirm_recovery restart
  remote restart-native "$SOURCE_ALIAS"
  previous="$RUN.previous-$recovery_generation"
  mv "$RUN" "$previous"
  mv "$stage" "$RUN"
  printf 'Previous controller receipts retained at %s; no chain database was downloaded.\n' "$previous"
}
query_epoch() {
  source_api /productscience/inference/inference/current_epoch_group_data
}
poc_round_complete() {
  local preserved='{}'
  [[ -z "${5:-}" ]] || preserved="$(jq -c . "$5")"
  jq -ne --argjson preserved "$preserved" --argjson addresses "$1" --argjson lost "$LOST" --slurpfile commits "$2" --slurpfile validations "$3" --slurpfile groups "$4" '
    all($addresses[]; . as $address |
      ((any($commits[0].commits[]?; .participant_address==$address and (.count|tonumber)>0)
      and any($validations[0].poc_validation[]?.poc_validation[]?; .participant_address==$address and (.validated_weight|tonumber)>0))
      or (($preserved.snapshot.episode_anchor_height|tonumber?) == ($groups[0].epoch_group_data.poc_start_block_height|tonumber?)
        and any($preserved.snapshot.model_preserved_nodes[]?.participants[]?; .participant_id==$address and (.node_ids|length)>0)))
      and any($groups[0].epoch_group_data.validation_weights[]?; .member_address==$address and (.weight|tonumber)>0))
    and all($groups[0].epoch_group_data.validation_weights[]?; .member_address as $address | $lost | index($address) | not)'
}
wait_native_epochs() {
  local phase="$1" start current poc end=$((SECONDS+2400)) address addresses marker alias last='' consecutive=0
  address="$(jq -er .participant_address "$RUN/$SOURCE_ALIAS-backup/manifest.json")"
  addresses="$(jq -cn --arg address "$address" '[$address]')"
  if [[ "$phase" == restored ]]; then
    for marker in "$RUN"/*-joined; do
      [[ -f "$marker" ]] || continue
      alias="${marker##*/}"; alias="${alias%-joined}"
      address="$(jq -er .participant_address "$RUN/$alias-backup/manifest.json")"
      addresses="$(jq -c --arg address "$address" '. + [$address] | unique' <<<"$addresses")"
    done
  fi
  mkdir -p "$RUN/epochs-$phase"
  query_epoch >"$RUN/epochs-$phase/start.json"
  start="$(jq -er .epoch_group_data.epoch_index "$RUN/epochs-$phase/start.json")"
  last="$start"
  while (( SECONDS < end )); do
    query_epoch >"$RUN/epochs-$phase/current.json"
    current="$(jq -er .epoch_group_data.epoch_index "$RUN/epochs-$phase/current.json")"
    if [[ "$current" != "$last" ]]; then
      cp -p "$RUN/epochs-$phase/current.json" "$RUN/epochs-$phase/epoch-$current.json"
      poc="$(jq -er .epoch_group_data.poc_start_block_height "$RUN/epochs-$phase/current.json")"
      [[ "$poc" =~ ^[1-9][0-9]*$ ]] || fail 'invalid PoC height'
      ssh -T "$SOURCE_ALIAS" "curl -fsS --max-time 10 http://127.0.0.1:1317/productscience/inference/inference/all_poc_v2_store_commits/$poc" \
        >"$RUN/epochs-$phase/commits-$current.json"
      ssh -T "$SOURCE_ALIAS" "curl -fsS --max-time 10 http://127.0.0.1:1317/productscience/inference/inference/poc_v2_validations_for_stage/$poc" \
        >"$RUN/epochs-$phase/validations-$current.json"
      # Query the snapshot at the same episode, not a later mutable snapshot.
      ssh -T "$SOURCE_ALIAS" "curl -fsS --max-time 10 -H 'x-cosmos-block-height: $poc' http://127.0.0.1:1317/productscience/inference/inference/preserved_nodes_snapshot" \
        >"$RUN/epochs-$phase/preserved-$current.json" || printf '{}\n' >"$RUN/epochs-$phase/preserved-$current.json"
      if (( current == last+1 )) &&
        poc_round_complete "$addresses" "$RUN/epochs-$phase/commits-$current.json" \
          "$RUN/epochs-$phase/validations-$current.json" "$RUN/epochs-$phase/current.json" "$RUN/epochs-$phase/preserved-$current.json" >/dev/null; then
        consecutive=$((consecutive+1))
      else
        consecutive=0
      fi
      printf 'Checking %s PoC: epoch=%s, consecutive committed and validated rounds=%s/2.\n' "$phase" "$current" "$consecutive"
      last="$current"
    fi
    if (( consecutive >= 2 )); then
      return
    fi
    sleep 15
  done
  fail 'native epoch acceptance timed out; retained data and original signer state were not reset'
}
confirm_recovery() {
  local answer
  [[ -r /dev/tty && -w /dev/tty ]] || fail 'an interactive confirmation is required'
  exec 8<>/dev/tty
  if [[ "${1:-}" == statesync ]]; then
    printf 'Prepare native state sync on %s for returning Hosts.\nBriefly stop only node to create a local native snapshot, then restart it.\nNo new fork, governance transaction, database archive download or SSH keys.\nType RECOVER to proceed: ' "$SOURCE_ALIAS" >&8
  elif [[ "${1:-}" == restart ]]; then
    printf 'Restart recovery on %s from the original incident backup at block %s.\nKeep the current post-incident branch on this Host; do not download chain data.\nRemove both lost-key identities and restore native PoC operation.\nType RECOVER to proceed: ' "$SOURCE_ALIAS" "$HALTED_HEIGHT" >&8
  else
    printf 'Recover %s on %s from block %s.\nStop and back up this Host only; preserve its history and keys.\nRetire the two lost-key participants. Other Hosts are handled by their own reset and join commands.\nType RECOVER to proceed: ' \
      "$INCIDENT" "$SOURCE_ALIAS" "$HALTED_HEIGHT" >&8
  fi
  IFS= read -r answer <&8
  [[ "$answer" == RECOVER ]] || fail 'not confirmed; no Host was changed'
}
prepare_rejoin() {
  remote prepare-sync "$SOURCE_ALIAS" || fail 'native state-sync preparation failed; no returning Host was reset'
  remote sync-info "$SOURCE_ALIAS" >"$RUN/state-sync.json.next" || fail 'cannot read the source state-sync metadata'
  jq -e --arg chain "$CHAIN" --argjson height "$HALTED_HEIGHT" '.chain_id == $chain
    and .snapshot_height > $height and .trust_height >= (.snapshot_height + 2)' "$RUN/state-sync.json.next" >/dev/null \
    || fail 'source state-sync preparation is incomplete'
  mv "$RUN/state-sync.json.next" "$RUN/state-sync.json"
  touch "$RUN/ready"
  printf '%s is ready. Use ordinary host reset and host join --source-rpc %s --pex false --restore ARCHIVE --public-host HOST ALIAS.\n' \
    "$SOURCE_ALIAS" "$(jq -er .rpc_url "$RUN/state-sync.json")"
}

wait_rejoin_sync() {
  local alias="$1" end=$((SECONDS + 3600)) response height
  while (( SECONDS < end )); do
    response="$(status "$alias" 2>/dev/null || true)"
    if jq -e --argjson height "$HALTED_HEIGHT" '.result.sync_info.catching_up == false
      and (.result.sync_info.latest_block_height|tonumber) > $height' <<<"$response" >/dev/null 2>&1; then return; fi
    height="$(jq -r '.result.sync_info.latest_block_height // "unavailable"' <<<"$response" 2>/dev/null || true)"
    printf 'Waiting for native state sync on %s; height=%s. Data stays on the Hosts.\n' "$alias" "${height:-unavailable}"
    sleep 10
  done
  fail 'state sync has not completed within one hour; repeat the same join to continue, do not reset again'
}

recover_source() {
  local resume_kind=boot confirmed_this_run=false
  SOURCE_ALIAS="$1"
  valid_alias "$SOURCE_ALIAS" || fail 'expected a safe source SSH alias'
  if [[ -e "$RUN" || -L "$RUN" ]]; then
    [[ ! -L "$RUN" && -f "$RUN/confirmed" && -f "$RUN/source-alias" \
      && "$SOURCE_ALIAS" == "$(<"$RUN/source-alias")" ]] || fail 'this recovery attempt cannot be resumed'
    if [[ -e "$RUN/ready" && ! -e "$RUN/native-prepared" ]]; then
      restart_native_attempt
      confirmed_this_run=true
    fi
    [[ ! -f "$RUN/native-prepared" ]] || recovery_generation="$(<"$RUN/native-prepared")"
    resume_kind="$(remote check-source-resume "$SOURCE_ALIAS")"
    if [[ "$resume_kind" == running ]]; then
      if [[ -e "$RUN/native-bootstrap.complete" ]]; then
        confirm_recovery statesync
        prepare_rejoin
        return
      fi
    fi
    [[ ! -e "$RUN/ready" ]] || fail 'previously ready source is no longer running'
    [[ "$resume_kind" == boot || "$resume_kind" == running || "$resume_kind" == backup || "$resume_kind" == dns-boot || "$resume_kind" == genesis || "$resume_kind" == promoted ]] || fail 'unsupported recovery continuation'
    prepare_governance_key
    [[ "$confirmed_this_run" == true ]] || confirm_recovery
    if [[ "$resume_kind" == backup ]]; then
      backup_host "$SOURCE_ALIAS" resume-backup
    elif [[ "$resume_kind" == dns-boot ]]; then
      remote archive-dns-boot "$SOURCE_ALIAS"
    fi
  else
    RUN="$(mktemp -d "$GDC_DATA_ROOT/.recover-preflight.XXXXXX")"
    trap '[[ "$RUN" != "$GDC_DATA_ROOT"/.recover-preflight.* ]] || rm -rf -- "$RUN"' EXIT
    inspect_host "$SOURCE_ALIAS"
    prepare_governance_key
    confirm_recovery
    mv "$RUN" "$GDC_DATA_ROOT/recovery-$INCIDENT"
    RUN="$GDC_DATA_ROOT/recovery-$INCIDENT"
    key_home="$RUN/governance-keyring"
    trap - EXIT
    printf '%s\n' "$SOURCE_ALIAS" >"$RUN/source-alias"
    touch "$RUN/confirmed"
    recovery_generation="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    printf '%s\n' "$recovery_generation" >"$RUN/native-prepared"
    backup_host "$SOURCE_ALIAS"
  fi
  [[ -e "$RUN/expected-returning.json" ]] || record_returning_archives
  if [[ "$resume_kind" == running ]]; then
    :
  elif [[ "$resume_kind" == promoted ]]; then
    remote resume-promoted "$SOURCE_ALIAS"
  elif [[ "$resume_kind" == genesis ]]; then
    remote resume-genesis "$SOURCE_ALIAS"
  else
    remote boot "$SOURCE_ALIAS" "$valoper"
  fi
  progress "$SOURCE_ALIAS" "$HALTED_HEIGHT"
  [[ -e "$RUN/retired" ]] || retire_lost_keys bootstrap
  if [[ ! -e "$RUN/native-services.complete" ]]; then
    remote services "$SOURCE_ALIAS"
    remote normal-pace "$SOURCE_ALIAS"
    touch "$RUN/native-services.complete"
  fi
  progress "$SOURCE_ALIAS" "$HALTED_HEIGHT"
  remote prepare-poc "$SOURCE_ALIAS"
  wait_native_epochs bootstrap
  touch "$RUN/native-bootstrap.complete"
  prepare_rejoin
}
reset_host() {
  local alias="$1"
  valid_alias "$alias" || fail 'invalid SSH alias'
  load_recovery
  [[ ! -f "$RUN/native-prepared" ]] || recovery_generation="$(<"$RUN/native-prepared")"
  [[ "$alias" != "$SOURCE_ALIAS" ]] || fail 'do not reset the recovery source'
  [[ ! -e "$RUN/$alias-joined" ]] || fail 'this Host has already rejoined; do not reset a recovered signer'
  [[ ! -e "$RUN/$alias-reset" ]] || { printf '%s is already reset for this incident\n' "$alias"; return; }
  [[ ! -e "$RUN/$alias-backup-started" ]] || fail 'a backup was already attempted; inspect retained files before retrying'
  inspect_host "$alias"
  touch "$RUN/$alias-backup-started"
  backup_host "$alias"
  remote reset "$alias"
  touch "$RUN/$alias-reset"
}
join_host() {
  local alias="$1" archive="$2" public_host="$3" saved height
  valid_alias "$alias" || fail 'invalid SSH alias'
  load_recovery
  [[ "$alias" != "$SOURCE_ALIAS" && -e "$RUN/$alias-reset" ]] || fail 'restore requires the incident reset'
  [[ "$public_host" == "$(jq -er .public_host "$(host_context "$alias")")" ]] || fail 'public host differs from the retained deployment'
  [[ -f "$archive" && ! -L "$archive" && "$(sha "$archive")" == "$(<"$RUN/$alias-archive.sha256")" ]] || fail 'restore archive differs from the verified incident backup'
  [[ ! -e "$RUN/$alias-joined" ]] || { same_chain "$alias"; printf '%s is already restored\n' "$alias"; return; }
  saved="$(saved_path "$alias")"
  if [[ -f "$RUN/native-prepared" ]]; then
    remote restore-recipe "$alias" "$(<"$RUN/native-prepared")"
  fi
  # Transfer only the small authenticated trust tuple, never a database archive.
  ssh -T "$alias" "if sudo -n test -f '$saved/state-sync.json'; then cat >/dev/null; else sudo -n tee '$saved/state-sync.json' >/dev/null; fi" <"$RUN/state-sync.json"
  remote import "$alias"
  wait_rejoin_sync "$alias"
  same_chain "$alias"
  remote enable "$alias"
  height="$(status "$alias" | jq -er .result.sync_info.latest_block_height)"
  progress "$alias" "$height"
  same_chain "$alias"
  touch "$RUN/$alias-joined"
  printf 'RESTORED %s with its original signer and matching chain state\n' "$alias"
}

enroll_restored_hosts() {
  local requested_source="$1" aliases="$2" alias context fresh key expected
  local hosts=() keys=() enrolled_aliases=' '
  load_recovery
  [[ "$requested_source" == "$SOURCE_ALIAS" ]] || fail 'source alias differs from this recovery'
  IFS=, read -r -a hosts <<<"$aliases"
  (( ${#hosts[@]} > 0 )) || fail 'returning Hosts must be explicit'
  for alias in "${hosts[@]}"; do
    valid_alias "$alias" && [[ "$alias" != "$SOURCE_ALIAS" && "$enrolled_aliases" != *" $alias "* ]] || fail 'invalid or repeated returning Host'
    enrolled_aliases+="$alias "
    context="$(host_context "$alias")"
    if [[ ! -f "$context" ]]; then
      inspect_host "$alias"
    else
      fresh="$context.rejoin-next"
      remote inspect "$alias" >"$fresh"
      jq -e --slurpfile old "$context" '.machine_sha256==$old[0].machine_sha256 and .node_name==$old[0].node_name' "$fresh" >/dev/null \
        || fail 'returning Host changed its machine binding'
      verify_incident_archive "$alias" "$GDC_DATA_ROOT/$(jq -er .node_name "$fresh")-validator-backup.tar" "$fresh"
      [[ "$(jq -er .genesis_sha256 "$fresh")" == "$(jq -er .genesis_sha256 "$(host_context "$SOURCE_ALIAS")")" ]] || fail 'returning Genesis differs'
      [[ -f "$context.before-rejoin" ]] || cp -p "$context" "$context.before-rejoin"
      mv "$fresh" "$context"
    fi
    same_chain "$alias"
    key="$(jq -er .consensus_pubkey "$RUN/$alias-backup/identity.json")"
    status "$alias" | jq -e --arg key "$key" '.result.validator_info.pub_key.value==$key and .result.sync_info.catching_up==false' >/dev/null \
      || fail 'returning Host is not synchronized with its original signer'
    keys+=("$key")
  done
  expected="$(printf '%s\n' "${keys[@]}" | jq -R . | jq -cs 'sort')"
  [[ "$(jq 'unique|length' <<<"$expected")" -eq "${#keys[@]}" ]] || fail 'duplicate returning signer'
  [[ ! -f "$RUN/expected-returning.json" ]] || jq -e --argjson keys "$expected" 'sort==$keys' "$RUN/expected-returning.json" >/dev/null \
    || fail '--hosts must include all original returning validator backups'
  for alias in "${hosts[@]}"; do touch "$RUN/$alias-joined"; done
}
check_recovery() {
  local aliases="$1" alias key keys temporary height peers hosts=() response
  [[ -e "$RUN/handoff.complete" ]] || fail 'original-key handoff has not completed'
  IFS=, read -r -a hosts <<<"$aliases"
  hosts=("$SOURCE_ALIAS" "${hosts[@]}")
  keys='[]'
  for alias in "${hosts[@]}"; do
    response="$(status "$alias")"
    key="$(jq -er .consensus_pubkey "$RUN/$alias-backup/identity.json")"
    jq -e --arg key "$key" '.result.validator_info.pub_key.value==$key and .result.sync_info.catching_up==false' <<<"$response" >/dev/null || fail "$alias is not using its original signer"
    keys="$(jq -c --arg key "$key" '.+[$key]' <<<"$keys")"
    same_chain "$alias"
  done
  temporary="$(ssh -T "$SOURCE_ALIAS" "sudo -n cat '$(saved_path "$SOURCE_ALIAS")/transition-key.public'")"
  ssh -T "$SOURCE_ALIAS" 'curl -fsS --max-time 10 "http://127.0.0.1:26657/validators?per_page=100"' >"$RUN/check-validators.json"
  jq -e --argjson keys "$keys" --arg temporary "$temporary" '.result as $r | $r.validators as $vs |
    ($r.total|tonumber)==($vs|length) and all($keys[]; . as $k | any($vs[];.pub_key.value==$k and (.voting_power|tonumber)>0))
    and all($vs[]; .pub_key.value!=$temporary and (.pub_key.value as $k | $keys|index($k)!=null))' "$RUN/check-validators.json" >/dev/null \
    || fail 'validator set is not exactly the restored original signers'
  for alias in "${hosts[@]}"; do
    peers="$(ssh -T "$alias" 'curl -fsS --max-time 10 http://127.0.0.1:26657/net_info')"
    jq -e '.result.peers | type=="array" and length>0' <<<"$peers" >/dev/null \
      || fail "$alias has no peer connections"
  done
  height="$(status "$SOURCE_ALIAS" | jq -er .result.sync_info.latest_block_height)"
  progress "$SOURCE_ALIAS" "$height"
  wait_native_epochs restored
  ssh -T "$SOURCE_ALIAS" 'curl -fsS --max-time 10 "http://127.0.0.1:26657/validators?per_page=100"' >"$RUN/check-validators-after-epochs.json"
  jq -e --argjson keys "$keys" '.result as $r | ($r.total|tonumber)==($r.validators|length)
    and ([$r.validators[] | select((.voting_power|tonumber)>0) | .pub_key.value] | sort)==($keys|sort)' \
    "$RUN/check-validators-after-epochs.json" >/dev/null || fail 'original validator set did not survive the epoch transitions'
  source_api /productscience/inference/inference/params >"$RUN/check-retirement.json"
  jq -e --argjson lost "$LOST" '.params.participant_access_params.blocked_participant_addresses as $blocked
    | all($lost[]; . as $a | $blocked | index($a)!=null)' "$RUN/check-retirement.json" >/dev/null || fail 'lost identities are not blocked'
  for alias in "${hosts[@]}"; do same_chain "$alias"; done
  touch "$RUN/complete"
  printf 'RECOVERED: original signers, native epochs, matching state and peer connections verified.\n'
}

incident_main() {
recovery_action="${1:-}"
# Report the location, never the expanded command: it may contain key material.
trap 'report_incident_error "$?" "$LINENO" "${FUNCNAME[0]:-main}"' ERR
mkdir -p "$GDC_DATA_ROOT"
exec 9>"$GDC_DATA_ROOT/.incident-recovery.lock"
flock -n 9 || fail 'another incident recovery command is running'
case "${1:-}" in
  bootstrap) [[ $# == 2 ]] || fail 'expected bootstrap SSH_ALIAS'; recover_source "$2" ;;
  handoff|check)
    [[ $# == 4 && "$3" == --hosts ]] || fail 'expected handoff|check SOURCE_ALIAS --hosts RETURNING_ALIAS,...'
    action="$1"
    enroll_restored_hosts "$2" "$4"
    if [[ "$action" == handoff ]]; then
      finish_recovery
      [[ -e "$RUN/handoff.complete" ]] || fail 'handoff is not complete; retain state and retry handoff'
      printf 'END handoff SUCCESS\n'
    else check_recovery "$4"; fi
    ;;
  *) fail 'expected bootstrap, handoff, or check' ;;
esac
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0
incident_main "$@"
