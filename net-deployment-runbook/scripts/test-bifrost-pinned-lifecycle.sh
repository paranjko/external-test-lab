#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python_test="$ROOT/.python-test-venv/bin/python"
[[ -x "$python_test" ]] || { echo 'Python test environment is required; run make install-python-test-dependencies' >&2; exit 2; }
image='maximhq/bifrost@sha256:5f8215163cea192451f4b2ee5e0b583874ffe9435a5ab733e08c07aaf38ace57'
grep -Fqx "    image: $image" "$ROOT/04-ops/compose.yaml"
name="gdc-bifrost-pinned-test-$$"
tmp="$(mktemp -d)"
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
upstream_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
broker_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
edge_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
compose=(docker compose --project-name "$name" --env-file "$tmp/compose.env" -f "$tmp/compose.fixture.yaml" -f "$tmp/compose.override.yaml")
upstream_pid=''; broker_pid=''; edge_pid=''; admission_pid=''
cleanup() { [[ -z "$admission_pid" ]] || kill "$admission_pid" >/dev/null 2>&1 || true; [[ -z "$edge_pid" ]] || kill "$edge_pid" >/dev/null 2>&1 || true; [[ -z "$broker_pid" ]] || kill "$broker_pid" >/dev/null 2>&1 || true; [[ -z "$upstream_pid" ]] || kill "$upstream_pid" >/dev/null 2>&1 || true; "${compose[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT

printf 'BIFROST_DATA_VOLUME_NAME=%s\nINFERENCED_IMAGE=fixture/unused:latest\nSITE_HOST=fixture.invalid\nAPI_HOST=fixture.invalid\nGRAFANA_HOST=fixture.invalid\nGATEWAY_PUBLIC_HOST=fixture.invalid\nPUBLIC_EDGE_CIDR=127.0.0.1/32\n' "$name" >"$tmp/compose.env"
printf 'APP_HOST=127.0.0.1\nAPP_PORT=%s\nBIFROST_SETUP_TOKEN=temporary-setup-token\n' "$port" >"$tmp/bifrost.env"
printf 'services:\n  bifrost:\n    env_file:\n      - %s\n' "$tmp/bifrost.env" >"$tmp/compose.override.yaml"
# Select the shipped YAML before Compose reads any unrelated service env_file
# Older Compose versions check file existence even with --no-env-resolution
# Retain the whole service and volume blocks, refuse missing/duplicate blocks
awk '
  BEGIN { print "services:" }
  /^volumes:$/ { section="volumes"; capture=0; print; next }
  /^  [a-zA-Z0-9_-]+:$/ {
    capture=($0 == "  bifrost:" && section != "volumes") || ($0 == "  bifrost-data:" && section == "volumes")
    if (capture && section == "volumes") volumes++; else if (capture) services++
  }
  capture { print }
  END { if (services != 1 || volumes != 1) exit 1 }
' "$ROOT/04-ops/compose.yaml" >"$tmp/compose.fixture.yaml"
"${compose[@]}" config --no-env-resolution --format json \
  | jq '{name, services: {bifrost: .services.bifrost}, volumes: {"bifrost-data": .volumes["bifrost-data"]}}' \
  >"$tmp/compose.json"
compose=(docker compose --project-name "$name" -f "$tmp/compose.json")
GDC_TEST_POC_FENCE_FILE="$tmp/poc-fence" "$python_test" "$ROOT/scripts/bifrost-fake-inference.py" "$upstream_port" >/dev/null 2>&1 & upstream_pid=$!
"${compose[@]}" up -d bifrost >/dev/null
ready=false
for _ in $(seq 1 40); do
  if curl -fsS --connect-timeout 1 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then ready=true; break; fi
  sleep 1
done
[[ "$ready" == true ]] || { "${compose[@]}" logs bifrost >&2; exit 1; }

payload_base='{"client_config":{"log_retention_days":1},"auth_config":{"admin_username":{"value":"admin"},"admin_password":{"value":"Valid!Password1"},"is_enabled":true'
missing_code="$(curl -sS -o /dev/null -w '%{http_code}' -X PUT "http://127.0.0.1:$port/api/config" -H 'Content-Type: application/json' -d "${payload_base},\"setup_token\":\"\"}}")"
wrong_code="$(curl -sS -o /dev/null -w '%{http_code}' -X PUT "http://127.0.0.1:$port/api/config" -H 'Content-Type: application/json' -d "${payload_base},\"setup_token\":\"wrong-token\"}}")"
[[ "$missing_code" == 403 && "$wrong_code" == 403 ]] || { echo "expected setup-token rejection, got missing=$missing_code wrong=$wrong_code" >&2; exit 1; }

run_provision() {
  env BIFROST_MANAGEMENT_URL="http://127.0.0.1:$port" BIFROST_ADMIN_USERNAME=admin \
    BIFROST_ADMIN_PASSWORD='Valid!Password1' BIFROST_SETUP_TOKEN=temporary-setup-token \
    BIFROST_GONKA_PROVIDER=gonka-s BIFROST_GONKA_MODEL=test-model \
    BIFROST_GONKA_BASE_URL="http://127.0.0.1:$upstream_port" BIFROST_GONKA_PROVIDER_KEY=provider-secret \
    BIFROST_BROKER_BINDING_FILE="$tmp/broker-binding.env" \
    python3 "$ROOT/04-ops/bifrost-provision.py" "$@"
}

preview="$(run_provision --preview)"
expected="$(jq -r '.before_sha256' <<<"$preview")"
[[ "$(jq -r '.current.bootstrap' <<<"$preview")" == empty ]] || exit 1
apply="$(run_provision --apply --expected-sha256 "$expected")"
[[ "$(jq -r '.applied' <<<"$apply")" == true && "$(jq '.delta | length' <<<"$apply")" == 0 ]] || exit 1
[[ "$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/api/config")" == 401 ]]
[[ "$(curl -sS -u 'admin:Valid!Password1' -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/api/config")" == 200 ]]
# The actual release, rather than the edge fixture, must recognise a native
# virtual key on every stable adapter route. The absent disposable upstream
# makes a successful inference impossible here, but authentication must pass
# far enough that each route returns an upstream failure rather than 401/404.
provider_key_id="$(awk -F= '$1 == "BIFROST_GONKA_KEY_ID" { print $2 }' "$tmp/broker-binding.env")"
native="$(jq -cn --arg key_id "$provider_key_id" '{name:"pinned-protocol-test",is_active:true,provider_configs:[{provider:"gonka-s",allowed_models:["test-model"],key_ids:[$key_id]}]}' \
  | curl -fsS -u 'admin:Valid!Password1' -X POST "http://127.0.0.1:$port/api/governance/virtual-keys" -H 'Content-Type: application/json' --data-binary @- | jq -r '.virtual_key.value')"
[[ "$native" == sk-bf-* ]]
for route in /v1/chat/completions /anthropic/v1/messages /genai/v1beta/models/test-model:generateContent; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$port$route" -H "x-bf-vk: $native" -H 'Content-Type: application/json' -d '{"model":"test-model","messages":[{"role":"user","content":"probe"}]}')"
  [[ "$code" != 401 && "$code" != 404 ]] || { echo "pinned Bifrost rejected adapter route $route with $code" >&2; exit 1; }
done
cp "$ROOT/04-ops/bifrost-key-broker.py" "$tmp/bifrost_key_broker.py"
cp "$ROOT/04-ops/bifrost-broker-service.py" "$tmp/bifrost-broker-service.py"
env BIFROST_MANAGEMENT_URL="http://127.0.0.1:$port" BIFROST_ADMIN_USERNAME=admin BIFROST_ADMIN_PASSWORD='Valid!Password1' \
  BIFROST_BROKER_TOKEN=bbbbbbbbbbbbbbbbbbbbbbbb BIFROST_EDGE_TOKEN=eeeeeeeeeeeeeeeeeeeeeeee \
  BIFROST_BROKER_ENCRYPTION_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= BIFROST_BROKER_BINDING_FILE="$tmp/broker-binding.env" \
  BIFROST_BROKER_DB="$tmp/keys.sqlite3" BIFROST_BROKER_HOST=127.0.0.1 BIFROST_BROKER_PORT="$broker_port" \
  "$python_test" "$tmp/bifrost-broker-service.py" >/dev/null 2>&1 & broker_pid=$!
printf 'BIFROST_EDGE_HOST=127.0.0.1\nBIFROST_EDGE_PORT=%s\nBIFROST_EDGE_BROKER_URL=http://127.0.0.1:%s\nBIFROST_EDGE_UPSTREAM_URL=http://127.0.0.1:%s\nBIFROST_EDGE_TOKEN=eeeeeeeeeeeeeeeeeeeeeeee\n' "$edge_port" "$broker_port" "$port" >"$tmp/edge.env"
export BIFROST_EDGE_MAINTENANCE_ENV="$tmp/edge.env"
BIFROST_EDGE_MAINTENANCE_IMAGE="$(docker build -q -f "$ROOT/04-ops/Dockerfile.bifrost-edge" "$ROOT/04-ops")"
export BIFROST_EDGE_MAINTENANCE_IMAGE
edge_compose=(docker compose -p "$name" -f "$ROOT/04-ops/compose.bifrost-edge-maintenance.yaml")
adapter_id="$("${compose[@]}" ps -q bifrost)"
"${edge_compose[@]}" up -d --no-deps bifrost-edge
"${edge_compose[@]}" up -d --no-deps --force-recreate bifrost-edge
[[ "$("${compose[@]}" ps -q bifrost)" == "$adapter_id" ]]
edge_ready=false
for _ in $(seq 1 30); do
  if [[ "$(curl -s --connect-timeout 1 --max-time 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$edge_port/v1/models" || true)" == 401 ]]; then
    edge_ready=true
    break
  fi
  sleep 1
done
[[ "$edge_ready" == true ]] || { echo 'edge did not reach its authentication gate' >&2; exit 1; }
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$broker_port/v1/keys" -o /dev/null -X POST -H 'Authorization: Bearer bbbbbbbbbbbbbbbbbbbbbbbb' -H 'Content-Type: application/json' -d '{"telegram_id":99,"update_id":1}'; then break; fi
  sleep 1
done
stable="$(curl -fsS -X POST "http://127.0.0.1:$broker_port/v1/keys" -H 'Authorization: Bearer bbbbbbbbbbbbbbbbbbbbbbbb' -H 'Content-Type: application/json' -d '{"telegram_id":99,"update_id":1}' | jq -r .key)"
[[ "$stable" == sk-gdc-* ]]
edge_openai_body="$tmp/edge-openai.json"
edge_openai_code="$(curl -sS -D "$tmp/edge-openai.headers" -o "$edge_openai_body" -w '%{http_code}' "http://127.0.0.1:$edge_port/v1/chat/completions" -H "Authorization: Bearer $stable" -H 'Content-Type: application/json' -d '{"model":"test-model","messages":[{"role":"user","content":"probe"}]}')"
[[ "$edge_openai_code" == 200 ]] || { echo "pinned edge OpenAI request returned $edge_openai_code: $(<"$edge_openai_body")" >&2; exit 1; }
jq -e '.choices[0].message.content == "fixture-ok"' "$edge_openai_body" >/dev/null
# Stable readiness must correlate the actual native request and escrow, not
# Bifrost's own request identifier or an unrelated successful gateway probe.
tr -d '\r' <"$tmp/edge-openai.headers" >"$tmp/edge-openai-normalized.headers"
grep -Fixq 'X-Request-Id: fixture-native-request' "$tmp/edge-openai-normalized.headers"
grep -Fixq 'X-Devshard-ID: fixture-native-escrow' "$tmp/edge-openai-normalized.headers"
printf 'PASS pinned stable adapter preserves native request and escrow response identities\n'
"$python_test" - "$tmp" "$port" "$edge_port" "$provider_key_id" <<'PY'
import importlib.util
import json
from pathlib import Path
import sys
from urllib.request import Request, urlopen
root, port, edge, provider_key = sys.argv[1:]
spec = importlib.util.spec_from_file_location('broker', Path(root) / 'bifrost_key_broker.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
client = module.BifrostClient('http://127.0.0.1:' + port, 'admin', 'Valid!Password1',
                              'gonka-s', 'test-model', provider_key)
broker = module.Broker(str(Path(root) / 'keys.sqlite3'), client, b'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=')
key = broker.ensure_health_key()
assert broker.ensure_health_key() == key
request = Request('http://127.0.0.1:' + edge + '/v1/chat/completions',
    json.dumps({'model': 'test-model', 'messages': [{'role': 'user', 'content': 'probe'}]}).encode(),
    {'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
with urlopen(request, timeout=10) as response:
    assert response.status == 200
    assert json.load(response)['choices'][0]['message']['content'] == 'fixture-ok'
broker.db.close()
print('PASS pinned operator health key serves through the same stable edge without user rotation')
PY
edge_anthropic_body="$tmp/edge-anthropic.json"
edge_anthropic_code="$(curl -sS -o "$edge_anthropic_body" -w '%{http_code}' "http://127.0.0.1:$edge_port/anthropic/v1/messages" -H "x-api-key: $stable" -H 'anthropic-version: 2023-06-01' -H 'Content-Type: application/json' -d '{"model":"test-model","max_tokens":8,"messages":[{"role":"user","content":"probe"}]}')"
[[ "$edge_anthropic_code" == 200 ]] || { echo "pinned edge Anthropic request returned $edge_anthropic_code: $(<"$edge_anthropic_body")" >&2; exit 1; }
jq -e '.type == "message" and .role == "assistant" and (.usage | type == "object")' "$edge_anthropic_body" >/dev/null || { echo "unexpected Anthropic adapter body: $(<"$edge_anthropic_body")" >&2; exit 1; }
edge_genai_body="$tmp/edge-genai.json"
edge_genai_code="$(curl -sS -o "$edge_genai_body" -w '%{http_code}' "http://127.0.0.1:$edge_port/genai/v1beta/models/test-model:generateContent" -H "x-goog-api-key: $stable" -H 'Content-Type: application/json' -d '{"contents":[{"parts":[{"text":"probe"}]}]}')"
[[ "$edge_genai_code" == 200 ]] || { echo "pinned edge GenAI request returned $edge_genai_code: $(<"$edge_genai_body")" >&2; exit 1; }
jq -e '.candidates | type == "array"' "$edge_genai_body" >/dev/null || { echo "unexpected GenAI adapter body: $(<"$edge_genai_body")" >&2; exit 1; }
rotated="$(curl -fsS -X POST "http://127.0.0.1:$broker_port/v1/keys" -H 'Authorization: Bearer bbbbbbbbbbbbbbbbbbbbbbbb' -H 'Content-Type: application/json' -d '{"telegram_id":99,"update_id":2}' | jq -r .key)"
[[ "$rotated" == sk-gdc-* && "$rotated" != "$stable" ]]
old_edge_code="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$edge_port/v1/chat/completions" -H "Authorization: Bearer $stable" -H 'Content-Type: application/json' -d '{"model":"test-model","messages":[{"role":"user","content":"probe"}]}')"
[[ "$old_edge_code" == 401 ]] || { echo "rotated stable key was accepted with $old_edge_code" >&2; exit 1; }
rotated_edge_body="$tmp/edge-rotated-openai.json"
rotated_edge_code="$(curl -sS -o "$rotated_edge_body" -w '%{http_code}' "http://127.0.0.1:$edge_port/v1/chat/completions" -H "Authorization: Bearer $rotated" -H 'Content-Type: application/json' -d '{"model":"test-model","messages":[{"role":"user","content":"probe"}]}')"
[[ "$rotated_edge_code" == 200 ]] || { echo "rotated stable key returned $rotated_edge_code: $(<"$rotated_edge_body")" >&2; exit 1; }
jq -e '.choices[0].message.content == "fixture-ok"' "$rotated_edge_body" >/dev/null
if run_provision --apply --expected-sha256 "$expected" >/dev/null 2>&1; then echo 'stale preview was accepted' >&2; exit 1; fi
converged="$(run_provision --preview)"
[[ "$(jq '.delta | length' <<<"$converged")" == 0 ]]
[[ "$(jq -r '.outcome' <<<"$(run_provision --apply --expected-sha256 "$(jq -r .before_sha256 <<<"$converged")")")" == no-change ]]
"${compose[@]}" restart bifrost >/dev/null
ready=false
for _ in $(seq 1 40); do
  if curl -fsS --connect-timeout 1 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then ready=true; break; fi
  sleep 1
done
[[ "$ready" == true ]] || { "${compose[@]}" logs bifrost >&2; exit 1; }
[[ "$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/api/config")" == 401 ]]
[[ "$(curl -sS -u 'admin:Valid!Password1' -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/api/config")" == 200 ]]
[[ "$(jq '.delta | length' <<<"$(run_provision --preview)")" == 0 ]]
# An operator can change the existing provider transport and key in place:
# stable user keys remain bound to the same provider/key IDs after migration.
# The pinned release can report healthy while restart-time SQLite writers
# still hold the config-store lock. Retry only that explicit transient error
# for these idempotent fixture PUTs, not arbitrary 500s or funding operations.
put_fixture_config() {
  local route="$1" payload="$2" attempt code detail
  for attempt in $(seq 1 10); do
    code="$(curl -sS -o "$tmp/config-update.json" -w '%{http_code}' \
      -u 'admin:Valid!Password1' -X PUT "http://127.0.0.1:$port$route" \
      -H 'Content-Type: application/json' --data-binary "@$payload")"
    [[ "$code" != 200 ]] || return 0
    detail="$(jq -r '.error.message // .message // .error // "no structured error"' "$tmp/config-update.json")"
    if [[ "$code" != 500 || "$detail" != *'database is locked'* || "$attempt" == 10 ]]; then
      printf 'pinned config update failed HTTP %s: %s\n' "$code" "$detail" >&2
      return 1
    fi
    printf 'WAIT pinned config store lock attempt=%s/10\n' "$attempt"
    sleep 1
  done
}
provider_before="$(curl -fsS -u 'admin:Valid!Password1' "http://127.0.0.1:$port/api/providers" | jq '.providers[] | select(.name == "gonka-s")')"
# Existing providers must not silently re-enable retries behind the stable
# route. Exercise actual management readback and refusal, preserving key IDs.
retry_before="$(run_provision --preview)"
jq -c '{network_config:(.network_config + {max_retries:2}),concurrency_and_buffer_size,custom_provider_config,proxy_config}' <<<"$provider_before" >"$tmp/retry-drift.json"
put_fixture_config /api/providers/gonka-s "$tmp/retry-drift.json"
retry_drift="$(run_provision --preview)"
jq -e '.delta == ["provider.max_retries"] and .current.provider.max_retries == 2' <<<"$retry_drift" >/dev/null
[[ "$(jq -r .before_sha256 <<<"$retry_before")" != "$(jq -r .before_sha256 <<<"$retry_drift")" ]]
if run_provision --apply --expected-sha256 "$(jq -r .before_sha256 <<<"$retry_drift")" >"$tmp/retry-refused.log" 2>&1; then
  echo 'pinned provider with retries enabled was accepted' >&2
  exit 1
fi
grep -Fq 'explicitly disable retries' "$tmp/retry-refused.log"
curl -fsS -u 'admin:Valid!Password1' "http://127.0.0.1:$port/api/providers" \
  | jq -e '.providers[] | select(.name == "gonka-s") | .network_config.max_retries == 2' >/dev/null
jq -c '{network_config,concurrency_and_buffer_size,custom_provider_config,proxy_config}' <<<"$provider_before" >"$tmp/retry-restore.json"
put_fixture_config /api/providers/gonka-s "$tmp/retry-restore.json"
[[ "$(jq '.delta | length' <<<"$(run_provision --preview)")" == 0 ]]
printf 'PASS pinned provider retry drift changes the receipt and fails closed without mutation\n'
jq -c --arg base "http://127.0.0.1:$upstream_port/" '{network_config:(.network_config + {base_url:$base}),concurrency_and_buffer_size,custom_provider_config,proxy_config}' <<<"$provider_before" >"$tmp/provider-update.json"
put_fixture_config /api/providers/gonka-s "$tmp/provider-update.json"
curl -fsS -u 'admin:Valid!Password1' "http://127.0.0.1:$port/api/providers" \
  | jq -e --arg base "http://127.0.0.1:$upstream_port/" '.providers[] | select(.name == "gonka-s") | .network_config.base_url == $base' >/dev/null
curl -fsS -u 'admin:Valid!Password1' "http://127.0.0.1:$port/api/providers/gonka-s/keys" \
  | jq -c '.keys[0] | .value={value:"provider-secret"} | del(.status)' >"$tmp/key-update.json"
put_fixture_config "/api/providers/gonka-s/keys/$provider_key_id" "$tmp/key-update.json"
[[ "$(curl -fsS -u 'admin:Valid!Password1' "http://127.0.0.1:$port/api/providers/gonka-s/keys" | jq -r '.keys[0].id')" == "$provider_key_id" ]]
curl -fsS "http://127.0.0.1:$edge_port/v1/chat/completions" -H "Authorization: Bearer $rotated" -H 'Content-Type: application/json' \
  -d '{"model":"test-model","messages":[{"role":"user","content":"probe"}]}' | jq -e '.choices[0].message.content == "fixture-ok"' >/dev/null
printf 'PASS pinned provider transport/key update preserves existing stable client credentials\n'
env BIFROST_MANAGEMENT_URL="http://127.0.0.1:$port" BIFROST_ADMIN_USERNAME=admin \
  BIFROST_ADMIN_PASSWORD='Valid!Password1' python3 "$ROOT/04-ops/migrate-bifrost-model.py" \
  --model successor-model --evidence "$tmp/model-migration" --apply
curl -fsS "http://127.0.0.1:$edge_port/v1/chat/completions" -H "Authorization: Bearer $rotated" -H 'Content-Type: application/json' \
  -d '{"model":"successor-model","messages":[{"role":"user","content":"probe"}]}' | jq -e '.choices[0].message.content == "fixture-ok"' >/dev/null
printf 'PASS pinned model permission migration preserves the same stable credential\n'
admission_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
env GDC_GATEWAY_ADMISSION_PORT="$admission_port" \
  GDC_GATEWAY_ADMISSION_UPSTREAM="http://127.0.0.1:$upstream_port" \
  GDC_GATEWAY_ADMISSION_STATUS_URL="http://127.0.0.1:$upstream_port/v1/status" \
  GDC_GATEWAY_ADMISSION_STATUS_BEARER_TOKEN=fixture-status \
  GDC_GATEWAY_ADMISSION_EPOCH_URL="http://127.0.0.1:$upstream_port/epoch" \
  GDC_GATEWAY_ADMISSION_EPOCH_INFO_URL="http://127.0.0.1:$upstream_port/epoch-info" \
  GDC_GATEWAY_ADMISSION_CHAIN_STATUS_URL="http://127.0.0.1:$upstream_port/chain-status" \
  GDC_GATEWAY_ADMISSION_CHAIN_PARAMS_URL="http://127.0.0.1:$upstream_port/params" \
  GDC_GATEWAY_ADMISSION_PROTOCOLS_JSON='{"v6":{"binary":"https://example.invalid/v6.zip","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}' \
  GDC_GATEWAY_ADMISSION_SELECTED_VERSION=v6 GDC_GATEWAY_ADMISSION_MAX_WAIT_SECONDS=5 \
  GDC_GATEWAY_ADMISSION_MAX_DISPATCHES_PER_BLOCK=10 GDC_GATEWAY_ADMISSION_POLL_SECONDS=0.03 \
  GDC_GATEWAY_ADMISSION_AUDIT_FILE="$tmp/admission.jsonl" \
  "$python_test" "$ROOT/04-ops/edge-node/gateway-admission-proxy.py" >"$tmp/admission.log" 2>&1 & admission_pid=$!
ready=false
for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$admission_port/v1/admission-status" | jq -e '.state == "READY"' >/dev/null; then ready=true; break; fi
  sleep 1
done
[[ "$ready" == true ]] || { cat "$tmp/admission.log" >&2; exit 1; }
jq -c --arg base "http://127.0.0.1:$admission_port" '{network_config:(.network_config + {base_url:$base}),concurrency_and_buffer_size,custom_provider_config,proxy_config}' <<<"$provider_before" >"$tmp/admission-provider.json"
put_fixture_config /api/providers/gonka-s "$tmp/admission-provider.json"
for stream in false true; do
  deadline_ms="$(python3 -c 'import time; print(time.time_ns() // 1000000 + 20000)')"
  printf '%s' "$deadline_ms" >"$tmp/admission-$stream.deadline"
  curl -fsS --max-time 15 -D "$tmp/admission-$stream.headers" -o "$tmp/admission-$stream.body" \
    "http://127.0.0.1:$edge_port/v1/chat/completions" -H "Authorization: Bearer $rotated" \
    -H "X-Request-Deadline-Ms: $deadline_ms" \
    -H 'X-GDC-Admission-ID: client-forgery' -H 'Content-Type: application/json' \
    -d "{\"model\":\"test-model\",\"messages\":[{\"role\":\"user\",\"content\":\"probe\"}],\"stream\":$stream}"
done
python3 - "$tmp" <<'PY'
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
records = [json.loads(line) for line in (root / "admission.jsonl").read_text().splitlines()]
assert len(records) == 2, records
ids = set()
for stream, record in zip(("false", "true"), records):
    headers = dict(line.split(":", 1) for line in (root / f"admission-{stream}.headers").read_text().splitlines() if ":" in line)
    headers = {key.lower(): value.strip() for key, value in headers.items()}
    receipt = headers["x-gdc-admission-id"]
    assert receipt != "client-forgery" and receipt == record["admission_id"]
    assert record["admission"] == "dispatched_once" and record["error_class"] == ""
    assert record["deadline_ms"] == int((root / f"admission-{stream}.deadline").read_text()), record
    assert headers["x-gdc-admission"] == "dispatched_once"
    assert headers["x-request-id"].startswith("fixture-native-")
    ids.add(receipt)
assert len(ids) == 2
assert json.loads((root / "admission-false.body").read_text())["choices"][0]["message"]["content"] == "fixture-ok"
assert "data: [DONE]" in (root / "admission-true.body").read_text()
print("PASS pinned stable JSON/SSE carries real v6 admission receipts bound to final audits")
PY
python3 - "$tmp" "$edge_port" "$upstream_port" "$rotated" <<'PY'
from concurrent.futures import ThreadPoolExecutor
import http.client
import json
from pathlib import Path
import sys
import threading
root, edge_port, upstream_port, key = sys.argv[1:]
barrier = threading.Barrier(2)
def request(marker):
    connection = http.client.HTTPConnection("127.0.0.1", int(edge_port), timeout=10)
    barrier.wait(timeout=5)
    connection.request("POST", "/v1/chat/completions", json.dumps({"model": "test-model",
        "messages": [{"role": "user", "content": marker}]}),
        {"Authorization": "Bearer " + key, "Content-Type": "application/json"})
    response = connection.getresponse()
    body = json.loads(response.read())
    assert response.status == 200, body
    assert body["choices"][0]["message"]["content"] == marker
    assert response.getheader("X-Request-Id") == "fixture-native-" + marker
    receipt = response.getheader("X-GDC-Admission-ID")
    connection.close()
    return receipt
with ThreadPoolExecutor(max_workers=2) as pool:
    receipts = list(pool.map(request, ("receipt-one", "receipt-two")))
assert len(set(receipts)) == 2 and all(receipts)
records = [json.loads(line) for line in (Path(root) / "admission.jsonl").read_text().splitlines()]
assert len(records) == 4
for receipt in receipts:
    matches = [row for row in records if row["admission_id"] == receipt]
    assert len(matches) == 1 and matches[0]["admission"] == "dispatched_once"
    assert matches[0]["error_class"] == ""
connection = http.client.HTTPConnection("127.0.0.1", int(upstream_port), timeout=5)
connection.request("GET", "/fixture/requests")
response = connection.getresponse()
assert sorted(json.loads(response.read())) == ["receipt-one", "receipt-two"]
connection.close()
print("PASS concurrent stable requests retain exclusive receipts with exactly one native dispatch each")
PY
python3 - "$tmp" "$edge_port" "$upstream_port" "$rotated" <<'PY'
import http.client
import json
from pathlib import Path
import sys
import time
root, edge_port, upstream_port, key = sys.argv[1:]
root = Path(root)
(root / "poc-fence").touch()
time.sleep(1)
deadline = time.time_ns() // 1000000 + 2000
started = time.monotonic()
connection = http.client.HTTPConnection("127.0.0.1", int(edge_port), timeout=10)
connection.request("POST", "/v1/chat/completions", json.dumps({"model": "test-model",
    "messages": [{"role": "user", "content": "receipt-fenced"}]}),
    {"Authorization": "Bearer " + key, "Content-Type": "application/json",
     "X-Request-Deadline-Ms": str(deadline)})
response = connection.getresponse()
body = json.loads(response.read())
assert response.status == 503, (response.status, body)
assert time.monotonic() - started < 5
receipt = response.getheader("X-GDC-Admission-ID")
assert response.getheader("X-GDC-Admission") == "pre_dispatch_rejected", (response.getheaders(), body)
connection.close()
records = [json.loads(line) for line in (root / "admission.jsonl").read_text().splitlines()]
matches = [row for row in records if row["admission_id"] == receipt]
assert len(matches) == 1, records
record = matches[0]
assert record["deadline_ms"] == deadline, record
assert record["error_class"] == "admission_poc_fence", record
assert record["dispatch_height"] is None and record["upstream_http_status"] == 0, record
connection = http.client.HTTPConnection("127.0.0.1", int(upstream_port), timeout=5)
connection.request("GET", "/fixture/requests")
assert sorted(json.loads(connection.getresponse().read())) == ["receipt-one", "receipt-two"]
connection.close()
print("PASS pinned stable PoC refusal respects caller deadline and never dispatches upstream")
# Match the tester's ordinary request: no deadline header and no retry.
started_ms = time.time_ns() // 1000000
started = time.monotonic()
connection = http.client.HTTPConnection("127.0.0.1", int(edge_port), timeout=30)
connection.request("POST", "/v1/chat/completions", json.dumps({"model": "test-model",
    "messages": [{"role": "user", "content": "receipt-fenced"}], "max_tokens": 32}),
    {"Authorization": "Bearer " + key, "Content-Type": "application/json"})
response = connection.getresponse()
body = json.loads(response.read())
assert response.status == 503 and time.monotonic() - started < 25, body
assert "admission_poc_fence" in json.dumps(body), body
receipt = response.getheader("X-GDC-Admission-ID")
assert response.getheader("X-GDC-Admission") == "pre_dispatch_rejected"
connection.close()
records = [json.loads(line) for line in (root / "admission.jsonl").read_text().splitlines()]
matches = [row for row in records if row["admission_id"] == receipt]
assert len(matches) == 1
record = matches[0]
assert started_ms + 20000 <= record["deadline_ms"] <= started_ms + 22000, record
assert record["error_class"] == "admission_poc_fence"
assert record["dispatch_at_ms"] is None and record["upstream_http_status"] == 0
connection = http.client.HTTPConnection("127.0.0.1", int(upstream_port), timeout=5)
connection.request("GET", "/fixture/requests")
assert sorted(json.loads(connection.getresponse().read())) == ["receipt-one", "receipt-two"]
connection.close()
print("PASS ordinary no-deadline client receives a bounded explicit PoC refusal without dispatch")
PY
printf 'PASS pinned Bifrost bootstrap, stable edge protocols and rotation, preview/apply, stale/no-op and restart lifecycle\n'
