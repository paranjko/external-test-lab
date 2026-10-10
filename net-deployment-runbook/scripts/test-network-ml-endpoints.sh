#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

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

if "$ROOT/scripts/add-network-ml-endpoint.sh" \
  --input "$next" --ml-host mlnode5.example.test --ml-alias gdc-node5 \
  --output "$tmp/duplicate.json" --id-output "$tmp/duplicate-id" >/dev/null 2>&1; then
  echo 'adding an already configured ML endpoint unexpectedly succeeded' >&2
  exit 1
fi

deploy="$tmp/deploy"
fake_bin="$tmp/bin"
mkdir -p "$deploy" "$fake_bin"
cp "$next" "$deploy/node-config.json"
cp "$ROOT/02-node/sync-node-config.sh" "$deploy/sync-node-config.sh"
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

(
  cd "$deploy"
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

printf 'PASS network ML endpoint configuration retains the local endpoint and synchronizes the additional endpoint\n'
