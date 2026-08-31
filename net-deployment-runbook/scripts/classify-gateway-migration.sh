#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[[ $# -eq 9 ]] || {
  echo 'usage: classify-gateway-migration.sh ACTION SNAPSHOT EXPECTED_SOURCE_URL EXPECTED_SOURCE_SHA256 EXPECTED_TARGET_URL EXPECTED_TARGET_SHA256 EXPECTED_CHAIN_ID EXPECTED_MODEL OUTPUT_DIR' >&2
  exit 2
}

action="$1"
snapshot="$2"
expected_source_url="$3"
expected_source_sha256="$4"
expected_target_url="$5"
expected_target_sha256="$6"
expected_chain_id="$7"
expected_model="$8"
output_dir="$9"
[[ "$action" =~ ^(preflight|verify|drain)$ && -s "$snapshot" ]] || exit 2
[[ "$expected_source_url" =~ ^https:// && "$expected_source_sha256" =~ ^[0-9a-f]{64}$ ]] || exit 2
[[ "$expected_target_url" =~ ^https:// && "$expected_target_sha256" =~ ^[0-9a-f]{64}$ ]] || exit 2
[[ "$expected_chain_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && -n "$expected_model" ]] || exit 2
mkdir -p "$output_dir"

reason=''
verdict=PASS
exit_code=0

source_version="$(jq -er .source.version "$snapshot")" || exit 2
target_version="$(jq -er .target.version "$snapshot")" || exit 2

if jq -e '.target.port == .source.port' "$snapshot" >/dev/null; then
  verdict=FAIL
  exit_code=1
  reason='target gateway must use a port distinct from the source gateway'
elif ! jq -e --arg source "$source_version" --arg url "$expected_source_url" --arg sha "$expected_source_sha256" \
  --arg chain "$expected_chain_id" --arg model "$expected_model" '
  .schema_version == 1
  and (.source.version | test("^v[345]$"))
  and (.target.version | test("^v[345]$"))
  and .source.version != .target.version
  and .source.route_prefix == ("/devshard/" + .source.version)
  and .source.model == $model
  and (.source.data_volume | type == "string" and length > 0)
  and (.source.port | type == "number")
  and .source.chain_id == $chain
  and .source.rpc_status.network == $chain
  and .source.rpc_status.catching_up == false
  and (.source.rpc_status.height | type == "number" and . > 0)
  and .source.rpc_status.fresh == true
  and .source.binary_url == $url
  and .source.binary_sha256 == $sha
  and (.source.state.available == true)
  and (.source.state.host_count | type == "number" and . > 0)
  and any(.source.state.devshards[]?;
    .model == $model
    and
    .active == true
    and .session_version == $source
    and .route_prefix == ("/devshard/" + $source)
    and .phase == "active"
    and .requests_blocked == false)
' "$snapshot" >/dev/null; then
  verdict=FAIL
  exit_code=1
  reason='source gateway does not satisfy the declared route and active-session contract'
elif [[ "$(jq -r .epoch.phase "$snapshot")" != Inference ]]; then
  verdict=BLOCKED
  exit_code=3
  reason='migration window is outside the safe Inference interval'
elif [[ "$(jq -r .target.present "$snapshot")" == true ]]; then
  if ! jq -e --arg url "$expected_target_url" --arg sha "$expected_target_sha256" \
    --arg chain "$expected_chain_id" --arg model "$expected_model" '
    .target.data_volume != .source.data_volume
    and .target.route_prefix == ("/devshard/" + .target.version)
    and .target.model == $model
    and .target.chain_id == $chain
    and (
      ((.target.chain_rpc | test("^https://[^@?#]+/$")) and .target.chain_grpc == "none")
      or
      ((.target.chain_rpc | test("^http://(127\\.0\\.0\\.1|localhost|[A-Za-z0-9.-]+):[0-9]+/?$"))
        and (.target.chain_grpc | test("^(127\\.0\\.0\\.1|localhost|[A-Za-z0-9.-]+):[0-9]+$")))
    )
    and .target.rpc_status.network == $chain
    and .target.rpc_status.catching_up == false
    and (.target.rpc_status.height | type == "number" and . > 0)
    and .target.rpc_status.fresh == true
    and ((.source.rpc_status.height - .target.rpc_status.height) | fabs) <= 5
    and .target.binary_url == $url
    and .target.binary_sha256 == $sha
  ' "$snapshot" >/dev/null; then
    verdict=FAIL
    exit_code=1
    reason='target gateway configuration violates the side-by-side migration contract'
  fi
elif [[ "$action" != preflight ]]; then
  verdict=BLOCKED
  exit_code=3
  reason='target gateway has not been staged'
fi

if [[ "$verdict" == PASS && "$(jq -r .stats_listener_scope "$snapshot")" == non_loopback ]]; then
  verdict=FAIL
  exit_code=1
  reason='unauthenticated DevShard statistics listener is reachable beyond loopback'
elif [[ "$verdict" == PASS && "$(jq -r .stats_listener_scope "$snapshot")" == unknown ]]; then
  verdict=BLOCKED
  exit_code=3
  reason='DevShard statistics listener exposure could not be determined'
fi

if [[ "$verdict" == PASS && "$action" =~ ^(verify|drain)$ ]]; then
  if ! jq -e '
    .source.settings_before_probes.rotation_enabled == false
    and .source.settings_before_probes.settlement_enabled == false
    and .source.settings.rotation_enabled == false
    and .source.settings.settlement_enabled == false
    and .target.settings_before_probes.rotation_enabled == false
    and .target.settings_before_probes.settlement_enabled == false
    and .target.settings.rotation_enabled == false
    and .target.settings.settlement_enabled == false
  ' "$snapshot" >/dev/null; then
    verdict=FAIL
    exit_code=1
    reason='source and target escrow rotation and automatic settlement are not both frozen'
  fi
fi

if [[ "$verdict" == PASS && "$action" =~ ^(verify|drain)$ ]]; then
  if ! jq -e --arg target "$target_version" --arg model "$expected_model" '
    .target.state.available == true
    and (.target.state.host_count | tonumber) > 0
    and any(.target.state.devshards[]?;
      .model == $model
      and
      .active == true
      and .session_version == $target
      and .route_prefix == ("/devshard/" + $target)
      and .phase == "active"
      and .chain_phase == "Inference"
      and .requests_blocked == false)
    and .target.smoke.attempted == true
    and .target.smoke.requested_model == $model
    and .target.smoke.http_status == 200
    and .target.smoke.completion_id_present == true
    and .target.smoke.completion_present == true
  ' "$snapshot" >/dev/null; then
    verdict=FAIL
    exit_code=1
    reason='target gateway did not prove route, session, capacity, and direct authenticated inference'
  fi
fi

if [[ "$verdict" == PASS && "$action" == drain ]]; then
  if ! jq -e '
    (.source.state_before_probes.in_flight_requests | type == "number")
    and (.source.state.in_flight_requests | type == "number")
    and .source.state_before_probes.in_flight_requests == 0
    and .source.state.in_flight_requests == 0
    and all(.source.state_before_probes.devshards[]?;
      (.active_requests | type == "number") and .active_requests == 0)
    and all(.source.state.devshards[]?;
      (.active_requests | type == "number") and .active_requests == 0)
  ' "$snapshot" >/dev/null; then
    verdict=BLOCKED
    exit_code=3
    reason='source gateway still has in-flight requests'
  fi
fi

jq --arg action "$action" --arg verdict "$verdict" --arg reason "$reason" \
  --arg expected_source_url "$expected_source_url" --arg expected_source_sha256 "$expected_source_sha256" \
  --arg expected_target_url "$expected_target_url" --arg expected_target_sha256 "$expected_target_sha256" \
  --arg expected_chain_id "$expected_chain_id" --arg expected_model "$expected_model" '
  {
    schema_version: 1,
    action: $action,
    verdict: $verdict,
    reason: $reason,
    source: (.source | .chain_rpc = (if (.chain_rpc | test("[@?#]")) then "redacted_invalid_url" else .chain_rpc end)),
    target: (.target | .chain_rpc = (if (.chain_rpc | test("[@?#]")) then "redacted_invalid_url" else .chain_rpc end)),
    epoch: .epoch,
    expected_chain_id: $expected_chain_id,
    expected_model: $expected_model,
    expected_source: {
      binary_url: $expected_source_url,
      binary_sha256: $expected_source_sha256
    },
    expected_target: {
      binary_url: $expected_target_url,
      binary_sha256: $expected_target_sha256
    }
  }' "$snapshot" >"$output_dir/receipt.json"

cat >"$output_dir/verdict.md" <<EOF
# DevShard gateway migration $action: $verdict

${reason:-The observed source, target and migration window satisfy this phase contract.}
EOF
chmod 0600 "$output_dir/receipt.json" "$output_dir/verdict.md"

printf '%s gateway migration %s evidence: %s\n' "$verdict" "$action" "$output_dir"
exit "$exit_code"
