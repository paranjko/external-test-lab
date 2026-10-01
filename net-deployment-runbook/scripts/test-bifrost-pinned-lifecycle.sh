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
compose=(docker compose --project-name "$name" --env-file "$tmp/compose.env" -f "$ROOT/04-ops/compose.yaml" -f "$tmp/compose.override.yaml")
upstream_pid=''; broker_pid=''; edge_pid=''
cleanup() { [[ -z "$edge_pid" ]] || kill "$edge_pid" >/dev/null 2>&1 || true; [[ -z "$broker_pid" ]] || kill "$broker_pid" >/dev/null 2>&1 || true; [[ -z "$upstream_pid" ]] || kill "$upstream_pid" >/dev/null 2>&1 || true; "${compose[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; rm -rf "$tmp"; }
trap cleanup EXIT

printf 'BIFROST_DATA_VOLUME_NAME=%s\nINFERENCED_IMAGE=fixture/unused:latest\nSITE_HOST=fixture.invalid\nAPI_HOST=fixture.invalid\nGRAFANA_HOST=fixture.invalid\nGATEWAY_PUBLIC_HOST=fixture.invalid\nPUBLIC_EDGE_CIDR=127.0.0.1/32\n' "$name" >"$tmp/compose.env"
printf 'APP_HOST=127.0.0.1\nAPP_PORT=%s\nBIFROST_SETUP_TOKEN=temporary-setup-token\n' "$port" >"$tmp/bifrost.env"
printf 'services:\n  bifrost:\n    env_file:\n      - %s\n' "$tmp/bifrost.env" >"$tmp/compose.override.yaml"
"$python_test" "$ROOT/scripts/bifrost-fake-inference.py" "$upstream_port" >/dev/null 2>&1 & upstream_pid=$!
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
env BIFROST_EDGE_HOST=127.0.0.1 BIFROST_EDGE_PORT="$edge_port" BIFROST_EDGE_BROKER_URL="http://127.0.0.1:$broker_port" \
  BIFROST_EDGE_UPSTREAM_URL="http://127.0.0.1:$port" BIFROST_EDGE_TOKEN=eeeeeeeeeeeeeeeeeeeeeeee \
  "$python_test" "$ROOT/04-ops/bifrost-protocol-edge.py" >/dev/null 2>&1 & edge_pid=$!
for _ in $(seq 1 30); do curl -fsS "http://127.0.0.1:$broker_port/v1/keys" -o /dev/null -X POST -H 'Authorization: Bearer bbbbbbbbbbbbbbbbbbbbbbbb' -H 'Content-Type: application/json' -d '{"telegram_id":99,"update_id":1}' && break || sleep 1; done
stable="$(curl -fsS -X POST "http://127.0.0.1:$broker_port/v1/keys" -H 'Authorization: Bearer bbbbbbbbbbbbbbbbbbbbbbbb' -H 'Content-Type: application/json' -d '{"telegram_id":99,"update_id":1}' | jq -r .key)"
[[ "$stable" == sk-gdc-* ]]
edge_openai_body="$tmp/edge-openai.json"
edge_openai_code="$(curl -sS -o "$edge_openai_body" -w '%{http_code}' "http://127.0.0.1:$edge_port/v1/chat/completions" -H "Authorization: Bearer $stable" -H 'Content-Type: application/json' -d '{"model":"test-model","messages":[{"role":"user","content":"probe"}]}')"
[[ "$edge_openai_code" == 200 ]] || { echo "pinned edge OpenAI request returned $edge_openai_code: $(<"$edge_openai_body")" >&2; exit 1; }
jq -e '.choices[0].message.content == "fixture-ok"' "$edge_openai_body" >/dev/null
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
printf 'PASS pinned Bifrost bootstrap, stable edge protocols and rotation, preview/apply, stale/no-op and restart lifecycle\n'
