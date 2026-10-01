#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
action="${1:-}"
[[ $# -eq 1 && "$action" =~ ^(preview|apply)$ ]] || die 'expected: ops gateway-readiness preview|apply'
target="$(jq -ce '[.[] | select(.id == "B")] | select(length == 1) | .[0]
  | select((keys | sort) == ["id","node","port","secret_file"])
  | select(.secret_file == "/srv/dai/broker-tests/ds502-b/gateway.env")
  | select(.node | type == "string" and test("^[A-Za-z0-9._-]+$"))
  | select(.port | type == "number" and floor == . and . >= 1024 and . <= 65535)' \
  <<<"${GDC_GATEWAY_SETTINGS_TARGETS:-}")" || die 'B readiness requires one configured independent B target'
node="$(jq -r .node <<<"$target")"
native_port="$(jq -r .port <<<"$target")"
topology_contains_node "$node" || die 'B readiness target is outside the inventory'
port="${GDC_GATEWAY_B_READINESS_PORT:-18086}"
[[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && (( port >= 1024 && port <= 65535 )) || die 'invalid B readiness private port'
[[ "${GDC_RUN_ID:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die 'B readiness requires a safe GDC run ID'
# The stand's core profile may predate v5. Do not upgrade Core/DAPI or
# reinterpret its frozen lock just to select B's independently released binary.
binary="${GDC_GATEWAY_READINESS_BINARY_URL:-https://github.com/gonka-ai/gonka/releases/download/devshard/v5.0.2/devshardd.zip}"
binary_sha="${GDC_GATEWAY_READINESS_BINARY_SHA256:-fa9f30775abfc14c40ac8d8a9bae7159f6193cd820f3dfac06a60170cd8b48a1}"
[[ "$binary" == https://github.com/gonka-ai/gonka/releases/download/devshard/v5.0.2/devshardd.zip \
   && "$binary_sha" == fa9f30775abfc14c40ac8d8a9bae7159f6193cd820f3dfac06a60170cd8b48a1 ]] || die 'B readiness requires the official immutable v5.0.2 release contract'
run="$GDC_HOME/runs/$GDC_RUN_ID/gateway-readiness"
mkdir -p "$run"
stage="/srv/dai/ops/gdc-gateway-readiness-$GDC_RUN_ID"
ssh -n "$node" "install -d -m 0700 '$stage'"
scp -q "$ROOT/04-ops/gateway-readiness.py" "$ROOT/04-ops/edge-node/gateway-admission-proxy.py" "$node:$stage/" < /dev/null
printf -v arguments '%q ' --source "$stage/gateway-admission-proxy.py" --port "$port" --native-port "$native_port" \
  --model "$MODEL_ID" --binary "$binary" --sha256 "$binary_sha"
preview() {
  ssh -n "$node" "sudo python3 '$stage/gateway-readiness.py' $arguments" \
    | jq -ce --arg host "$node" '. + {host:$host} | select(.schema == "gdc-gateway-readiness/1" and .applied == false and (.before_sha256 | test("^[0-9a-f]{64}$")) and (.desired_sha256 | test("^[0-9a-f]{64}$")) and (.delta | type == "array"))'
}
receipt="$run/preview.json"
if [[ "$action" == preview ]]; then
  preview >"$receipt"
  sha="$(sha256sum "$receipt" | awk '{print $1}')"
  jq --arg sha "$sha" '. + {receipt_sha256:$sha}' "$receipt"
  exit 0
fi
[[ -s "$receipt" ]] || die 'B readiness apply requires the retained preview'
sha="$(sha256sum "$receipt" | awk '{print $1}')"
[[ "${GDC_GATEWAY_READINESS_APPROVED_PREVIEW_SHA256:-}" == "$sha" ]] || die 'B readiness apply requires approval of the exact preview SHA-256'
fresh="$(preview)"
[[ "$(jq -r .before_sha256 <<<"$fresh")" == "$(jq -r .before_sha256 "$receipt")" \
   && "$(jq -r .desired_sha256 <<<"$fresh")" == "$(jq -r .desired_sha256 "$receipt")" ]] || die 'B readiness changed after preview'
expected="$(jq -r .before_sha256 "$receipt")"
ssh -n "$node" "sudo python3 '$stage/gateway-readiness.py' $arguments --apply --expected-sha256 '$expected'" \
  | jq -ce 'select(.schema == "gdc-gateway-readiness/1" and (.outcome == "PASS" or .outcome == "no-change"))' \
  | tee "$run/apply.json"
printf 'PASS B readiness managed service reconciled on %s; edge handoff requires its separate approved delta\n' "$node"
