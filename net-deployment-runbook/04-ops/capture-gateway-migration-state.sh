#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[[ $# -eq 5 ]] || {
  echo 'usage: capture-gateway-migration-state.sh SOURCE_VERSION TARGET_VERSION TARGET_PORT EXPECTED_CHAIN_ID EXPECTED_MODEL' >&2
  exit 2
}

source_version="$1"
target_version="$2"
target_port="$3"
expected_chain_id="$4"
expected_model="$5"
ops_dir="${GDC_OPS_DIR:-/srv/dai/ops}"
source_env="$ops_dir/gateway.env"
target_env="$ops_dir/gateway-migration-target.env"

[[ "$source_version" =~ ^v[345]$ && "$target_version" =~ ^v[345]$ && "$source_version" != "$target_version" ]] || {
  echo 'source and target must be different supported DevShard versions' >&2
  exit 2
}
[[ "$target_port" =~ ^[1-9][0-9]{0,4}$ && "$target_port" -le 65535 ]] || {
  echo 'target port must be from 1 through 65535' >&2
  exit 2
}
[[ "$expected_chain_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && -n "$expected_model" ]] || {
  echo 'expected chain ID and model must be explicit' >&2
  exit 2
}
[[ -s "$source_env" ]] || {
  echo "source gateway environment is unavailable: $source_env" >&2
  exit 1
}

read_env() {
  local file="$1" key="$2"
  sed -n "s/^${key}=//p" "$file" | head -n1
}

sanitize_state() {
  jq -c '
    {
      available: true,
      host_count: (.capacity.host_count | tonumber?),
      in_flight_requests: (.limiter.in_flight_requests | tonumber?),
      devshards: [
        .devshards[]?
        | {
            model: (.model // ""),
            route_prefix: (.route_prefix // ""),
            active: (.active // false),
            session_version: (.runtime.session_version // ""),
            phase: (.runtime.phase // ""),
            chain_phase: (.runtime.chain_phase // ""),
            requests_blocked: (.runtime.requests_blocked // false),
            active_requests: (.runtime.active_requests | tonumber?)
          }
      ]
    }
  '
}

validate_rpc_url() {
  local url="$1"
  [[ "$url" != *'@'* && "$url" != *'?'* && "$url" != *'#'* ]] || return 1
  [[ "$url" =~ ^https://[^/]+/.*/?$ || "$url" =~ ^http://(127\.0\.0\.1|localhost|[A-Za-z0-9.-]+):[0-9]+/?$ ]]
}

capture_rpc_status() {
  local rpc="$1" status_url payload latest_epoch now_epoch max_age fresh=false
  status_url="${rpc%/}/status"
  payload="$(curl -fsS --connect-timeout 3 --max-time 15 "$status_url" | jq -c '
    .result
    | {
        network: .node_info.network,
        height: (.sync_info.latest_block_height | tonumber?),
        catching_up: .sync_info.catching_up,
        latest_block_time: .sync_info.latest_block_time
      }
  ')"
  max_age="${GDC_GATEWAY_MIGRATION_MAX_BLOCK_AGE_SECONDS:-120}"
  [[ "$max_age" =~ ^[1-9][0-9]*$ ]] || {
    echo 'GDC_GATEWAY_MIGRATION_MAX_BLOCK_AGE_SECONDS must be positive' >&2
    return 2
  }
  latest_epoch="$(date -u -d "$(jq -er .latest_block_time <<<"$payload")" +%s 2>/dev/null || true)"
  now_epoch="$(date -u +%s)"
  if [[ "$latest_epoch" =~ ^[0-9]+$ ]] \
    && (( latest_epoch <= now_epoch + 30 && now_epoch - latest_epoch <= max_age )); then
    fresh=true
  fi
  jq -c --argjson fresh "$fresh" '. + {fresh:$fresh}' <<<"$payload"
}

sanitize_settings() {
  jq -c '
    {
      rotation_enabled: (.escrow_rotation.enabled // true),
      settlement_enabled: (.escrow_rotation.settlement_enabled // true)
    }
  '
}

stats_listener_scope() {
  local sockets
  command -v ss >/dev/null 2>&1 || { printf 'unknown\n'; return; }
  sockets="$(ss -H -ltn 2>/dev/null | awk '$4 ~ /:9091$/ { print $4 }')"
  [[ -n "$sockets" ]] || { printf 'absent\n'; return; }
  if ! grep -Eqv '^(127\.0\.0\.1|\[::1\]):9091$' <<<"$sockets"; then
    printf 'loopback\n'
  else
    printf 'non_loopback\n'
  fi
}

source_admin_key="$(read_env "$source_env" DEVSHARD_ADMIN_API_KEY)"
source_port="$(read_env "$source_env" DEVSHARD_PORT)"
source_route="$(read_env "$source_env" DEVSHARD_ROUTE_PREFIX)"
source_rpc="$(read_env "$source_env" DEVSHARD_CHAIN_RPC)"
source_grpc="$(read_env "$source_env" DEVSHARD_CHAIN_GRPC)"
source_chain_id="$(read_env "$source_env" DEVSHARD_CHAIN_ID)"
source_model="$(read_env "$source_env" DEVSHARD_MODEL)"
source_volume="$(read_env "$source_env" DEVSHARD_GATEWAY_DATA_VOLUME)"
source_binary_url="$(read_env "$source_env" DEVSHARD_BINARY_URL)"
source_binary_sha256="$(read_env "$source_env" DEVSHARD_BINARY_SHA256)"
[[ -n "$source_admin_key" && "$source_port" =~ ^[1-9][0-9]{0,4}$ && "$source_port" -le 65535 \
  && "$source_chain_id" == "$expected_chain_id" && "$source_model" == "$expected_model" ]] || {
  echo 'source gateway environment is incomplete' >&2
  exit 1
}
validate_rpc_url "$source_rpc" || {
  echo 'source gateway RPC URL is invalid or contains credentials' >&2
  exit 1
}

source_before_raw="$(curl -fsS --connect-timeout 3 --max-time 15 \
  "http://127.0.0.1:${source_port}/v1/admin/devshards" \
  -H "Authorization: Bearer $source_admin_key")"
source_state_before="$(sanitize_state <<<"$source_before_raw")"
source_settings_raw="$(curl -fsS --connect-timeout 3 --max-time 15 \
  "http://127.0.0.1:${source_port}/v1/admin/settings" \
  -H "Authorization: Bearer $source_admin_key")"
source_settings_before="$(sanitize_settings <<<"$source_settings_raw")"
stats_scope="$(stats_listener_scope)"

target_present=false
target_route=''
target_volume=''
target_rpc=''
target_grpc=''
target_binary_url=''
target_binary_sha256=''
target_model=''
target_chain_id=''
target_state='{"available":false,"host_count":null,"in_flight_requests":null,"devshards":[]}'
target_settings='{"rotation_enabled":true,"settlement_enabled":true}'
target_settings_before="$target_settings"
target_rpc_status='null'
smoke='{"attempted":false,"requested_model":"","http_status":0,"completion_id_present":false,"completion_present":false}'

if [[ -s "$target_env" ]]; then
  target_present=true
  target_admin_key="$(read_env "$target_env" DEVSHARD_ADMIN_API_KEY)"
  target_declared_port="$(read_env "$target_env" DEVSHARD_PORT)"
  target_route="$(read_env "$target_env" DEVSHARD_ROUTE_PREFIX)"
  target_volume="$(read_env "$target_env" DEVSHARD_GATEWAY_DATA_VOLUME)"
  target_rpc="$(read_env "$target_env" DEVSHARD_CHAIN_RPC)"
  target_grpc="$(read_env "$target_env" DEVSHARD_CHAIN_GRPC)"
  target_binary_url="$(read_env "$target_env" DEVSHARD_BINARY_URL)"
  target_binary_sha256="$(read_env "$target_env" DEVSHARD_BINARY_SHA256)"
  target_model="$(read_env "$target_env" DEVSHARD_MODEL)"
  target_chain_id="$(read_env "$target_env" DEVSHARD_CHAIN_ID)"
  target_client_key="$(read_env "$target_env" DEVSHARD_API_KEYS | cut -d, -f1)"
  [[ -n "$target_admin_key" && "$target_model" == "$expected_model" \
    && "$target_chain_id" == "$expected_chain_id" && -n "$target_client_key" \
    && "$target_declared_port" == "$target_port" ]] || {
    echo 'target gateway environment is incomplete' >&2
    exit 1
  }
  validate_rpc_url "$target_rpc" || {
    echo 'target gateway RPC URL is invalid or contains credentials' >&2
    exit 1
  }
  target_raw="$(curl -fsS --connect-timeout 3 --max-time 15 \
    "http://127.0.0.1:${target_port}/v1/admin/devshards" \
    -H "Authorization: Bearer $target_admin_key")"
  target_state="$(sanitize_state <<<"$target_raw")"
  target_settings_raw="$(curl -fsS --connect-timeout 3 --max-time 15 \
    "http://127.0.0.1:${target_port}/v1/admin/settings" \
    -H "Authorization: Bearer $target_admin_key")"
  target_settings_before="$(sanitize_settings <<<"$target_settings_raw")"
  if [[ "${GDC_GATEWAY_MIGRATION_SMOKE:-false}" == true ]]; then
    smoke_body="$(mktemp)"
    smoke_status="$(curl -sS --connect-timeout 5 --max-time 120 \
      -o "$smoke_body" -w '%{http_code}' -X POST \
      "http://127.0.0.1:${target_port}/v1/chat/completions" \
      -H "Authorization: Bearer $target_client_key" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"$target_model\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"migration smoke\"}]}" \
      || true)"
    smoke="$(jq -cn \
      --arg status "${smoke_status:-0}" \
      --arg model "$target_model" \
      --argjson id_present "$(jq -e '.id | type == "string" and length > 0' "$smoke_body" >/dev/null 2>&1 && printf true || printf false)" \
      --argjson completion_present "$(jq -e '.choices | type == "array" and length > 0' "$smoke_body" >/dev/null 2>&1 && printf true || printf false)" \
      '{attempted:true,requested_model:$model,http_status:($status | tonumber? // 0),completion_id_present:$id_present,completion_present:$completion_present}')"
    rm -f "$smoke_body"
  fi
  target_settings_raw="$(curl -fsS --connect-timeout 3 --max-time 15 \
    "http://127.0.0.1:${target_port}/v1/admin/settings" \
    -H "Authorization: Bearer $target_admin_key")"
  target_settings="$(sanitize_settings <<<"$target_settings_raw")"
  target_rpc_status="$(capture_rpc_status "$target_rpc")"
fi

source_after_raw="$(curl -fsS --connect-timeout 3 --max-time 15 \
  "http://127.0.0.1:${source_port}/v1/admin/devshards" \
  -H "Authorization: Bearer $source_admin_key")"
source_state="$(sanitize_state <<<"$source_after_raw")"
source_settings_raw="$(curl -fsS --connect-timeout 3 --max-time 15 \
  "http://127.0.0.1:${source_port}/v1/admin/settings" \
  -H "Authorization: Bearer $source_admin_key")"
source_settings="$(sanitize_settings <<<"$source_settings_raw")"
source_rpc_status="$(capture_rpc_status "$source_rpc")"
height="$(jq -er '.height | tonumber' <<<"$source_rpc_status")"
read -r epoch_length poc_duration poc_exchange_duration validation_delay validation_duration validators_delay < <(
  curl -fsS --connect-timeout 3 --max-time 15 \
    http://127.0.0.1:1317/productscience/inference/inference/params \
    | jq -r '.params.epoch_params | [.epoch_length,.poc_stage_duration,.poc_exchange_duration,.poc_validation_delay,.poc_validation_duration,.set_new_validators_delay] | map(tonumber) | @tsv'
)
position=$((height % epoch_length))
safe_start=$((poc_duration + poc_exchange_duration + validation_delay + validation_duration + validators_delay + 1))
guard_blocks="${GDC_GATEWAY_MIGRATION_GUARD_BLOCKS:-10}"
[[ "$guard_blocks" =~ ^[1-9][0-9]*$ && "$guard_blocks" -lt "$epoch_length" ]] || {
  echo 'GDC_GATEWAY_MIGRATION_GUARD_BLOCKS must be positive and smaller than the epoch' >&2
  exit 2
}
safe_end=$((epoch_length - guard_blocks))
phase=transition
(( position >= safe_start && position <= safe_end )) && phase=Inference

jq -n \
  --arg source_version "$source_version" --arg target_version "$target_version" \
  --arg source_route "$source_route" --arg source_volume "$source_volume" \
  --arg source_port "$source_port" --arg source_binary_url "$source_binary_url" \
  --arg source_rpc "$source_rpc" --arg source_grpc "$source_grpc" \
  --arg source_chain_id "$source_chain_id" --arg source_model "$source_model" \
  --arg source_binary_sha256 "$source_binary_sha256" --argjson source_state "$source_state" \
  --argjson source_state_before "$source_state_before" --argjson source_rpc_status "$source_rpc_status" \
  --argjson source_settings_before "$source_settings_before" --argjson source_settings "$source_settings" \
  --arg stats_listener_scope "$stats_scope" \
  --argjson target_present "$target_present" --arg target_route "$target_route" \
  --arg target_volume "$target_volume" --arg target_port "$target_port" \
  --arg target_rpc "$target_rpc" --arg target_grpc "$target_grpc" \
  --arg target_chain_id "$target_chain_id" --arg target_model "$target_model" \
  --arg target_binary_url "$target_binary_url" --arg target_binary_sha256 "$target_binary_sha256" \
  --argjson target_state "$target_state" --argjson target_settings_before "$target_settings_before" \
  --argjson target_settings "$target_settings" \
  --argjson target_rpc_status "$target_rpc_status" --argjson smoke "$smoke" \
  --arg height "$height" --arg phase "$phase" --arg position "$position" \
  --arg safe_start "$safe_start" --arg safe_end "$safe_end" '
  {
    schema_version: 1,
    source: {
      version: $source_version,
      route_prefix: $source_route,
      model: $source_model,
      data_volume: $source_volume,
      port: ($source_port | tonumber),
      chain_rpc: $source_rpc,
      chain_grpc: $source_grpc,
      chain_id: $source_chain_id,
      rpc_status: $source_rpc_status,
      binary_url: $source_binary_url,
      binary_sha256: $source_binary_sha256,
      state_before_probes: $source_state_before,
      state: $source_state,
      settings_before_probes: $source_settings_before,
      settings: $source_settings
    },
    target: {
      version: $target_version,
      present: $target_present,
      route_prefix: $target_route,
      model: $target_model,
      data_volume: $target_volume,
      port: ($target_port | tonumber),
      chain_rpc: $target_rpc,
      chain_grpc: $target_grpc,
      chain_id: $target_chain_id,
      rpc_status: $target_rpc_status,
      binary_url: $target_binary_url,
      binary_sha256: $target_binary_sha256,
      state: $target_state,
      settings_before_probes: $target_settings_before,
      settings: $target_settings,
      smoke: $smoke
    },
    stats_listener_scope: $stats_listener_scope,
    epoch: {
      height: ($height | tonumber),
      phase: $phase,
      position: ($position | tonumber),
      safe_start: ($safe_start | tonumber),
      safe_end: ($safe_end | tonumber)
    }
  }'
