#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: $0 preflight-window [TIMEOUT] | freeze DIR SOURCE_PORT | prepare DIR TARGET_ENV TARGET_COMPOSE_ENV TARGET_PROJECT SOURCE_PORT TARGET_PORT | status DIR | drain DIR [TIMEOUT] | drain-target DIR [TIMEOUT] | restore-source DIR | promote DIR | mark DIR PHASE" >&2
}

action="${1:-}"
shift || true
OPS="${GDC_GATEWAY_OPS_ROOT:-/srv/dai/ops}"
[[ "$OPS" == /* && "$OPS" != / ]] || { echo 'ERROR gateway operations root is invalid' >&2; exit 2; }

valid_port() {
  [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( "$1" <= 65535 ))
}

valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
}

valid_image_ref() {
  [[ -n "$1" && "$1" != *[[:space:]]* && "$1" != *[$\`\\]* ]]
}

value() {
  local file="$1" key="$2"
  sed -n "s/^${key}=//p" "$file" | tail -n1
}

write_manifest_value() {
  local manifest="$1" key="$2" replacement="$3" tmp
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "$replacement" != *$'\n'* ]] || return 2
  tmp="${manifest}.tmp.$$"
  awk -F= -v key="$key" -v replacement="$replacement" '
    $1 == key { print key "=" replacement; found=1; next }
    { print }
    END { if (!found) print key "=" replacement }
  ' "$manifest" >"$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$manifest"
}

write_phase() {
  local manifest="$1" phase="$2" tmp
  [[ "$phase" =~ ^(preparing|prepared|cutover_pending|cutover|drained|promoting|rolled_back|completed|failed)$ ]] || return 2
  tmp="${manifest}.tmp.$$"
  awk -F= -v phase="$phase" '
    $1 == "phase" { print "phase=" phase; found=1; next }
    { print }
    END { if (!found) print "phase=" phase }
  ' "$manifest" >"$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$manifest"
}

load_manifest() {
  local directory="$1"
  manifest="$directory/manifest.env"
  [[ -d "$directory" && -f "$manifest" && ! -L "$manifest" ]] || {
    echo 'ERROR gateway migration state is unavailable' >&2
    exit 1
  }
  # shellcheck disable=SC1090
  source "$manifest"
  [[ "${schema_version:-}" == 1 ]] || { echo 'ERROR gateway migration schema is unsupported' >&2; exit 1; }
  [[ "${phase:-}" =~ ^(preparing|prepared|cutover_pending|cutover|drained|promoting|rolled_back|completed|failed)$ ]] \
    || { echo 'ERROR gateway migration phase is invalid' >&2; exit 1; }
  if ! valid_port "${source_port:-}" || ! valid_port "${target_port:-}"; then
    echo 'ERROR gateway migration ports are invalid' >&2
    exit 1
  fi
  if ! valid_name "${source_version:-}" || ! valid_name "${target_version:-}" \
    || ! valid_name "${target_project:-}"; then
    echo 'ERROR gateway migration identity is invalid' >&2
    exit 1
  fi
  [[ "${source_escrow_id:-}" =~ ^[1-9][0-9]*$ ]] \
    || { echo 'ERROR source gateway escrow identity is invalid' >&2; exit 1; }
  if [[ "${target_escrow_id:-}" == pending ]]; then
    [[ "$phase" =~ ^(preparing|failed)$ ]] \
      || { echo 'ERROR pending target escrow is invalid after preparation' >&2; exit 1; }
  elif [[ ! "${target_escrow_id:-}" =~ ^[1-9][0-9]*$ ]]; then
    echo 'ERROR target gateway escrow identity is invalid' >&2
    exit 1
  fi
  source_env="$directory/source.env"
  target_env="$directory/target.env"
  source_compose_env="$directory/source-compose.env"
  source_compose_yaml="$directory/source-compose.yaml"
  target_compose_env="$directory/target-compose.env"
  source_settings="$directory/source-settings.json"
  [[ -f "$source_env" && -f "$target_env" && -f "$source_compose_env" && -f "$source_compose_yaml" \
    && -f "$target_compose_env" \
    && ! -L "$source_env" && ! -L "$target_env" \
    && ! -L "$source_compose_env" && ! -L "$source_compose_yaml" && ! -L "$target_compose_env" ]] \
    || { echo 'ERROR gateway migration runtime inputs are unavailable' >&2; exit 1; }
  if ! valid_image_ref "${source_image_ref:-}" || ! valid_image_ref "${target_image_ref:-}" \
    || [[ ! "${source_image_id:-}" =~ ^sha256:[0-9a-f]{64}$ \
      || ! "${target_image_id:-}" =~ ^sha256:[0-9a-f]{64}$ \
      || ! "${source_binary_sha256:-}" =~ ^[0-9a-f]{64}$ \
      || ! "${target_binary_sha256:-}" =~ ^[0-9a-f]{64}$ ]]; then
    echo 'ERROR gateway migration image identity is invalid' >&2
    exit 1
  fi
}

image_identity() {
  local compose_env="$1" image_ref image_id
  image_ref="$(value "$compose_env" LOCAL_GATEWAY_IMAGE)"
  valid_image_ref "$image_ref" || return 1
  image_id="$(docker image inspect --format '{{.Id}}' "$image_ref")"
  [[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  printf '%s\t%s\n' "$image_ref" "$image_id"
}

assert_runtime_identity() {
  local port="$1" expected_ref="$2" expected_id="$3" expected_volume="$4" ids=() id
  mapfile -t ids < <(
    docker ps -q --filter label=com.docker.compose.service=devshard-gateway \
      | while IFS= read -r id; do
          docker inspect "$id" \
            | jq -r --arg port "$port" '
                .[0]
                | if any(.Config.Env[]?; . == ("DEVSHARD_PORT=" + $port))
                  then .Id
                  else empty
                  end
              '
        done
  )
  [[ "${#ids[@]}" == 1 ]] || {
    echo "ERROR gateway runtime selection failed port=$port matching_containers=${#ids[@]} expected=1" >&2
    return 1
  }
  id="${ids[0]}"
  docker inspect "$id" | jq -e --arg ref "$expected_ref" --arg image_id "$expected_id" \
    --arg volume "$expected_volume" '
      .[0]
      | .Config.Image == $ref
        and .Image == $image_id
        and ([.Mounts[]? | select(.Destination == "/root/.devshardctl" and .Type == "volume") | .Name]
          | unique) == [$volume]
    ' >/dev/null || {
      echo "ERROR gateway runtime image or exact data volume differs port=$port" >&2
      return 1
    }
}

runtime_volume_for_port() {
  local port="$1" ids=() volumes=() id
  mapfile -t ids < <(
    docker ps -q --filter label=com.docker.compose.service=devshard-gateway \
      | while IFS= read -r id; do
          docker inspect "$id" \
            | jq -r --arg port "$port" '
                .[0]
                | if any(.Config.Env[]?; . == ("DEVSHARD_PORT=" + $port))
                  then .Id
                  else empty
                  end
              '
        done
  )
  [[ "${#ids[@]}" == 1 ]] || {
    echo "ERROR gateway data volume selection failed port=$port matching_containers=${#ids[@]} expected=1" >&2
    return 1
  }
  id="${ids[0]}"
  mapfile -t volumes < <(
    docker inspect "$id" | jq -r '
      [.[0].Mounts[]?
        | select(.Destination == "/root/.devshardctl" and .Type == "volume")
        | .Name]
      | unique[]
    '
  )
  if [[ "${#volumes[@]}" != 1 ]] || ! valid_name "${volumes[0]:-}"; then
    echo "ERROR gateway data volume is ambiguous port=$port matching_volumes=${#volumes[@]} expected=1" >&2
    return 1
  fi
  printf '%s\n' "${volumes[0]}"
}

admin_json() {
  local env_file="$1" port="$2" path="$3"
  (
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
    curl -fsS --connect-timeout 5 --max-time 15 \
      "http://127.0.0.1:${port}${path}" \
      -H "Authorization: Bearer $DEVSHARD_ADMIN_API_KEY"
  )
}

post_settings_file() {
  local env_file="$1" port="$2" payload="$3"
  (
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
    curl -fsS --connect-timeout 5 --max-time 30 -X POST \
      "http://127.0.0.1:${port}/v1/admin/settings" \
      -H "Authorization: Bearer $DEVSHARD_ADMIN_API_KEY" \
      -H 'Content-Type: application/json' --data-binary "@$payload"
  )
}

matching_target_escrows() {
  local env_file="$1" port="$2" model="$3" route="$4" state
  state="$(admin_json "$env_file" "$port" /v1/admin/state)"
  jq -r --arg model "$model" --arg route "$route" '
    [.devshards[]?
      | select((.model // .runtime.model // "") == $model)
      | select((.route_prefix // .runtime.route_prefix // "") == $route)
      | (.id | tostring)
      | select(test("^[1-9][0-9]*$"))]
    | unique[]
  ' <<<"$state"
}

matching_active_escrows() {
  local env_file="$1" port="$2" model="$3" route="$4" state
  state="$(admin_json "$env_file" "$port" /v1/admin/state)"
  jq -r --arg model "$model" --arg route "$route" '
    [.devshards[]?
      | select((.model // .runtime.model // "") == $model)
      | select((.route_prefix // .runtime.route_prefix // "") == $route)
      | select((.active // false) == true)
      | (.id | tostring)
      | select(test("^[1-9][0-9]*$"))]
    | unique | sort_by(tonumber)[]
  ' <<<"$state"
}

ensure_target_escrow() {
  local env_file="$1" port="$2" version="$3" expected="$4" directory="$5"
  local model route amount attempt response http_status curl_rc=0 response_id ids=() id
  model="$(value "$env_file" DEVSHARD_MODEL)"
  route="/devshard/$version"
  amount="$(value "$env_file" DEVSHARD_ROTATION_ESCROW_AMOUNT)"
  attempt="$directory/target-escrow-create.env"
  [[ -n "$model" && "$amount" =~ ^[1-9][0-9]*$ ]] || {
    echo 'ERROR target escrow creation inputs are incomplete' >&2
    return 1
  }

  mapfile -t ids < <(matching_target_escrows "$env_file" "$port" "$model" "$route")
  if (( ${#ids[@]} > 1 )); then
    echo "ERROR target gateway has ambiguous matching escrows model=$model route=$route count=${#ids[@]}" >&2
    return 1
  fi
  if (( ${#ids[@]} == 1 )); then
    id="${ids[0]}"
    [[ "$expected" == pending || "$expected" == "$id" ]] || {
      echo "ERROR retained target escrow differs expected=$expected observed=$id" >&2
      return 1
    }
    printf '%s\n' "$id"
    return 0
  fi
  if [[ "$expected" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR retained target escrow is absent expected=$expected model=$model route=$route" >&2
    return 1
  fi
  if [[ -s "$attempt" ]]; then
    echo "ERROR target escrow creation outcome is ambiguous; no retry was sent model=$model route=$route evidence=$attempt" >&2
    return 1
  fi

  umask 077
  cat >"$attempt" <<EOF
schema_version=1
state=submitting
model=$model
route=$route
amount=$amount
started_at=$(date -u +%FT%TZ)
EOF
  response="$(mktemp)"
  set +e
  http_status="$(curl -sS --connect-timeout 5 --max-time 60 -o "$response" -w '%{http_code}' -X POST \
    "http://127.0.0.1:${port}/v1/admin/escrows" \
    -H "Authorization: Bearer $(value "$env_file" DEVSHARD_ADMIN_API_KEY)" \
    -H 'Content-Type: application/json' \
    --data-binary "$(jq -cn --arg model "$model" --arg route "$route" --argjson amount "$amount" \
      '{amount:$amount,model_id:$model,private_key_env:"DEVSHARD_PRIVATE_KEY",route_prefix:$route,register:true}')")"
  curl_rc=$?
  set -e
  response_id="$(jq -r '.escrow_id // empty | tostring' "$response" 2>/dev/null || true)"
  rm -f "$response"

  for _ in $(seq 1 10); do
    mapfile -t ids < <(matching_target_escrows "$env_file" "$port" "$model" "$route" 2>/dev/null || true)
    (( ${#ids[@]} == 0 )) || break
    sleep 1
  done
  if (( ${#ids[@]} > 1 )); then
    echo "ERROR target gateway created ambiguous matching escrows model=$model route=$route count=${#ids[@]}" >&2
    return 1
  fi
  if (( ${#ids[@]} == 1 )); then
    id="${ids[0]}"
    [[ ! "$response_id" =~ ^[1-9][0-9]*$ || "$response_id" == "$id" ]] || {
      echo "ERROR target escrow response conflicts with registered state response=$response_id observed=$id" >&2
      return 1
    }
    cat >"$attempt" <<EOF
schema_version=1
state=created
model=$model
route=$route
amount=$amount
escrow_id=$id
completed_at=$(date -u +%FT%TZ)
EOF
    printf '%s\n' "$id"
    return 0
  fi

  write_manifest_value "$attempt" state ambiguous
  echo "ERROR target escrow creation did not produce a unique registered runtime curl_exit=$curl_rc http_status=${http_status:-unavailable}; automatic retry is disabled evidence=$attempt" >&2
  return 1
}

configure_target() (
  local env_file="$1" port="$2" rotation_enabled="$3" settlement_enabled="$4"
  local payload model default_max_tokens max_requests max_per_weight max_tokens burst recovery pre_poc temp_count target_count amount
  model="$(value "$env_file" DEVSHARD_MODEL)"
  default_max_tokens="$(value "$env_file" GATEWAY_DEFAULT_MAX_TOKENS)"
  max_requests="$(value "$env_file" GATEWAY_MAX_CONCURRENT_REQUESTS)"
  max_per_weight="$(value "$env_file" GATEWAY_MAX_CONCURRENT_REQUESTS_PER_10000_WEIGHT)"
  max_tokens="$(value "$env_file" GATEWAY_MAX_INPUT_TOKENS_IN_FLIGHT)"
  burst="$(value "$env_file" GATEWAY_PARTICIPANT_REQUEST_BURST)"
  recovery="$(value "$env_file" GATEWAY_PARTICIPANT_RECOVERY_PER_MINUTE)"
  pre_poc="$(value "$env_file" GDC_GATEWAY_PRE_POC_BLOCKS)"
  temp_count="$(value "$env_file" GDC_GATEWAY_ROTATION_TEMP_COUNT)"
  target_count="$(value "$env_file" GDC_GATEWAY_ROTATION_TARGET_COUNT)"
  amount="$(value "$env_file" DEVSHARD_ROTATION_ESCROW_AMOUNT)"
  [[ -n "$model" && "$default_max_tokens" =~ ^[1-9][0-9]*$ \
    && "$max_requests" =~ ^[0-9]+$ && "$max_per_weight" =~ ^[0-9]+$ \
    && "$max_tokens" =~ ^[0-9]+$ && "$burst" =~ ^[1-9][0-9]*$ \
    && "$recovery" =~ ^[1-9][0-9]*$ && "$pre_poc" =~ ^[1-9][0-9]*$ \
    && "$temp_count" =~ ^[1-9][0-9]*$ && "$target_count" =~ ^[1-9][0-9]*$ \
    && "$amount" =~ ^[1-9][0-9]*$ ]] || {
      echo 'ERROR target gateway policy is incomplete' >&2
      return 1
    }
  payload="$(mktemp)"
  trap 'rm -f "$payload"' RETURN
  jq -n \
    --arg model "$model" \
    --argjson default_max_tokens "$default_max_tokens" \
    --argjson max_requests "$max_requests" \
    --argjson max_per_weight "$max_per_weight" \
    --argjson max_tokens "$max_tokens" \
    --argjson burst "$burst" \
    --argjson recovery "$recovery" \
    --argjson rotation_enabled "$rotation_enabled" \
    --argjson settlement_enabled "$settlement_enabled" \
    --argjson pre_poc "$pre_poc" \
    --argjson temp_count "$temp_count" \
    --argjson target_count "$target_count" \
    --argjson amount "$amount" '
      {
        default_request_max_tokens:$default_max_tokens,
        max_concurrent_requests:$max_requests,
        max_concurrent_requests_per_10000_weight:$max_per_weight,
        poc_max_concurrent_requests_per_10000_weight:$max_per_weight,
        max_input_tokens_in_flight:$max_tokens,
        participant_throttle:{request_burst:$burst,recovery_per_minute:$recovery},
        model_limits:[{model_id:$model,max_concurrent_requests:$max_requests,max_input_tokens_in_flight:$max_tokens,access_mode:"api_key"}],
        escrow_rotation:{enabled:$rotation_enabled,settlement_enabled:$settlement_enabled,pre_poc_blocks:$pre_poc,models:[{model_id:$model,temp_count:$temp_count,target_count:$target_count,amount:$amount,private_key_env:"DEVSHARD_PRIVATE_KEY"}]}
      }
    ' >"$payload"
  post_settings_file "$env_file" "$port" "$payload" >/dev/null
)

wait_admin_settings_ready() {
  local env_file="$1" port="$2" role="$3" timeout poll_seconds deadline
  timeout="${GDC_GATEWAY_MIGRATION_ADMIN_READY_TIMEOUT_SECONDS:-120}"
  poll_seconds="${GDC_GATEWAY_MIGRATION_ADMIN_READY_POLL_SECONDS:-2}"
  [[ "$timeout" =~ ^[1-9][0-9]*$ && "$poll_seconds" =~ ^[0-9]+$ ]] || return 2
  deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    if admin_json "$env_file" "$port" /v1/admin/settings >/dev/null 2>&1; then
      return 0
    fi
    sleep "$poll_seconds"
  done
  echo "ERROR $role gateway admin settings did not become ready within ${timeout}s port=$port" >&2
  return 1
}

wait_runtime_ready() {
  local env_file="$1" port="$2" version="$3" escrow="$4" role="$5" deadline state route session model
  model="$(value "$env_file" DEVSHARD_MODEL)"
  deadline=$((SECONDS + ${GDC_GATEWAY_MIGRATION_READY_TIMEOUT_SECONDS:-600}))
  while (( SECONDS < deadline )); do
    state="$(admin_json "$env_file" "$port" /v1/admin/state 2>/dev/null || true)"
    if [[ -n "$state" ]]; then
      route="/devshard/$version"
      session="${version#v}"
      if jq -e --arg escrow "$escrow" --arg route "$route" --arg session "$session" --arg model "$model" '
        (.devshards | type) == "array"
        and any(.devshards[];
          (.id | tostring) == $escrow
          and (.model // .runtime.model // "") == $model
          and (.active // false) == true
          and (.route_prefix // .runtime.route_prefix // "") == $route
          and ((.protocol_version // .runtime.protocol_version // "") | tostring | ltrimstr("v")) == $session
          and ((.runtime.session_version // "") | tostring | ltrimstr("v")) == $session
          and (.runtime.phase // .phase // "") == "active"
          and (.runtime.chain_phase // .chain_phase // "") == "Inference"
          and (.runtime.requests_blocked // .requests_blocked // false) == false)
        and (.capacity.models | type) == "object"
        and any(.capacity.models[]; (.routable // false) == true)
      ' <<<"$state" >/dev/null 2>&1; then
        return 0
      fi
    fi
    sleep 3
  done
  echo "ERROR $role gateway did not become routable protocol=$version port=$port" >&2
  return 1
}

direct_smoke() {
  local env_file="$1" port="$2" key model response
  key="$(value "$env_file" DEVSHARD_API_KEYS)"
  key="${key%%,*}"
  model="$(value "$env_file" DEVSHARD_MODEL)"
  [[ -n "$key" && -n "$model" ]] || { echo 'ERROR target smoke credentials are unavailable' >&2; return 1; }
  response="$(mktemp)"
  trap 'rm -f "$response"' RETURN
  curl -fsS --connect-timeout 5 --max-time "${GDC_GATEWAY_MIGRATION_SMOKE_TIMEOUT_SECONDS:-180}" \
    -o "$response" -X POST "http://127.0.0.1:${port}/v1/chat/completions" \
    -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$model\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with ok\"}]}"
  jq -e --arg model "$model" '
    (.id | type == "string" and length > 0)
    and .model == $model
    and (.choices | type == "array")
    and any(.choices[]?; ((.message.content // .text // "") | type == "string" and length > 0))
  ' "$response" >/dev/null || {
    echo "ERROR target direct inference returned an invalid completion port=$port model=$model" >&2
    return 1
  }
}

sanitized_state() {
  local env_file="$1" port="$2" role="$3" payload
  payload="$(admin_json "$env_file" "$port" /v1/admin/state 2>/dev/null || true)"
  if [[ -z "$payload" ]]; then
    jq -n --arg role "$role" --argjson port "$port" '{role:$role,port:$port,available:false}'
    return
  fi
  jq --arg role "$role" --argjson port "$port" '
    {
      role:$role,
      port:$port,
      available:true,
      in_flight:(.limiter.in_flight_requests // null),
      devshards:[.devshards[]? | {
        id,
        model:(.model // .runtime.model),
        active,
        protocol_version:(.protocol_version // .runtime.protocol_version),
        route_prefix:(.route_prefix // .runtime.route_prefix),
        phase:(.runtime.phase // .phase),
        chain_phase:(.runtime.chain_phase // .chain_phase),
        session_version:.runtime.session_version,
        active_requests:(.runtime.active_requests // .active_requests // null),
        reserved_tokens:(.reserved_tokens // .runtime.reserved_tokens // 0)
      }]
    }
  ' <<<"$payload"
}

drain_runtime() {
  local env_file="$1" port="$2" role="$3" timeout="$4" expected_escrow="$5"
  local deadline state in_flight schema poll_seconds
  [[ "$timeout" =~ ^[1-9][0-9]*$ && "$expected_escrow" =~ ^[1-9][0-9]*$ ]] || return 2
  poll_seconds="${GDC_GATEWAY_MIGRATION_DRAIN_POLL_SECONDS:-5}"
  [[ "$poll_seconds" =~ ^[0-9]+$ ]] || return 2
  deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    state="$(admin_json "$env_file" "$port" /v1/admin/state 2>/dev/null || true)"
    if jq -e --arg escrow "$expected_escrow" '
      def counter:
        if type == "number" and . >= 0 and floor == . then .
        elif type == "string" and test("^[0-9]+$") then tonumber
        else error("invalid counter")
        end;
      type == "object"
      and (.limiter | type) == "object"
      and (.limiter | has("in_flight_requests"))
      and ((.limiter.in_flight_requests | counter) == 0)
      and (.devshards | type) == "array"
      and (.devshards | length) > 0
      and ([.devshards[] | select((.id | tostring) == $escrow)] | length) == 1
      and all(.devshards[];
        ((if (.runtime | type) == "object" and (.runtime | has("active_requests"))
          then .runtime.active_requests
          elif has("active_requests") then .active_requests
          else error("missing active_requests")
          end) | counter) == 0)
    ' <<<"$state" >/dev/null 2>&1; then
      printf 'PASS %s gateway drained through authenticated admin state escrow=%s\n' "$role" "$expected_escrow"
      return 0
    fi
    in_flight="$(jq -r '.limiter.in_flight_requests // "unavailable"' <<<"$state" 2>/dev/null || printf unavailable)"
    schema="$(jq -r --arg escrow "$expected_escrow" '
      if type != "object" then "invalid-root"
      elif (.limiter | type) != "object" or (.limiter | has("in_flight_requests") | not) then "missing-global-counter"
      elif (.devshards | type) != "array" or (.devshards | length) == 0 then "missing-devshards"
      elif ([.devshards[] | select((.id | tostring) == $escrow)] | length) != 1 then "missing-retained-escrow"
      elif any(.devshards[];
        ((.runtime | type) != "object" or (.runtime | has("active_requests") | not))
        and (has("active_requests") | not)) then "missing-active-request-counter"
      else "requests-active-or-counter-invalid"
      end
    ' <<<"$state" 2>/dev/null || printf unavailable)"
    printf 'WAIT %s gateway drain in_flight=%s expected_escrow=%s state=%s\n' \
      "$role" "$in_flight" "$expected_escrow" "$schema"
    sleep "$poll_seconds"
  done
  echo "ERROR $role gateway did not prove a complete zero-request state within ${timeout}s expected_escrow=$expected_escrow" >&2
  return 1
}

restore_source_runtime() {
  local canonical_compose="$OPS/compose.yaml" ids=() id
  [[ -s "$source_compose_yaml" && -s "$source_compose_env" && -s "$source_env" ]] || {
    echo 'ERROR canonical source runtime snapshot is incomplete' >&2
    return 1
  }

  # Stop whatever currently owns the canonical Compose service before
  # restoring the retained source contract. A Docker failure is not safe to
  # ignore because it could leave two runtimes competing for the same port.
  mapfile -t ids < <(
    docker ps -q --filter label=com.docker.compose.service=devshard-gateway \
      | while IFS= read -r id; do
          docker inspect "$id" \
            | jq -r '
                .[0]
                | if any(.Config.Env[]?; . == "DEVSHARD_PORT=18080")
                  then .Id
                  else empty
                  end
              '
        done
  )
  (( ${#ids[@]} <= 1 )) || {
    echo "ERROR canonical gateway ownership is ambiguous matching_containers=${#ids[@]} expected_at_most=1" >&2
    return 1
  }
  if (( ${#ids[@]} == 1 )); then
    docker stop "${ids[0]}" >/dev/null || return 1
  fi
  install -m 0644 "$source_compose_yaml" "$canonical_compose" || return 1
  install -m 0600 "$source_compose_env" "$OPS/.env" || return 1
  install -m 0600 "$source_env" "$OPS/gateway.env" || return 1
  (
    cd "$OPS"
    GDC_GATEWAY_ENV_FILE="$OPS/gateway.env" docker compose \
      --env-file .env --env-file gateway.env up -d --force-recreate devshard-gateway
  ) || return 1
  (
    cd "$directory/04-ops"
    GDC_GATEWAY_ENV_FILE="$target_env" docker compose -p "$target_project" \
      --env-file "$target_compose_env" --env-file "$target_env" \
      up -d --force-recreate devshard-gateway
  ) || return 1
  # Promotion enables the target lifecycle before the final identity and
  # readiness checks. A failure after that mutation persists in gateway.db,
  # so a restored side-by-side target must be frozen again before phase=drained
  # can be recorded for a retry.
  wait_admin_settings_ready "$target_env" "$target_port" target || return 1
  configure_target "$target_env" "$target_port" false false || return 1
  admin_json "$target_env" "$target_port" /v1/admin/settings \
    | jq -e '.escrow_rotation.enabled == false and .escrow_rotation.settlement_enabled == false' \
      >/dev/null || return 1
  assert_runtime_identity "$source_port" "$source_image_ref" "$source_image_id" "$source_volume" || return 1
  assert_runtime_identity "$target_port" "$target_image_ref" "$target_image_id" "$target_volume" || return 1
  wait_runtime_ready "$source_env" "$source_port" "$source_version" "$source_escrow_id" source || return 1
  wait_runtime_ready "$target_env" "$target_port" "$target_version" "$target_escrow_id" target || return 1
}

wait_safe_window() {
  local timeout="$1" deadline height params values epoch_length epoch_shift position
  local poc_duration exchange_duration validation_delay validation_duration validators_delay
  local safe_start safe_end runway
  [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || return 2
  runway="${GDC_GATEWAY_MIGRATION_MIN_RUNWAY_BLOCKS:-20}"
  [[ "$runway" =~ ^[1-9][0-9]*$ ]] || return 2
  deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    height="$(curl -fsS --connect-timeout 3 --max-time 10 http://127.0.0.1:26657/status 2>/dev/null \
      | jq -er '.result.sync_info.latest_block_height | tonumber' 2>/dev/null || true)"
    params="$(curl -fsS --connect-timeout 3 --max-time 10 \
      http://127.0.0.1:1317/productscience/inference/inference/params 2>/dev/null || true)"
    values="$(jq -er '(.params // .).epoch_params
      | [(.epoch_length|tonumber),(.epoch_shift // 0|tonumber),(.poc_stage_duration|tonumber),
         (.poc_exchange_duration|tonumber),(.poc_validation_delay|tonumber),
         (.poc_validation_duration|tonumber),(.set_new_validators_delay|tonumber)] | @tsv' \
      <<<"$params" 2>/dev/null || true)"
    if [[ "$height" =~ ^[0-9]+$ && -n "$values" ]]; then
      read -r epoch_length epoch_shift poc_duration exchange_duration validation_delay \
        validation_duration validators_delay <<<"$values"
      if (( epoch_length <= 0 )); then
        printf 'WAIT gateway migration window epoch_length=invalid\n'
        sleep 3
        continue
      fi
      position=$(((height - epoch_shift) % epoch_length))
      (( position < 0 )) && position=$((position + epoch_length))
      safe_start=$((poc_duration + exchange_duration + validation_delay + validation_duration + validators_delay + 1))
      safe_end=$((epoch_length - runway))
      if (( safe_end < safe_start )); then
        echo "ERROR gateway migration runway ${runway} cannot fit the configured epoch" >&2
        return 1
      fi
      if (( safe_start <= position && position <= safe_end )); then
        printf 'PASS gateway migration window phase=Inference position=%s safe_range=%s-%s height=%s\n' \
          "$position" "$safe_start" "$safe_end" "$height"
        return 0
      fi
      printf 'WAIT gateway migration window position=%s safe_range=%s-%s height=%s\n' \
        "$position" "$safe_start" "$safe_end" "$height"
    else
      printf 'WAIT gateway migration window chain_state=unavailable\n'
    fi
    sleep 3
  done
  echo "ERROR no safe Inference window with at least ${runway} blocks of runway appeared within ${timeout}s" >&2
  return 1
}

case "$action" in
  preflight-window)
    [[ $# -le 1 ]] || { usage; exit 2; }
    wait_safe_window "${1:-600}"
    ;;
  freeze)
    [[ $# -eq 2 ]] || { usage; exit 2; }
    directory="$1"
    source_port="$2"
    if ! valid_port "$source_port" || [[ "$directory" != "$OPS/gateway-migrations/"* ]]; then
      echo 'ERROR gateway migration freeze path or port is unsafe' >&2
      exit 2
    fi
    install -d -m 0700 "$directory"
    source_env="$directory/source.env"
    source_compose_env="$directory/source-compose.env"
    source_compose_yaml="$directory/source-compose.yaml"
    source_settings="$directory/source-settings.json"
    [[ -f "$OPS/gateway.env" && -f "$OPS/.env" && -f "$OPS/compose.yaml" ]] \
      || { echo 'ERROR source gateway environment is unavailable' >&2; exit 1; }
    if [[ ! -s "$source_settings" || ! -s "$source_env" || ! -s "$source_compose_env" \
      || ! -s "$source_compose_yaml" ]]; then
      install -m 0600 "$OPS/gateway.env" "$source_env"
      install -m 0600 "$OPS/.env" "$source_compose_env"
      install -m 0644 "$OPS/compose.yaml" "$source_compose_yaml"
      admin_json "$source_env" "$source_port" /v1/admin/settings >"$source_settings"
      printf 'source_port=%s\n' "$source_port" >"$directory/freeze.env"
      chmod 0600 "$directory/freeze.env"
    fi
    frozen="$(mktemp)"
    source_settings_mutated=false
    cleanup_freeze() {
      local rc=$?
      if (( rc != 0 )) && [[ "$source_settings_mutated" == true ]]; then
        if ! post_settings_file "$source_env" "$source_port" "$source_settings" >/dev/null 2>&1; then
          echo 'ERROR source gateway lifecycle restoration failed after freeze validation failure' >&2
        fi
      fi
      rm -f "$frozen"
      exit "$rc"
    }
    trap cleanup_freeze EXIT
    jq '.escrow_rotation.enabled = false | .escrow_rotation.settlement_enabled = false' \
      "$source_settings" >"$frozen"
    # A failed POST can still have changed the remote runtime. Arm restoration
    # before sending the first lifecycle mutation.
    source_settings_mutated=true
    post_settings_file "$source_env" "$source_port" "$frozen" >/dev/null
    admin_json "$source_env" "$source_port" /v1/admin/settings \
      | jq -e '.escrow_rotation.enabled == false and .escrow_rotation.settlement_enabled == false' >/dev/null
    source_route="$(value "$source_env" DEVSHARD_ROUTE_PREFIX)"
    source_version="${source_route##*/}"
    source_model="$(value "$source_env" DEVSHARD_MODEL)"
    configured_source_escrow_id="$(value "$source_env" DEVSHARD_ESCROW_ID)"
    mapfile -t source_escrow_ids < <(
      matching_active_escrows "$source_env" "$source_port" "$source_model" "$source_route"
    )
    (( ${#source_escrow_ids[@]} > 0 )) \
      || { echo 'ERROR source gateway has no active escrow for its model and route' >&2; exit 1; }
    if [[ -n "$configured_source_escrow_id" ]]; then
      [[ "$configured_source_escrow_id" =~ ^[1-9][0-9]*$ ]] \
        || { echo 'ERROR configured source gateway escrow identity is invalid' >&2; exit 1; }
      printf '%s\n' "${source_escrow_ids[@]}" | grep -Fxq "$configured_source_escrow_id" \
        || { echo 'ERROR configured source gateway escrow is absent from active admin state' >&2; exit 1; }
      source_escrow_id="$configured_source_escrow_id"
    else
      source_escrow_id="${source_escrow_ids[0]}"
    fi
    [[ "$source_version" =~ ^v[345]$ ]] \
      || { echo 'ERROR source gateway runtime identity is incomplete' >&2; exit 1; }
    write_manifest_value "$directory/freeze.env" source_escrow_id "$source_escrow_id"
    write_manifest_value "$directory/freeze.env" source_model "$source_model"
    write_manifest_value "$directory/freeze.env" source_route "$source_route"
    wait_runtime_ready "$source_env" "$source_port" "$source_version" "$source_escrow_id" source
    source_settings_mutated=false
    trap - EXIT
    rm -f "$frozen"
    printf 'PASS source gateway rotation and automatic settlement frozen\n'
    ;;
  prepare)
    [[ $# -eq 6 ]] || { usage; exit 2; }
    directory="$1" uploaded_target_env="$2" uploaded_target_compose_env="$3"
    target_project="$4" source_port="$5" target_port="$6"
    if ! valid_port "$source_port" || ! valid_port "$target_port" || ! valid_name "$target_project"; then
      usage
      exit 2
    fi
    [[ "$source_port" != "$target_port" && "$directory" == "$OPS/gateway-migrations/"* ]] \
      || { echo 'ERROR gateway migration paths or ports are unsafe' >&2; exit 2; }
    install -d -m 0700 "$directory"
    target_env="$directory/target.env"
    target_compose_env="$directory/target-compose.env"
    source_env="$directory/source.env"
    source_compose_env="$directory/source-compose.env"
    source_compose_yaml="$directory/source-compose.yaml"
    source_settings="$directory/source-settings.json"
    manifest="$directory/manifest.env"
    resume_manifest=false
    if [[ -s "$manifest" ]]; then
      requested_target_project="$target_project"
      requested_source_port="$source_port"
      requested_target_port="$target_port"
      load_manifest "$directory"
      case "$phase" in
        prepared|cutover|drained|completed)
          if [[ "$phase" == completed ]]; then
            assert_runtime_identity 18080 "$target_image_ref" "$target_image_id" "$target_volume"
            wait_runtime_ready "$OPS/gateway.env" 18080 "$target_version" "$target_escrow_id" target
          else
            assert_runtime_identity "$source_port" "$source_image_ref" "$source_image_id" "$source_volume"
            assert_runtime_identity "$target_port" "$target_image_ref" "$target_image_id" "$target_volume"
            wait_runtime_ready "$target_env" "$target_port" "$target_version" "$target_escrow_id" target
          fi
          printf 'READY gateway migration already prepared protocol=%s port=%s phase=%s\n' \
            "$target_version" "$target_port" "$phase"
          exit 0
          ;;
        preparing|failed|rolled_back)
          [[ "$requested_target_project" == "$target_project" \
            && "$requested_source_port" == "$source_port" \
            && "$requested_target_port" == "$target_port" ]] \
            || { echo 'ERROR retained gateway migration arguments changed during resume' >&2; exit 1; }
          retained_source_version="$source_version"
          retained_target_version="$target_version"
          retained_source_volume="$source_volume"
          retained_target_volume="$target_volume"
          retained_source_escrow_id="$source_escrow_id"
          retained_target_escrow_id="$target_escrow_id"
          retained_source_image_ref="$source_image_ref"
          retained_source_image_id="$source_image_id"
          retained_target_image_ref="$target_image_ref"
          retained_target_image_id="$target_image_id"
          retained_source_binary_sha256="$source_binary_sha256"
          retained_target_binary_sha256="$target_binary_sha256"
          resume_manifest=true
          ;;
        *)
          echo "ERROR existing gateway migration is not resumable phase=$phase" >&2
          exit 1
          ;;
      esac
    fi
    [[ -f "$OPS/gateway.env" && -f "$OPS/.env" \
      && -f "$uploaded_target_env" && -f "$uploaded_target_compose_env" ]] \
      || { echo 'ERROR source or target gateway environment is unavailable' >&2; exit 1; }
    [[ -s "$source_env" && -s "$source_compose_env" && -s "$source_compose_yaml" \
      && -s "$source_settings" ]] \
      || { echo 'ERROR source lifecycle must be frozen before target escrow preparation' >&2; exit 1; }
    install -m 0600 "$uploaded_target_env" "$target_env"
    install -m 0600 "$uploaded_target_compose_env" "$target_compose_env"
    source_route="$(value "$source_env" DEVSHARD_ROUTE_PREFIX)"
    target_route="$(value "$target_env" DEVSHARD_ROUTE_PREFIX)"
    source_version="${source_route##*/}"
    target_version="${target_route##*/}"
    source_volume="$(value "$source_env" DEVSHARD_GATEWAY_DATA_VOLUME_NAME)"
    [[ -n "$source_volume" ]] || source_volume="$(runtime_volume_for_port "$source_port")"
    target_volume="$(value "$target_env" DEVSHARD_GATEWAY_DATA_VOLUME_NAME)"
    source_escrow_id="$(value "$source_env" DEVSHARD_ESCROW_ID)"
    [[ -n "$source_escrow_id" ]] \
      || source_escrow_id="$(value "$directory/freeze.env" source_escrow_id)"
    target_escrow_id=pending
    source_binary_sha256="$(value "$source_env" DEVSHARD_BINARY_SHA256)"
    target_binary_sha256="$(value "$target_env" DEVSHARD_BINARY_SHA256)"
    IFS=$'\t' read -r source_image_ref source_image_id < <(image_identity "$source_compose_env") \
      || { echo 'ERROR source gateway image identity is unavailable' >&2; exit 1; }
    IFS=$'\t' read -r target_image_ref target_image_id < <(image_identity "$target_compose_env") \
      || { echo 'ERROR target gateway image identity is unavailable' >&2; exit 1; }
    [[ "$source_version" =~ ^v[345]$ && "$target_version" =~ ^v[345]$ \
      && "$source_version" != "$target_version" && "$source_volume" != "$target_volume" \
      && "$source_image_id" != "$target_image_id" \
      && "$source_escrow_id" =~ ^[1-9][0-9]*$ \
      && "$source_binary_sha256" =~ ^[0-9a-f]{64}$ \
      && "$target_binary_sha256" =~ ^[0-9a-f]{64}$ ]] \
      || { echo 'ERROR source and target gateway identities are not distinct and complete' >&2; exit 1; }
    assert_runtime_identity "$source_port" "$source_image_ref" "$source_image_id" "$source_volume"
    umask 077
    if [[ "$resume_manifest" == true ]]; then
      [[ "$source_version" == "$retained_source_version" \
        && "$target_version" == "$retained_target_version" \
        && "$source_volume" == "$retained_source_volume" \
        && "$target_volume" == "$retained_target_volume" \
        && "$source_escrow_id" == "$retained_source_escrow_id" \
        && "$source_image_ref" == "$retained_source_image_ref" \
        && "$source_image_id" == "$retained_source_image_id" \
        && "$target_image_ref" == "$retained_target_image_ref" \
        && "$target_image_id" == "$retained_target_image_id" \
        && "$source_binary_sha256" == "$retained_source_binary_sha256" \
        && "$target_binary_sha256" == "$retained_target_binary_sha256" ]] \
        || { echo 'ERROR retained gateway migration identity changed during resume' >&2; exit 1; }
      target_escrow_id="$retained_target_escrow_id"
      write_phase "$manifest" preparing
    else
      cat >"$manifest" <<EOF
schema_version=1
phase=preparing
source_version=$source_version
target_version=$target_version
source_port=$source_port
target_port=$target_port
source_volume=$source_volume
target_volume=$target_volume
source_escrow_id=$source_escrow_id
target_escrow_id=$target_escrow_id
target_project=$target_project
source_image_ref=$source_image_ref
source_image_id=$source_image_id
target_image_ref=$target_image_ref
target_image_id=$target_image_id
source_binary_sha256=$source_binary_sha256
target_binary_sha256=$target_binary_sha256
created_at=$(date -u +%FT%TZ)
EOF
      chmod 0600 "$manifest"
    fi
    cleanup_prepare() {
      rc=$?
      if (( rc != 0 )); then
        post_settings_file "$source_env" "$source_port" "$source_settings" >/dev/null 2>&1 || true
        (
          cd "$directory/04-ops"
          GDC_GATEWAY_ENV_FILE="$target_env" docker compose -p "$target_project" \
            --env-file "$target_compose_env" --env-file "$target_env" stop devshard-gateway >/dev/null 2>&1 || true
        )
        write_phase "$manifest" failed || true
      fi
      exit "$rc"
    }
    trap cleanup_prepare EXIT
    (
      cd "$directory/04-ops"
      export GDC_GATEWAY_ENV_FILE="$target_env"
      docker compose -p "$target_project" --env-file "$target_compose_env" --env-file "$target_env" \
        up -d --force-recreate devshard-gateway
    )
    for _ in $(seq 1 60); do
      admin_json "$target_env" "$target_port" /v1/admin/settings >/dev/null 2>&1 && break
      sleep 2
    done
    admin_json "$target_env" "$target_port" /v1/admin/settings >/dev/null
    assert_runtime_identity "$target_port" "$target_image_ref" "$target_image_id" "$target_volume"
    target_escrow_id="$(ensure_target_escrow "$target_env" "$target_port" "$target_version" \
      "$target_escrow_id" "$directory")"
    write_manifest_value "$manifest" target_escrow_id "$target_escrow_id"
    configure_target "$target_env" "$target_port" false false
    wait_runtime_ready "$target_env" "$target_port" "$target_version" "$target_escrow_id" target
    direct_smoke "$target_env" "$target_port"
    write_phase "$manifest" prepared
    trap - EXIT
    printf 'PASS target gateway prepared side-by-side source=%s target=%s target_port=%s\n' \
      "$source_version" "$target_version" "$target_port"
    ;;
  status)
    [[ $# -eq 1 ]] || { usage; exit 2; }
    load_manifest "$1"
    jq -n --arg phase "$phase" \
      --arg source_image_ref "$source_image_ref" --arg source_image_id "$source_image_id" \
      --arg target_image_ref "$target_image_ref" --arg target_image_id "$target_image_id" \
      --arg source_binary_sha256 "$source_binary_sha256" --arg target_binary_sha256 "$target_binary_sha256" \
      --argjson source "$(sanitized_state "$source_env" "$source_port" source)" \
      --argjson target "$(sanitized_state "$target_env" "$target_port" target)" \
      '{phase:$phase,images:{source:{reference:$source_image_ref,id:$source_image_id,binary_sha256:$source_binary_sha256},target:{reference:$target_image_ref,id:$target_image_id,binary_sha256:$target_binary_sha256}},source:$source,target:$target}'
    ;;
  drain)
    [[ $# -ge 1 && $# -le 2 ]] || { usage; exit 2; }
    load_manifest "$1"
    [[ "$phase" =~ ^(cutover|drained)$ ]] \
      || { echo "ERROR source drain requires cutover phase=$phase" >&2; exit 1; }
    timeout="${2:-900}"
    drain_runtime "$source_env" "$source_port" source "$timeout" "$source_escrow_id"
    write_phase "$manifest" drained
    ;;
  drain-target)
    [[ $# -ge 1 && $# -le 2 ]] || { usage; exit 2; }
    load_manifest "$1"
    [[ "$phase" =~ ^(prepared|cutover_pending|cutover|drained|promoting)$ ]] \
      || { echo "ERROR target drain is unavailable phase=$phase" >&2; exit 1; }
    drain_runtime "$target_env" "$target_port" target "${2:-900}" "$target_escrow_id"
    ;;
  restore-source)
    [[ $# -eq 1 ]] || { usage; exit 2; }
    directory="$1"
    if [[ -s "$directory/manifest.env" ]]; then
      load_manifest "$directory"
      [[ "$phase" =~ ^(prepared|cutover_pending|cutover|drained|promoting|rolled_back|failed|preparing)$ ]] \
        || { echo "ERROR source lifecycle cannot be restored from phase=$phase" >&2; exit 1; }
    else
      [[ -s "$directory/freeze.env" ]] || { echo 'ERROR source gateway freeze state is unavailable' >&2; exit 1; }
      # shellcheck disable=SC1090
      source "$directory/freeze.env"
      source_env="$directory/source.env"
      source_settings="$directory/source-settings.json"
      manifest=''
    fi
    [[ -s "$source_settings" ]] || { echo 'ERROR source gateway settings snapshot is unavailable' >&2; exit 1; }
    if [[ -n "$manifest" && "$phase" == promoting ]]; then
      restore_source_runtime
    fi
    post_settings_file "$source_env" "$source_port" "$source_settings" >/dev/null
    [[ -z "$manifest" ]] || write_phase "$manifest" rolled_back
    printf 'READY source gateway lifecycle settings restored\n'
    ;;
  promote)
    [[ $# -eq 1 ]] || { usage; exit 2; }
    directory="$1"
    load_manifest "$directory"
    if [[ "$phase" == completed ]]; then
      wait_runtime_ready "$OPS/gateway.env" 18080 "$target_version" "$target_escrow_id" target
      printf 'READY target gateway is already promoted to the canonical port\n'
      exit 0
    fi
    if [[ "$phase" == promoting ]]; then
      if restore_source_runtime; then
        write_phase "$manifest" drained
        phase=drained
        printf 'READY incomplete target promotion restored to the drained side-by-side state\n'
      else
        echo 'ERROR incomplete target promotion could not restore both retained runtimes' >&2
        exit 1
      fi
    fi
    [[ "$phase" == drained ]] || { echo "ERROR promotion requires drained source phase=$phase" >&2; exit 1; }
    drain_runtime "$target_env" "$target_port" target 900 "$target_escrow_id"
    drain_runtime "$source_env" "$source_port" source 900 "$source_escrow_id"
    promoted="$directory/promoted.env"
    sed -e 's/^DEVSHARD_PORT=.*/DEVSHARD_PORT=18080/' \
      -e 's#^GDC_GATEWAY_ADMIN_URL=.*#GDC_GATEWAY_ADMIN_URL=http://127.0.0.1:18080#' \
      -e 's#^GDC_GATEWAY_RECONCILIATION_URL=.*#GDC_GATEWAY_RECONCILIATION_URL=http://127.0.0.1:18080#' \
      "$target_env" >"$promoted"
    chmod 0600 "$promoted"
    write_phase "$manifest" promoting
    cleanup_promotion() {
      local rc=$?
      if (( rc != 0 )); then
        if restore_source_runtime; then
          write_phase "$manifest" drained
          echo 'ERROR target promotion failed; both retained runtimes were restored for a safe retry' >&2
        else
          echo 'ERROR target promotion failed and runtime restoration is incomplete; retained phase=promoting' >&2
        fi
      fi
      exit "$rc"
    }
    trap cleanup_promotion EXIT
    cd "$OPS"
    GDC_GATEWAY_ENV_FILE="$source_env" docker compose \
      --env-file "$source_compose_env" --env-file "$source_env" stop devshard-gateway
    (
      cd "$directory/04-ops"
      GDC_GATEWAY_ENV_FILE="$target_env" docker compose -p "$target_project" \
        --env-file "$target_compose_env" --env-file "$target_env" stop devshard-gateway
    )
    install -m 0600 "$promoted" "$OPS/gateway.env"
    install -m 0600 "$target_compose_env" "$OPS/.env"
    install -m 0644 "$directory/04-ops/compose.yaml" "$OPS/compose.yaml"
    GDC_GATEWAY_ENV_FILE="$OPS/gateway.env" docker compose --env-file .env --env-file gateway.env \
      up -d --force-recreate devshard-gateway
    wait_admin_settings_ready "$OPS/gateway.env" 18080 target
    configure_target "$OPS/gateway.env" 18080 true true
    assert_runtime_identity 18080 "$target_image_ref" "$target_image_id" "$target_volume"
    wait_runtime_ready "$OPS/gateway.env" 18080 "$target_version" "$target_escrow_id" target
    write_phase "$manifest" completed
    trap - EXIT
    printf 'PASS target gateway promoted to canonical port; source volume preserved=%s\n' "$source_volume"
    ;;
  mark)
    [[ $# -eq 2 ]] || { usage; exit 2; }
    load_manifest "$1"
    case "$phase:$2" in
      prepared:cutover_pending) write_phase "$manifest" cutover_pending ;;
      cutover_pending:cutover) write_phase "$manifest" cutover ;;
      cutover:cutover|drained:cutover) printf 'READY gateway migration cutover was already recorded phase=%s\n' "$phase" ;;
      *) echo "ERROR invalid gateway migration transition current=$phase requested=$2" >&2; exit 1 ;;
    esac
    ;;
  *)
    usage
    exit 2
    ;;
esac
