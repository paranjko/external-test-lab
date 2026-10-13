#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
while (($#)); do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    -w) shift 2 ;;
    *) shift ;;
  esac
done
cp "$GDC_TEST_BOOTSTRAP" "$output"
printf '200'
EOF
chmod 0755 "$tmp/bin/curl"

(
  unset GDC_NETWORK_BOOTSTRAP_URL GDC_NETWORK_CHAIN_ID CHAIN_ID
  # shellcheck disable=SC1090
  source "$ROOT/scripts/lib.sh"
  [[ "$(network_bootstrap_url)" == 'https://gonka-dev.net/gonka-devnet-community/bootstrap.json' ]]
)
(
  GDC_NETWORK_CHAIN_ID='fixture-chain'
  GDC_NETWORK_BOOTSTRAP_URL='https://bootstrap.example/custom.json'
  export GDC_NETWORK_CHAIN_ID GDC_NETWORK_BOOTSTRAP_URL
  # shellcheck disable=SC1090
  source "$ROOT/scripts/lib.sh"
  [[ "$(network_bootstrap_url)" == "$GDC_NETWORK_BOOTSTRAP_URL" ]]
)

bootstrap_mlnode="$tmp/bootstrap-mlnode.json"
PATH="$tmp/bin:$PATH" GDC_TEST_BOOTSTRAP="$ROOT/../bootstrap/gonka-devnet-community.json" \
  "$ROOT/scripts/resolve-bootstrap-mlnode.sh" --url https://bootstrap.example/bootstrap.json \
  --run-id fixture --output "$bootstrap_mlnode" >"$tmp/bootstrap-mlnode.out"
jq -e '
  .bootstrap.url == "https://bootstrap.example/bootstrap.json"
  and .mlnode == {
    image:"ghcr.io/gonka-ai/mlnode:3.0.16@sha256:1b9b7ce55feecab837f1d7ce974fc5f377ae0a04a4fb403eeeb50130e7728ee1",
    proxy_image:"nginx:1.28.0@sha256:552e7481ca93ffccd046aa658dbbed22caefbc09c66fa7cd247cbb90b8a5c609",
    model_id:"Qwen/Qwen3-0.6B",model_revision:"c1899de289a04d12100db370d81485cdf75e47ca",
    context_length:2048,max_num_seqs:64,gpu_memory_utilization:"0.85",dtype:"auto",tensor_parallel_size:1
  }
' "$bootstrap_mlnode" >/dev/null
bootstrap_digest='sha256:1b9b7ce55feecab837f1d7ce974fc5f377ae0a04a4fb403eeeb50130e7728ee1'
"$ROOT/scripts/verify-bootstrap-mlnode-parent.sh" --receipt "$bootstrap_mlnode" --image "$bootstrap_digest"
if "$ROOT/scripts/verify-bootstrap-mlnode-parent.sh" --receipt "$bootstrap_mlnode" \
  --image 'sha256:41d765d1bf2b0f2e1c2aa7b131ff5a5da7a6eaebfe8c3276f67478924e466cd5' \
  >/dev/null 2>&1; then
  echo 'an outdated parent MLNode image unexpectedly accepted a Bootstrap ML endpoint' >&2
  exit 1
fi

input="$tmp/node-config.json"
next="$tmp/node-config.next.json"
node_id="$tmp/node-id"
staged="$tmp/staged"
cat >"$input" <<'JSON'
[{"id":"qwen3-0.6b:gdc-node0","host":"inference","inference_port":5000,"poc_port":5000}]
JSON

"$ROOT/scripts/add-network-ml-endpoint.sh" \
  --input "$input" --ml-host mlnode5.example.test --ml-alias gdc-node5 \
  --output "$next" --id-output "$node_id"

expected_id='qwen3-0.6b:gdc-node0--gdc-node5'
[[ "$(<"$node_id")" == "$expected_id" ]]
jq -e --arg id "$expected_id" '
  length == 2
  and .[0] == {id:"qwen3-0.6b:gdc-node0",host:"inference",inference_port:5000,poc_port:5000}
  and .[1] == {id:$id,host:"mlnode5.example.test",inference_port:5000,poc_port:5000}
' "$next" >/dev/null

removed="$tmp/node-config.removed.json"
removed_id="$tmp/removed-node-id"
"$ROOT/scripts/remove-network-ml-endpoint.sh" \
  --input "$next" --ml-host mlnode5.example.test --ml-alias gdc-node5 \
  --output "$removed" --id-output "$removed_id"
[[ "$(<"$removed_id")" == "$expected_id" ]]
jq -e --slurpfile original "$input" '. == $original[0]' "$removed" >/dev/null

if "$ROOT/scripts/add-network-ml-endpoint.sh" \
  --input "$next" --ml-host mlnode5.example.test --ml-alias gdc-node5 \
  --output "$tmp/duplicate.json" --id-output "$tmp/duplicate-id" >/dev/null 2>&1; then
  echo 'adding an already configured ML endpoint unexpectedly succeeded' >&2
  exit 1
fi

deploy="$tmp/deploy"
fake_bin="$tmp/runtime-bin"
staged_sync="$tmp/staged-network-sync"
mkdir -p "$deploy" "$fake_bin" "$staged_sync"
cp "$next" "$deploy/node-config.json"
cat >"$deploy/sync-node-config.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
jq -e 'if type == "array" and length == 1 then .[0] else error("expected exactly one ML node") end' node-config.json >/dev/null
EOF
chmod 0755 "$deploy/sync-node-config.sh"
curl_log="$tmp/curl.jsonl"
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
data=''
while (($#)); do
  case "$1" in
    --data) data="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "$data" >>"$GDC_TEST_CURL_LOG"
printf '%s\n200\n' "$data"
EOF
chmod 0755 "$fake_bin/curl"

cat >"$fake_bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${GDC_TEST_NETWORK_NODE_READY:-true}" == true ]] || exit 1
exit 0
EOF
chmod 0755 "$fake_bin/ssh"

PATH="$fake_bin:$PATH" "$ROOT/scripts/check-running-network-node.sh" gdc-node0
if PATH="$fake_bin:$PATH" GDC_TEST_NETWORK_NODE_READY=false \
  "$ROOT/scripts/check-running-network-node.sh" gdc-node0 >/dev/null 2>&1; then
  echo 'an unavailable Network Node unexpectedly passed readiness' >&2
  exit 1
fi

if (
  cd "$deploy"
  PATH="$fake_bin:$PATH" ./sync-node-config.sh 2>/dev/null
); then
  echo 'the historical deployed sync helper unexpectedly accepted multiple ML endpoints' >&2
  exit 1
fi

cp "$next" "$staged_sync/node-config.json"
cp "$ROOT/02-node/sync-node-config.sh" "$staged_sync/sync-node-config.sh"
chmod 0755 "$staged_sync/sync-node-config.sh"
(
  cd "$staged_sync"
  PATH="$fake_bin:$PATH" GDC_TEST_CURL_LOG="$curl_log" ./sync-node-config.sh >"$tmp/sync-output"
)
jq -es --arg local_id 'qwen3-0.6b:gdc-node0' --arg external_id "$expected_id" '
  length == 2
  and any(.[]; .id == $local_id and .host == "inference")
  and any(.[]; .id == $external_id and .host == "mlnode5.example.test")
' "$curl_log" >/dev/null

inventory="$tmp/inventory.env"
agent_env="$tmp/agent.env"
printf '%s\n' 'GDC_NODE_ALIASES="gdc-node0"' 'GDC_NODE_ML_HOSTS=""' >"$inventory"
"$ROOT/04-ops/agent/render-env.sh" --inventory "$inventory" --host gdc-node5 \
  --allow-ml-only-host gdc-node5 --output "$agent_env"
jq -en --rawfile env "$agent_env" '$env | contains("GDC_MONITOR_HOST=gdc-node5")' >/dev/null

mkdir -p "$staged/scripts"
cp -a "$ROOT/02-node" "$staged/02-node"
install -m 0644 "$ROOT/scripts/lib-lock.sh" "$staged/scripts/lib-lock.sh"
install -m 0644 "$staged/02-node/ml-only/../../scripts/lib-lock.sh" "$staged/lib-lock.sh"
[[ -s "$staged/lib-lock.sh" ]]

printf 'PASS network ML endpoint configuration replaces the stale deployed helper and synchronizes the additional endpoint\n'
