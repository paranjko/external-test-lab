#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
url='https://example.invalid/devshardd.zip'
sha='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
source_url='https://example.invalid/devshardd-v4.zip'
source_sha='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

mkdir -p "$work/ops" "$work/bin"
cat >"$work/ops/gateway.env" <<EOF
DEVSHARD_ADMIN_API_KEY=source-admin-secret
DEVSHARD_PORT=18080
DEVSHARD_ROUTE_PREFIX=/devshard/v4
DEVSHARD_CHAIN_RPC=http://127.0.0.1:26657
DEVSHARD_CHAIN_GRPC=127.0.0.1:9090
DEVSHARD_CHAIN_ID=gonka-devnet-community
DEVSHARD_MODEL=Qwen/Qwen3-0.6B
DEVSHARD_GATEWAY_DATA_VOLUME=gateway-data-v4
DEVSHARD_BINARY_URL=$source_url
DEVSHARD_BINARY_SHA256=$source_sha
EOF
cat >"$work/ops/gateway-migration-target.env" <<EOF
DEVSHARD_ADMIN_API_KEY=target-admin-secret
DEVSHARD_API_KEYS=target-client-secret
DEVSHARD_PORT=18085
DEVSHARD_ROUTE_PREFIX=/devshard/v5
DEVSHARD_GATEWAY_DATA_VOLUME=gateway-data-v5
DEVSHARD_CHAIN_RPC=http://127.0.0.1:26657
DEVSHARD_CHAIN_GRPC=127.0.0.1:9090
DEVSHARD_CHAIN_ID=gonka-devnet-community
DEVSHARD_BINARY_URL=$url
DEVSHARD_BINARY_SHA256=$sha
DEVSHARD_MODEL=Qwen/Qwen3-0.6B
EOF
cat >"$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
args="$*"
[[ -z "${GDC_TEST_CURL_LOG:-}" ]] || printf '%s\n' "$args" >>"$GDC_TEST_CURL_LOG"
case "$args" in
  *':26657/status'*)
    printf '{"result":{"node_info":{"network":"gonka-devnet-community"},"sync_info":{"latest_block_height":"35","catching_up":false,"latest_block_time":"%s"}}}\n' "$(date -u +%FT%TZ)"
    ;;
  *':1317/productscience/inference/inference/params'*)
    printf '%s\n' '{"params":{"epoch_params":{"epoch_length":"70","poc_stage_duration":"10","poc_exchange_duration":"2","poc_validation_delay":"2","poc_validation_duration":"2","set_new_validators_delay":"2"}}}'
    ;;
  *'/v1/admin/settings'*)
    printf '%s\n' '{"escrow_rotation":{"enabled":false,"settlement_enabled":false}}'
    ;;
  *':18080/v1/admin/devshards'*)
    printf '%s\n' '{"capacity":{"host_count":4},"limiter":{"in_flight_requests":0},"devshards":[{"model":"Qwen/Qwen3-0.6B","route_prefix":"/devshard/v4","active":true,"runtime":{"session_version":"v4","phase":"active","chain_phase":"Inference","requests_blocked":false,"active_requests":0}}]}'
    ;;
  *':18085/v1/admin/devshards'*)
    printf '%s\n' '{"capacity":{"host_count":4},"limiter":{"in_flight_requests":0},"devshards":[{"model":"Qwen/Qwen3-0.6B","route_prefix":"/devshard/v5","active":true,"runtime":{"session_version":"v5","phase":"active","chain_phase":"Inference","requests_blocked":false,"active_requests":0}}]}'
    ;;
  *':18085/v1/chat/completions'*)
    output=''
    while (( $# > 0 )); do
      if [[ "$1" == -o ]]; then output="$2"; shift 2; else shift; fi
    done
    [[ -n "$output" ]]
    printf '%s\n' '{"id":"completion-1","choices":[{"message":{"content":"ok"}}]}' >"$output"
    printf '200'
    ;;
  *) exit 22 ;;
esac
EOF
cat >"$work/bin/ss" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$work/bin/curl" "$work/bin/ss"
PATH="$work/bin:$PATH" GDC_OPS_DIR="$work/ops" \
  "$ROOT/04-ops/capture-gateway-migration-state.sh" \
  v4 v5 18085 gonka-devnet-community Qwen/Qwen3-0.6B >"$work/captured.json"
jq -e '
  .schema_version == 1
  and .source.version == "v4"
  and .target.version == "v5"
  and .target.present == true
  and .source.model == "Qwen/Qwen3-0.6B"
  and .target.model == "Qwen/Qwen3-0.6B"
  and .source.rpc_status.network == "gonka-devnet-community"
  and .target.rpc_status.network == "gonka-devnet-community"
  and .source.rpc_status.fresh == true
  and .target.rpc_status.fresh == true
  and .epoch.phase == "Inference"
  and .stats_listener_scope == "absent"
' "$work/captured.json" >/dev/null
for secret in source-admin-secret target-admin-secret target-client-secret; do
  if grep -Fq "$secret" "$work/captured.json"; then
    exit 1
  fi
done

PATH="$work/bin:$PATH" GDC_OPS_DIR="$work/ops" GDC_GATEWAY_MIGRATION_SMOKE=true \
  GDC_TEST_CURL_LOG="$work/curl-order.log" \
  "$ROOT/04-ops/capture-gateway-migration-state.sh" \
  v4 v5 18085 gonka-devnet-community Qwen/Qwen3-0.6B >"$work/captured-smoke.json"
jq -e '
  .target.smoke.attempted == true
  and .target.smoke.requested_model == "Qwen/Qwen3-0.6B"
  and .target.smoke.http_status == 200
  and .target.smoke.completion_id_present == true
  and .target.smoke.completion_present == true
' "$work/captured-smoke.json" >/dev/null
[[ "$(grep -c ':18080/v1/admin/devshards' "$work/curl-order.log")" == 2 ]]
first_source_line="$(grep -n ':18080/v1/admin/devshards' "$work/curl-order.log" | head -n1 | cut -d: -f1)"
smoke_line="$(grep -n ':18085/v1/chat/completions' "$work/curl-order.log" | cut -d: -f1)"
last_source_line="$(grep -n ':18080/v1/admin/devshards' "$work/curl-order.log" | tail -n1 | cut -d: -f1)"
(( first_source_line < smoke_line && smoke_line < last_source_line ))

sed -i 's/^DEVSHARD_PORT=18085$/DEVSHARD_PORT=18086/' "$work/ops/gateway-migration-target.env"
set +e
PATH="$work/bin:$PATH" GDC_OPS_DIR="$work/ops" \
  "$ROOT/04-ops/capture-gateway-migration-state.sh" \
  v4 v5 18085 gonka-devnet-community Qwen/Qwen3-0.6B >"$work/port-mismatch.json" 2>/dev/null
rc=$?
set -e
[[ "$rc" == 1 ]]
sed -i 's/^DEVSHARD_PORT=18086$/DEVSHARD_PORT=18085/' "$work/ops/gateway-migration-target.env"

sed -i 's|^DEVSHARD_CHAIN_RPC=.*|DEVSHARD_CHAIN_RPC=https://user:credential@node.example/chain-rpc/|' \
  "$work/ops/gateway-migration-target.env"
set +e
PATH="$work/bin:$PATH" GDC_OPS_DIR="$work/ops" \
  "$ROOT/04-ops/capture-gateway-migration-state.sh" \
  v4 v5 18085 gonka-devnet-community Qwen/Qwen3-0.6B \
  >"$work/credential-rpc.json" 2>"$work/credential-rpc.err"
rc=$?
set -e
[[ "$rc" == 1 ]]
if grep -Fq 'user:credential' "$work/credential-rpc.json" "$work/credential-rpc.err"; then
  exit 1
fi
sed -i 's|^DEVSHARD_CHAIN_RPC=.*|DEVSHARD_CHAIN_RPC=http://127.0.0.1:26657|' \
  "$work/ops/gateway-migration-target.env"

write_snapshot() {
  local target_present="$1" in_flight="$2" smoke_status="$3"
  cat >"$work/snapshot.json" <<EOF
{
  "schema_version": 1,
  "source": {
    "version": "v4",
    "route_prefix": "/devshard/v4",
    "model": "Qwen/Qwen3-0.6B",
    "data_volume": "gateway-data-v4",
    "port": 18080,
    "chain_rpc": "http://127.0.0.1:26657",
    "chain_grpc": "127.0.0.1:9090",
    "chain_id": "gonka-devnet-community",
    "rpc_status": {"network":"gonka-devnet-community","height":100,"catching_up":false,"latest_block_time":"2026-09-01T00:00:00Z","fresh":true},
    "binary_url": "$source_url",
    "binary_sha256": "$source_sha",
    "state_before_probes": {
      "available": true,
      "host_count": 4,
      "in_flight_requests": $in_flight,
      "devshards": [{"model":"Qwen/Qwen3-0.6B","route_prefix":"/devshard/v4","active":true,"session_version":"v4","phase":"active","chain_phase":"Inference","requests_blocked":false,"active_requests":$in_flight}]
    },
    "state": {
      "available": true,
      "host_count": 4,
      "in_flight_requests": $in_flight,
      "devshards": [{"model":"Qwen/Qwen3-0.6B","route_prefix":"/devshard/v4","active":true,"session_version":"v4","phase":"active","chain_phase":"Inference","requests_blocked":false,"active_requests":$in_flight}]
    },
    "settings_before_probes": {"rotation_enabled":false,"settlement_enabled":false},
    "settings": {"rotation_enabled":false,"settlement_enabled":false}
  },
  "target": {
    "version": "v5",
    "present": $target_present,
    "route_prefix": "/devshard/v5",
    "model": "Qwen/Qwen3-0.6B",
    "data_volume": "gateway-data-v5",
    "port": 18085,
    "chain_rpc": "http://127.0.0.1:26657",
    "chain_grpc": "127.0.0.1:9090",
    "chain_id": "gonka-devnet-community",
    "rpc_status": {"network":"gonka-devnet-community","height":100,"catching_up":false,"latest_block_time":"2026-09-01T00:00:00Z","fresh":true},
    "binary_url": "$url",
    "binary_sha256": "$sha",
    "state": {
      "available": $target_present,
      "host_count": 4,
      "in_flight_requests": 0,
      "devshards": [{"model":"Qwen/Qwen3-0.6B","route_prefix":"/devshard/v5","active":true,"session_version":"v5","phase":"active","chain_phase":"Inference","requests_blocked":false,"active_requests":0}]
    },
    "settings_before_probes": {"rotation_enabled":false,"settlement_enabled":false},
    "settings": {"rotation_enabled":false,"settlement_enabled":false},
    "smoke": {"attempted":true,"requested_model":"Qwen/Qwen3-0.6B","http_status":$smoke_status,"completion_id_present":true,"completion_present":true}
  },
  "stats_listener_scope": "absent",
  "epoch": {"height":100,"phase":"Inference","position":30,"safe_start":20,"safe_end":60}
}
EOF
}

write_snapshot false 0 0
"$ROOT/scripts/classify-gateway-migration.sh" preflight "$work/snapshot.json" "$source_url" "$source_sha" "$url" "$sha" gonka-devnet-community Qwen/Qwen3-0.6B "$work/preflight"
grep -qx '# DevShard gateway migration preflight: PASS' "$work/preflight/verdict.md"

write_snapshot true 1 200
"$ROOT/scripts/classify-gateway-migration.sh" verify "$work/snapshot.json" "$source_url" "$source_sha" "$url" "$sha" gonka-devnet-community Qwen/Qwen3-0.6B "$work/verify"
grep -qx '# DevShard gateway migration verify: PASS' "$work/verify/verdict.md"

jq '.target.chain_rpc = "https://node.example/chain-rpc/" | .target.chain_grpc = "none"' \
  "$work/snapshot.json" >"$work/public-rpc.json"
"$ROOT/scripts/classify-gateway-migration.sh" verify "$work/public-rpc.json" "$source_url" "$source_sha" "$url" "$sha" gonka-devnet-community Qwen/Qwen3-0.6B "$work/public-rpc"
grep -qx '# DevShard gateway migration verify: PASS' "$work/public-rpc/verdict.md"

jq '.target.chain_rpc = "https://node.example/chain-rpc" | .target.chain_grpc = "none"' \
  "$work/snapshot.json" >"$work/public-rpc-redirect.json"
set +e
"$ROOT/scripts/classify-gateway-migration.sh" verify "$work/public-rpc-redirect.json" "$source_url" "$source_sha" "$url" "$sha" gonka-devnet-community Qwen/Qwen3-0.6B "$work/public-rpc-redirect"
rc=$?
set -e
[[ "$rc" == 1 ]]
grep -qx '# DevShard gateway migration verify: FAIL' "$work/public-rpc-redirect/verdict.md"

jq '.source.settings.rotation_enabled = true' "$work/snapshot.json" >"$work/rotation-enabled.json"
set +e
"$ROOT/scripts/classify-gateway-migration.sh" verify "$work/rotation-enabled.json" "$source_url" "$source_sha" "$url" "$sha" gonka-devnet-community Qwen/Qwen3-0.6B "$work/rotation-enabled"
rc=$?
set -e
[[ "$rc" == 1 ]]
grep -qx '# DevShard gateway migration verify: FAIL' "$work/rotation-enabled/verdict.md"

set +e
"$ROOT/scripts/classify-gateway-migration.sh" verify "$work/snapshot.json" "$source_url" "$sha" "$url" "$sha" gonka-devnet-community Qwen/Qwen3-0.6B "$work/source-mismatch"
rc=$?
set -e
[[ "$rc" == 1 ]]
grep -qx '# DevShard gateway migration verify: FAIL' "$work/source-mismatch/verdict.md"
set +e
"$ROOT/scripts/classify-gateway-migration.sh" drain "$work/snapshot.json" "$source_url" "$source_sha" "$url" "$sha" gonka-devnet-community Qwen/Qwen3-0.6B "$work/drain-blocked"
rc=$?
set -e
[[ "$rc" == 3 ]]
grep -qx '# DevShard gateway migration drain: BLOCKED' "$work/drain-blocked/verdict.md"

write_snapshot true 0 200
"$ROOT/scripts/classify-gateway-migration.sh" drain "$work/snapshot.json" "$source_url" "$source_sha" "$url" "$sha" gonka-devnet-community Qwen/Qwen3-0.6B "$work/drain-pass"
grep -qx '# DevShard gateway migration drain: PASS' "$work/drain-pass/verdict.md"
[[ "$(stat -c %a "$work/drain-pass/receipt.json")" == 600 ]]
[[ "$(stat -c %a "$work/drain-pass/verdict.md")" == 600 ]]

jq '.source.state.in_flight_requests = null | .source.state.devshards[0].active_requests = null' \
  "$work/snapshot.json" >"$work/missing-counters.json"
set +e
"$ROOT/scripts/classify-gateway-migration.sh" drain "$work/missing-counters.json" "$source_url" "$source_sha" "$url" "$sha" gonka-devnet-community Qwen/Qwen3-0.6B "$work/missing-counters"
rc=$?
set -e
[[ "$rc" == 3 ]]
grep -qx '# DevShard gateway migration drain: BLOCKED' "$work/missing-counters/verdict.md"

jq '.source.state.in_flight_requests = 1 | .source.state.devshards[0].active_requests = 1' \
  "$work/snapshot.json" >"$work/late-source-request.json"
set +e
"$ROOT/scripts/classify-gateway-migration.sh" drain "$work/late-source-request.json" "$source_url" "$source_sha" "$url" "$sha" gonka-devnet-community Qwen/Qwen3-0.6B "$work/late-source-request"
rc=$?
set -e
[[ "$rc" == 3 ]]
grep -qx '# DevShard gateway migration drain: BLOCKED' "$work/late-source-request/verdict.md"

write_snapshot false 0 0
jq '.target.port = .source.port' "$work/snapshot.json" >"$work/unstaged-port-conflict.json"
set +e
"$ROOT/scripts/classify-gateway-migration.sh" preflight "$work/unstaged-port-conflict.json" "$source_url" "$source_sha" "$url" "$sha" gonka-devnet-community Qwen/Qwen3-0.6B "$work/unstaged-port-conflict"
rc=$?
set -e
[[ "$rc" == 1 ]]
grep -qx '# DevShard gateway migration preflight: FAIL' "$work/unstaged-port-conflict/verdict.md"

write_snapshot true 0 200
jq '.target.chain_rpc = "https://user:do-not-persist@node.example/chain-rpc/"' \
  "$work/snapshot.json" >"$work/credential-snapshot.json"
set +e
"$ROOT/scripts/classify-gateway-migration.sh" verify "$work/credential-snapshot.json" "$source_url" "$source_sha" "$url" "$sha" gonka-devnet-community Qwen/Qwen3-0.6B "$work/credential-snapshot"
rc=$?
set -e
[[ "$rc" == 1 ]]
if grep -Fq do-not-persist "$work/credential-snapshot/receipt.json" "$work/credential-snapshot/verdict.md"; then
  exit 1
fi
grep -Fq redacted_invalid_url "$work/credential-snapshot/receipt.json"

jq '.target.rpc_status.network = "other-chain"' "$work/snapshot.json" >"$work/wrong-chain.json"
set +e
"$ROOT/scripts/classify-gateway-migration.sh" verify "$work/wrong-chain.json" "$source_url" "$source_sha" "$url" "$sha" gonka-devnet-community Qwen/Qwen3-0.6B "$work/wrong-chain"
rc=$?
set -e
[[ "$rc" == 1 ]]

jq '.target.rpc_status.fresh = false' "$work/snapshot.json" >"$work/stale-chain.json"
set +e
"$ROOT/scripts/classify-gateway-migration.sh" verify "$work/stale-chain.json" "$source_url" "$source_sha" "$url" "$sha" gonka-devnet-community Qwen/Qwen3-0.6B "$work/stale-chain"
rc=$?
set -e
[[ "$rc" == 1 ]]

jq '.target.rpc_status.height = 90' "$work/snapshot.json" >"$work/lagging-chain.json"
set +e
"$ROOT/scripts/classify-gateway-migration.sh" verify "$work/lagging-chain.json" "$source_url" "$source_sha" "$url" "$sha" gonka-devnet-community Qwen/Qwen3-0.6B "$work/lagging-chain"
rc=$?
set -e
[[ "$rc" == 1 ]]

jq '.target.model = "other/model"' "$work/snapshot.json" >"$work/wrong-model.json"
set +e
"$ROOT/scripts/classify-gateway-migration.sh" verify "$work/wrong-model.json" "$source_url" "$source_sha" "$url" "$sha" gonka-devnet-community Qwen/Qwen3-0.6B "$work/wrong-model"
rc=$?
set -e
[[ "$rc" == 1 ]]

jq '.target.data_volume = "gateway-data-v4"' "$work/snapshot.json" >"$work/shared-volume.json"
set +e
"$ROOT/scripts/classify-gateway-migration.sh" verify "$work/shared-volume.json" "$source_url" "$source_sha" "$url" "$sha" gonka-devnet-community Qwen/Qwen3-0.6B "$work/shared-volume"
rc=$?
set -e
[[ "$rc" == 1 ]]
grep -qx '# DevShard gateway migration verify: FAIL' "$work/shared-volume/verdict.md"

jq '.target.smoke.http_status = 502' "$work/snapshot.json" >"$work/smoke-fail.json"
set +e
"$ROOT/scripts/classify-gateway-migration.sh" verify "$work/smoke-fail.json" "$source_url" "$source_sha" "$url" "$sha" gonka-devnet-community Qwen/Qwen3-0.6B "$work/smoke-fail"
rc=$?
set -e
[[ "$rc" == 1 ]]
grep -qx '# DevShard gateway migration verify: FAIL' "$work/smoke-fail/verdict.md"

jq '.epoch.phase = "PoCGenerate"' "$work/snapshot.json" >"$work/unsafe-window.json"
set +e
"$ROOT/scripts/classify-gateway-migration.sh" preflight "$work/unsafe-window.json" "$source_url" "$source_sha" "$url" "$sha" gonka-devnet-community Qwen/Qwen3-0.6B "$work/unsafe-window"
rc=$?
set -e
[[ "$rc" == 3 ]]
grep -qx '# DevShard gateway migration preflight: BLOCKED' "$work/unsafe-window/verdict.md"

jq '.stats_listener_scope = "non_loopback"' "$work/snapshot.json" >"$work/public-stats.json"
set +e
"$ROOT/scripts/classify-gateway-migration.sh" verify "$work/public-stats.json" "$source_url" "$source_sha" "$url" "$sha" gonka-devnet-community Qwen/Qwen3-0.6B "$work/public-stats"
rc=$?
set -e
[[ "$rc" == 1 ]]
grep -qx '# DevShard gateway migration verify: FAIL' "$work/public-stats/verdict.md"

jq '.stats_listener_scope = "unknown"' "$work/snapshot.json" >"$work/unknown-stats.json"
set +e
"$ROOT/scripts/classify-gateway-migration.sh" verify "$work/unknown-stats.json" "$source_url" "$source_sha" "$url" "$sha" gonka-devnet-community Qwen/Qwen3-0.6B "$work/unknown-stats"
rc=$?
set -e
[[ "$rc" == 3 ]]
grep -qx '# DevShard gateway migration verify: BLOCKED' "$work/unknown-stats/verdict.md"

grep -Fq 'gateway migrate preflight|verify|drain' "$ROOT/gdc.sh"
grep -Fq 'phase-gateway-migration.sh' "$ROOT/gdc.sh"
printf 'PASS side-by-side gateway migration observation contract\n'
