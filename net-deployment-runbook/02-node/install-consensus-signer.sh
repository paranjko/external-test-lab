#!/usr/bin/env bash
# Install a complete signer generation while consensus is fenced. A durable
# marker and retained directories make interruption fail closed, not roll back.

recovery_require_stopped() (
  set -Eeuo pipefail
  local deploy="$1" ids id
  local -a containers
  ids="$(docker compose --env-file "$deploy/.env" -f "$deploy/compose.yaml" --profile signer ps -aq node tmkms)" || return 1
  mapfile -t containers <<<"$ids"
  [[ ${#containers[@]} -eq 2 ]] || return 1
  for id in "${containers[@]}"; do [[ "$id" =~ ^[a-f0-9]{12,64}$ ]] || return 1; done
  docker inspect "${containers[@]}" | jq -e '
    length == 2 and ([.[].Config.Labels["com.docker.compose.service"]] | sort) == ["node","tmkms"] and
    all(.[]; .State.Running == false and .HostConfig.RestartPolicy.Name == "no")' >/dev/null
)

install_consensus_signer() (
  set -Eeuo pipefail
  { set +x; } 2>/dev/null
  umask 077
  [[ $# -eq 6 ]] || return 2
  local deploy="$1" preparation="$2" key="$3" boundary="$4" expected="$5" public_key_tool="$6"
  local active previous staged run path actual expected_sha
  [[ "$deploy" == /*/deploy && "${deploy%/deploy}" != '' ]] || return 1
  for path in "$deploy" "$preparation"; do
    [[ -d "$path" && ! -L "$path" && "$(readlink -f "$path")" == "$path" ]] || return 1
  done
  for path in "$key" "$boundary" "$public_key_tool" "$preparation/prepared.json" "$preparation/validator-before.tar"; do
    [[ -f "$path" && ! -L "$path" && "$(readlink -f "$path")" == "$path" ]] || return 1
  done
  jq -e '.kind == "gdc-consensus-recovery-preparation" and
    .consensus_processes_stopped == true and .restart_disabled == true and
    .activation_authorized == false' "$preparation/prepared.json" >/dev/null || return 1
  run="$(jq -er .run_id "$preparation/prepared.json")" || return 1
  [[ "$run" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || return 1
  expected_sha="$(jq -er .archive_sha256 "$preparation/prepared.json")" || return 1
  actual="$(sha256sum "$preparation/validator-before.tar")" || return 1
  [[ "${actual%% *}" == "$expected_sha" ]] || return 1
  actual="$(bash "$public_key_tool" "$key")" || return 1
  [[ "$actual" == "$expected" ]] || return 1
  jq -e 'keys == ["block_id","height","round","step"] and
    (.height | type == "string" and test("^[1-9][0-9]{0,17}$")) and
    .round == "2147483647" and .step == 127 and .block_id == null' "$boundary" >/dev/null || return 1
  active="${deploy%/deploy}/signer/tmkms"
  previous="${active}.before-$run"; staged="${active}.staged-$run"
  [[ -d "$active" && ! -L "$active" && "$(readlink -f "$active")" == "$active" ]] || return 1
  [[ ! -e "$previous" && ! -L "$previous" && ! -e "$staged" && ! -L "$staged" ]] || return 1
  # Claim before preparing anything. A partial invocation is never auto-retried.
  mkdir -m 700 "$preparation/install-claim" || return 1
  find "$active" ! -type f ! -type d -print >"$preparation/install-claim/unsupported-paths"
  [[ ! -s "$preparation/install-claim/unsupported-paths" ]] || return 1
  expected_sha="$(jq -er .previous_softsign_sha256 "$preparation/prepared.json")" || return 1
  actual="$(sha256sum "$active/secrets/priv_validator_key.softsign")" || return 1
  [[ "${actual%% *}" == "$expected_sha" ]] || return 1
  recovery_require_stopped "$deploy" || return 1
  cp -a "$active" "$staged" || return 1
  chmod 700 "$staged"
  install -m 600 "$key" "$staged/secrets/priv_validator_key.softsign" || return 1
  install -m 600 "$boundary" "$staged/state/priv_validator_state.json" || return 1
  actual="$(bash "$public_key_tool" "$staged/secrets/priv_validator_key.softsign")" || return 1
  [[ "$actual" == "$expected" ]] || return 1
  sync -f "$staged" || return 1
  recovery_require_stopped "$deploy" || return 1
  actual="$(sha256sum "$active/secrets/priv_validator_key.softsign")" || return 1
  [[ "${actual%% *}" == "$expected_sha" ]] || return 1
  jq -n --arg run "$run" --arg active "$active" --arg previous "$previous" --arg staged "$staged" \
    '{run_id:$run,active:$active,previous:$previous,staged:$staged,activation_authorized:false}' \
    >"$preparation/install-claim/prepared.json" || return 1
  sync -f "$preparation" || return 1
  # No fallback or automatic rollback. If the second rename fails, the active
  # path is absent and consensus must remain stopped for explicit recovery.
  mv -T "$active" "$previous" || return 1
  sync -f "${active%/*}" || return 1
  mv -T "$staged" "$active" || return 1
  sync -f "${active%/*}" || return 1
  actual="$(bash "$public_key_tool" "$active/secrets/priv_validator_key.softsign")" || return 1
  [[ "$actual" == "$expected" ]] || return 1
  cmp -s "$boundary" "$active/state/priv_validator_state.json" || return 1
  jq -n --arg run "$run" --arg key "$expected" --arg previous "$previous" --slurpfile boundary "$boundary" \
    '{schema_version:1,kind:"gdc-consensus-signer-installed",run_id:$run,consensus_pubkey:$key,
      boundary:$boundary[0],previous_directory:$previous,container_recreation_required:true,
      activation_authorized:false}' >"$preparation/installed.json.tmp" || return 1
  sync -f "$preparation" || return 1
  mv -T "$preparation/installed.json.tmp" "$preparation/installed.json" || return 1
  sync -f "$preparation" || return 1
)

recreate_consensus_stopped() (
  set -Eeuo pipefail
  umask 077
  local deploy="$1" preparation="$2" public_key_tool="$3" active expected actual ids path
  local -a containers compose
  [[ "$deploy" == /*/deploy && "${deploy%/deploy}" != '' ]] || return 1
  for path in "$deploy" "$preparation"; do
    [[ -d "$path" && ! -L "$path" && "$(readlink -f "$path")" == "$path" ]] || return 1
  done
  for path in "$preparation/installed.json" "$preparation/containers.json" "$public_key_tool"; do
    [[ -f "$path" && ! -L "$path" && "$(readlink -f "$path")" == "$path" ]] || return 1
  done
  jq -e '.kind == "gdc-consensus-signer-installed" and .activation_authorized == false' \
    "$preparation/installed.json" >/dev/null || return 1
  active="${deploy%/deploy}/signer/tmkms"
  expected="$(jq -er .consensus_pubkey "$preparation/installed.json")" || return 1
  actual="$(bash "$public_key_tool" "$active/secrets/priv_validator_key.softsign")" || return 1
  [[ "$actual" == "$expected" ]] || return 1
  jq -e --slurpfile installed "$preparation/installed.json" \
    '. == $installed[0].boundary' "$active/state/priv_validator_state.json" >/dev/null || return 1
  jq -e 'length == 2 and ([.[].service] | sort) == ["node","tmkms"] and
    all(.[]; .Image | test("^sha256:[a-f0-9]{64}$"))' "$preparation/containers.json" >/dev/null || return 1
  recovery_require_stopped "$deploy" || return 1
  if [[ -e "$preparation/consensus-images.json" ]]; then
    [[ -f "$preparation/consensus-images.json" && ! -L "$preparation/consensus-images.json" ]] || return 1
    jq -e --slurpfile retained "$preparation/containers.json" \
      '. == {services:($retained[0] | map({key:.service,value:{image:.Image,restart:"no"}}) | from_entries)}' \
      "$preparation/consensus-images.json" >/dev/null || return 1
  else
    (set -o noclobber; jq '{services:(map({key:.service,value:{image:.Image,restart:"no"}}) | from_entries)}' \
      "$preparation/containers.json" >"$preparation/consensus-images.json") || return 1
  fi
  sync -f "$preparation" || return 1
  compose=(docker compose --env-file "$deploy/.env" -f "$deploy/compose.yaml" \
    -f "$preparation/consensus-images.json" --profile signer)
  # Compose create has no --no-deps option. Refuse any dependency outside the
  # two fenced services before allowing its normal dependency traversal.
  "${compose[@]}" config --format json | jq -e '
    [.services.node, .services.tmkms] | all(.[];
      . != null and ((.depends_on // {} | keys) | all(.[]; . == "node" or . == "tmkms")) and
      (.links // [] | length == 0) and (.volumes_from // [] | length == 0) and
      ((.network_mode // "") | startswith("service:") | not) and
      ((.ipc // "") | startswith("service:") | not) and
      ((.pid // "") | startswith("service:") | not))' >/dev/null || return 1
  "${compose[@]}" create --no-build --pull never --force-recreate node tmkms || return 1
  recovery_require_stopped "$deploy" || return 1
  ids="$("${compose[@]}" ps -aq node tmkms)" || return 1
  mapfile -t containers <<<"$ids"
  [[ ${#containers[@]} -eq 2 ]] || return 1
  docker inspect "${containers[@]}" | jq '[.[] | {Image,State:{Running:.State.Running},
    HostConfig:{RestartPolicy:.HostConfig.RestartPolicy},
    Config:{Labels:{"com.docker.compose.service":.Config.Labels["com.docker.compose.service"]}},Mounts}]' \
    >"$preparation/recreated-containers.tmp" || return 1
  jq -e --slurpfile retained "$preparation/containers.json" --arg active "$active" '
    length == 2 and ([.[].Config.Labels["com.docker.compose.service"]] | sort) == ["node","tmkms"] and
    all(.[]; . as $container | .Config.Labels["com.docker.compose.service"] as $service |
      ($retained[0] | map(select(.service == $service)) | .[0].Image) == $container.Image and
      $container.State.Running == false and $container.HostConfig.RestartPolicy.Name == "no" and
      (if $service == "tmkms" then
        ([$container.Mounts[] | select(.Destination == "/root/.tmkms")] |
          length == 1 and .[0].Type == "bind" and .[0].Source == $active)
       else true end))' "$preparation/recreated-containers.tmp" >/dev/null || return 1
  # Do not retain Docker environment, which can contain credentials.
  rm -f "$preparation/recreated-containers.tmp"
  jq --slurpfile retained "$preparation/containers.json" \
    '{schema_version:1,kind:"gdc-consensus-containers-recreated",run_id,consensus_pubkey,
      images:($retained[0] | map({key:.service,value:.Image}) | from_entries),activation_authorized:false}' \
    "$preparation/installed.json" >"$preparation/recreated.json.tmp" || return 1
  sync -f "$preparation" || return 1
  mv -T "$preparation/recreated.json.tmp" "$preparation/recreated.json" || return 1
  sync -f "$preparation" || return 1
)

activate_consensus_recovery() (
  set -Eeuo pipefail
  umask 077
  local deploy="$1" preparation="$2" public_key_tool="$3" authorization="$4" active expected actual now ids path status=0
  local -a containers
  [[ "$deploy" == /*/deploy && "${deploy%/deploy}" != '' ]] || return 1
  for path in "$deploy" "$preparation"; do
    [[ -d "$path" && ! -L "$path" && "$(readlink -f "$path")" == "$path" ]] || return 1
  done
  for path in "$authorization" "$preparation/installed.json" "$preparation/recreated.json" "$public_key_tool"; do
    [[ -f "$path" && ! -L "$path" && "$(readlink -f "$path")" == "$path" ]] || return 1
  done
  now="$(date +%s)"
  jq -e --argjson now "$now" --slurpfile installed "$preparation/installed.json" \
    --slurpfile recreated "$preparation/recreated.json" '
    .kind == "gdc-consensus-recovery-activation" and .activation_authorized == true and
    .exclusive_signer_confirmed == true and .run_id == $installed[0].run_id and
    .run_id == $recreated[0].run_id and .consensus_pubkey == $installed[0].consensus_pubkey and
    .consensus_pubkey == $recreated[0].consensus_pubkey and .images == $recreated[0].images and
    (.issued_at_unix | type == "number") and (.expires_at_unix | type == "number") and
    .issued_at_unix <= $now and .expires_at_unix > $now and
    .expires_at_unix <= (.issued_at_unix + 60) and
    (.checkpoint_height | type == "string" and test("^[1-9][0-9]{0,17}$")) and
    ((.checkpoint_height | tonumber) >= ($installed[0].boundary.height | tonumber))
  ' "$authorization" >/dev/null || return 1
  active="${deploy%/deploy}/signer/tmkms"
  expected="$(jq -er .consensus_pubkey "$authorization")" || return 1
  actual="$(bash "$public_key_tool" "$active/secrets/priv_validator_key.softsign")" || return 1
  [[ "$actual" == "$expected" ]] || return 1
  jq -e --slurpfile installed "$preparation/installed.json" '. == $installed[0].boundary' \
    "$active/state/priv_validator_state.json" >/dev/null || return 1
  recovery_require_stopped "$deploy" || return 1
  ids="$(docker compose --env-file "$deploy/.env" -f "$deploy/compose.yaml" --profile signer ps -aq node tmkms)" || return 1
  mapfile -t containers <<<"$ids"
  [[ ${#containers[@]} -eq 2 ]] || return 1
  docker inspect "${containers[@]}" | jq -e --slurpfile authorization "$authorization" '
    length == 2 and ([.[].Config.Labels["com.docker.compose.service"]] | sort) == ["node","tmkms"] and
    all(.[]; .Config.Labels["com.docker.compose.service"] as $service |
      .Image == $authorization[0].images[$service] and .State.Running == false and
      .HostConfig.RestartPolicy.Name == "no")' >/dev/null || return 1
  # Consume before starting: a lost SSH reply must never trigger a blind retry.
  mkdir -m 700 "$preparation/activation-claim" || return 1
  install -m 600 "$authorization" "$preparation/activation-claim/authorization.json" || return 1
  sync -f "$preparation" || return 1
  trap 'status=$?; if ((status != 0)); then docker stop "${containers[@]}" >/dev/null 2>&1 || true; fi; exit "$status"' EXIT
  if ! docker start "${containers[@]}" >/dev/null; then
    docker stop "${containers[@]}" >/dev/null 2>&1 || true
    echo 'Recovery start failed; inspect stopped consensus and retained claim' >&2
    return 1
  fi
  if ! docker inspect "${containers[@]}" | jq -e 'length == 2 and all(.[];
      .State.Running == true and .HostConfig.RestartPolicy.Name == "no")' >/dev/null; then
    docker stop "${containers[@]}" >/dev/null 2>&1 || true
    echo 'Recovery start readback failed; automatic restart remains disabled' >&2
    return 1
  fi
  jq '{schema_version:1,kind:"gdc-consensus-recovery-started",run_id,consensus_pubkey,
    signing_verified:false,restart_enabled:false}' "$authorization" >"$preparation/started.json.tmp" || return 1
  sync -f "$preparation" || return 1
  mv -T "$preparation/started.json.tmp" "$preparation/started.json" || return 1
  sync -f "$preparation" || return 1
)

finalize_consensus_recovery() (
  set -Eeuo pipefail
  local deploy="$1" preparation="$2" public_key_tool="$3" proof="$4" key actual ids id service policy retries path
  local -a containers
  [[ "$deploy" == /*/deploy && "${deploy%/deploy}" != '' ]] || return 1
  for path in "$deploy" "$preparation"; do
    [[ -d "$path" && ! -L "$path" && "$(readlink -f "$path")" == "$path" ]] || return 1
  done
  for path in "$proof" "$public_key_tool" "$preparation/started.json" "$preparation/installed.json" "$preparation/containers.json"; do
    [[ -f "$path" && ! -L "$path" && "$(readlink -f "$path")" == "$path" ]] || return 1
  done
  key="$(jq -er .consensus_pubkey "$preparation/installed.json")" || return 1
  actual="$(bash "$public_key_tool" "${deploy%/deploy}/signer/tmkms/secrets/priv_validator_key.softsign")" || return 1
  [[ "$actual" == "$key" ]] || return 1
  jq -e --arg key "$key" --slurpfile installed "$preparation/installed.json" '
    .kind == "gdc-consensus-recovery-started" and .run_id == $installed[0].run_id and .consensus_pubkey == $key
  ' "$preparation/started.json" >/dev/null || return 1
  jq -e --arg key "$key" --slurpfile installed "$preparation/installed.json" '
    .verdict == "VALIDATING" and .consensus_pubkey == $key and .epoch_transition_verified == true and
    (.signed_blocks | type == "array" and length >= 4 and
      all(.[]; .consensus_pubkey == $key and .signature_verified == true and (.voting_power | type == "number" and . > 0) and
        (.height | tonumber) > ($installed[0].boundary.height | tonumber)) and
      (map(.height) | unique | length) == length and
      (. as $blocks | group_by(.epoch) | any(.[];
        length >= 3 and (.[0].epoch | tonumber) as $first | any($blocks[]; (.epoch | tonumber) > $first))))
  ' "$proof" >/dev/null || return 1
  jq -e --slurpfile installed "$preparation/installed.json" \
    '(.height | tonumber) > ($installed[0].boundary.height | tonumber)' \
    "${deploy%/deploy}/signer/tmkms/state/priv_validator_state.json" >/dev/null || return 1
  jq -e 'length == 2 and ([.[].service] | sort) == ["node","tmkms"] and all(.[];
    (.restart_policy.Name | IN("no","always","unless-stopped","on-failure")) and
    (.restart_policy.MaximumRetryCount | type == "number" and . >= 0 and floor == .))' \
    "$preparation/containers.json" >/dev/null || return 1
  ids="$(docker compose --env-file "$deploy/.env" -f "$deploy/compose.yaml" --profile signer ps -aq node tmkms)" || return 1
  mapfile -t containers <<<"$ids"
  [[ ${#containers[@]} -eq 2 ]] || return 1
  docker inspect "${containers[@]}" | jq -e --slurpfile retained "$preparation/containers.json" '
    length == 2 and ([.[].Config.Labels["com.docker.compose.service"]] | sort) == ["node","tmkms"] and
    all(.[]; . as $container | .Config.Labels["com.docker.compose.service"] as $service |
      .State.Running == true and .Image == ($retained[0][] | select(.service == $service) | .Image))' >/dev/null || return 1
  for id in "${containers[@]}"; do
    [[ "$id" =~ ^[a-f0-9]{12,64}$ ]] || return 1
    service="$(docker inspect "$id" | jq -er '.[0].Config.Labels["com.docker.compose.service"]')" || return 1
    policy="$(jq -er --arg service "$service" '.[] | select(.service == $service) | .restart_policy.Name' "$preparation/containers.json")" || return 1
    retries="$(jq -er --arg service "$service" '.[] | select(.service == $service) | .restart_policy.MaximumRetryCount' "$preparation/containers.json")" || return 1
    [[ "$policy" != on-failure || "$retries" == 0 ]] || policy="on-failure:$retries"
    docker update --restart "$policy" "$id" >/dev/null || return 1
  done
  docker inspect "${containers[@]}" | jq -e --slurpfile retained "$preparation/containers.json" '
    length == 2 and all(.[]; .Config.Labels["com.docker.compose.service"] as $service |
      .State.Running == true and .HostConfig.RestartPolicy ==
        ($retained[0][] | select(.service == $service) | .restart_policy))' >/dev/null || return 1
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ $EUID == 0 ]] || { echo 'Signer installation requires root' >&2; exit 2; }
  if [[ "${1:-}" == --recreate-stopped ]]; then
    shift
    [[ $# -eq 3 ]] || exit 2
    recreate_consensus_stopped "$@"
  elif [[ "${1:-}" == --activate ]]; then
    shift
    [[ $# -eq 4 ]] || exit 2
    activate_consensus_recovery "$@"
  elif [[ "${1:-}" == --finalize ]]; then
    shift
    [[ $# -eq 4 ]] || exit 2
    finalize_consensus_recovery "$@"
  else
    install_consensus_signer "$@"
  fi
fi
