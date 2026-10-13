#!/usr/bin/env bash
# Exercise the pinned DAPI deletion path against a real local Core.  It proves
# that DELETE removes the configured worker from the running broker, rather
# than treating an HTTP response from a mock as proof of detachment.
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_lock="$ROOT/profiles/releases/v2026.08.06.lock"
denom_metadata="$ROOT/test/fixtures/recovery/denom.json"
[[ -f "$release_lock" && -f "$denom_metadata" ]] || {
  echo "required pinned-DAPI test fixture is missing" >&2
  exit 2
}

set -a
# shellcheck source=/dev/null
source "$release_lock"
set +a
ensure_image() {
  local image="$1"
  docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image" >/dev/null
  docker image inspect -f '{{.Id}}' "$image"
}
core_image="$(ensure_image "$INFERENCED_IMAGE")"
# shellcheck disable=SC2153 # release lock assigns DAPI_IMAGE
dapi_image="$(ensure_image "$DAPI_IMAGE")"
probe_image="$(ensure_image gdc-runbook-bats:local)"

scratch="$(mktemp -d)"
suffix="${scratch##*/}"
network="gdc-pinned-dapi-${suffix}"
core="gdc-pinned-core-${suffix}"
dapi="gdc-pinned-dapi-${suffix}"
drain_service="gdc-pinned-drain-${suffix}"
uid="$(id -u):$(id -g)"
stage=init

cleanup() {
  docker rm -f "$dapi" "$core" "$drain_service" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  # DAPI runs as root in its shipped image and writes its own runtime cache.
  # Remove that disposable cache through the same local container boundary.
  docker run --rm --pull never -v "$scratch:/test" --entrypoint sh "$probe_image" \
    -c 'rm -rf /test/* /test/.[!.]* /test/..?*' >/dev/null 2>&1 || true
  rm -rf -- "$scratch"
}

on_exit() {
  local rc=$?
  if (( rc != 0 )); then
    printf 'FAIL pinned DAPI worker removal stage=%s\n' "$stage" >&2
    docker logs "$core" 2>&1 | tail -40 >&2 || true
    docker logs "$dapi" 2>&1 | tail -80 >&2 || true
  fi
  cleanup
  exit "$rc"
}
trap on_exit EXIT

cli() {
  docker run --rm --pull never --network none --user "$uid" -v "$scratch:/test" \
    --entrypoint inferenced "$core_image" "$@"
}

core_rpc() {
  docker run --rm --pull never --network "container:$core" --entrypoint curl "$probe_image" \
    -fsS --max-time 3 "http://127.0.0.1:26657/$1"
}

api() {
  docker run --rm --pull never --network "$network" --entrypoint curl "$probe_image" \
    -fsS --max-time 3 "http://api:9200/admin/v1/$1"
}

wait_core() {
  local end=$((SECONDS + 90)) height
  while (( SECONDS < end )); do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$core" 2>/dev/null || true)" != true ]]; then
      return 1
    fi
    height="$(core_rpc status 2>/dev/null | jq -r '.result.sync_info.latest_block_height // 0' || true)"
    [[ "$height" =~ ^[0-9]+$ ]] && (( height >= 3 )) && return 0
    sleep 1
  done
  return 1
}

wait_api() {
  local end=$((SECONDS + 90))
  while (( SECONDS < end )); do
    api nodes >/dev/null 2>&1 && return 0
    if [[ "$(docker inspect -f '{{.State.Running}}' "$dapi" 2>/dev/null || true)" != true ]]; then
      return 1
    fi
    sleep 1
  done
  return 1
}

wait_for_file() {
  local file="$1" end=$((SECONDS + 45))
  while (( SECONDS < end )); do
    [[ -f "$file" ]] && return 0
    if [[ "$(docker inspect -f '{{.State.Running}}' "$dapi" 2>/dev/null || true)" != true ]]; then
      return 1
    fi
    sleep 1
  done
  return 1
}

stage=genesis
cli init pinned-dapi --chain-id pinned-dapi --default-denom ngonka --home /test/core >/dev/null 2>&1
jq -s '.[0] * .[1]' "$scratch/core/config/genesis.json" "$denom_metadata" >"$scratch/genesis.json"
mv "$scratch/genesis.json" "$scratch/core/config/genesis.json"
cli keys add operator --keyring-backend test --home /test/core >"$scratch/operator.key" 2>/dev/null
address="$(cli keys show operator -a --keyring-backend test --home /test/core)"
warm="$(cli keys add warm --keyring-backend test --home /test/core 2>/dev/null | awk '/address:/ { print $3; exit }')"
denom="$(jq -r .app_state.staking.params.bond_denom "$scratch/core/config/genesis.json")"
tmp_genesis="$scratch/genesis.with-model.json"
jq '.app_state.inference.model_list = [{
  proposed_by: "genesis",
  id: "Qwen/Qwen3-0.6B",
  units_of_compute_per_token: "100",
  hf_repo: "Qwen/Qwen3-0.6B",
  hf_commit: "c1899de289a04d12100db370d81485cdf75e47ca",
  model_args: ["--max-model-len", "2048"],
  v_ram: "4",
  throughput_per_nonce: "1000",
  validation_threshold: {value: "95", exponent: -2}
}]' "$scratch/core/config/genesis.json" >"$tmp_genesis"
mv "$tmp_genesis" "$scratch/core/config/genesis.json"
cli genesis add-genesis-account "$address" "1000000000000000000$denom" --home /test/core
consensus_key="$(jq -r .pub_key.value "$scratch/core/config/priv_validator_key.json")"
cli genesis gentx operator "1000000000000000$denom" --pubkey "$consensus_key" \
  --ml-operational-address "$warm" --url http://pinned-dapi.invalid:8000 --chain-id pinned-dapi \
  --keyring-backend test --home /test/core >/dev/null 2>&1
cli genesis collect-gentxs --home /test/core >/dev/null 2>&1
cli genesis patch-genesis --home /test/core >/dev/null 2>&1
sed -i "s|^minimum-gas-prices *=.*|minimum-gas-prices = \"0$denom\"|" "$scratch/core/config/app.toml"
account_pubkey="$(cli keys show operator --pubkey --keyring-backend test --home /test/core | jq -er .key)"

stage=core
docker network create --internal "$network" >/dev/null
docker run -d --pull never --network "$network" --network-alias core --user "$uid" --name "$core" \
  -v "$scratch:/test" --entrypoint inferenced "$core_image" start --home /test/core \
  --rpc.laddr tcp://0.0.0.0:26657 --api.enable --api.address tcp://0.0.0.0:1317 >/dev/null
wait_core

printf '%s\n' '[
  {"id":"draining-node","host":"mlnode-draining","inference_port":8080,"poc_port":8080,"max_concurrent":1,"models":{"Qwen/Qwen3-0.6B":{"args":[]}}},
  {"id":"retained-node","host":"mlnode-retained","inference_port":8081,"poc_port":8081,"max_concurrent":1,"models":{"Qwen/Qwen3-0.6B":{"args":[]}}}
]' >"$scratch/node-config.json"

cat >"$scratch/drain-handler.sh" <<'SH'
#!/bin/sh
set -eu
IFS= read -r request || exit 0
while IFS= read -r header; do
  [ "$header" = "$(printf '\r')" ] && break
done
case "$request" in
  *'/api/v1/stop '* )
    : > /test/drain-inflight
    while [ ! -f /test/drain-release ]; do sleep 1; done
    body='{}'
    ;;
  *'/api/v1/state '* )
    body='{"state":"STOPPED","version":"test","poc_validation_inference":false,"loaded_model":""}'
    ;;
  *'/api/v1/inference/up '* ) body='{}' ;;
  *) body='{}' ;;
esac
printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "${#body}" "$body"
SH
chmod 0755 "$scratch/drain-handler.sh"
docker run -d --pull never --network "$network" --network-alias mlnode-draining --name "$drain_service" \
  -v "$scratch:/test" --entrypoint busybox "$probe_image" nc -lk -p 8080 -e /test/drain-handler.sh >/dev/null

stage=dapi
mkdir -p "$scratch/dapi"
docker run -d --pull never --network "$network" --network-alias api --name "$dapi" \
  -v "$scratch/core:/root/.inference" -v "$scratch/dapi:/root/.dapi" \
  -v "$scratch/node-config.json:/root/node_config.json:ro" \
  -e KEY_NAME=operator -e ACCOUNT_PUBKEY="$account_pubkey" -e KEYRING_BACKEND=test \
  -e KEYRING_DIR=/root/.inference -e NODE_CONFIG_PATH=/root/node_config.json \
  -e DAPI_API__POC_CALLBACK_URL=http://api:9100 -e DAPI_API__PUBLIC_URL=http://api:9000 \
  -e DAPI_API__PUBLIC_SERVER_PORT=9000 -e DAPI_API__ML_SERVER_PORT=9100 \
  -e DAPI_API__ADMIN_SERVER_PORT=9200 -e DAPI_API__NODE_MANAGER_GRPC_PORT=-1 \
  -e DAPI_CHAIN_NODE__URL=http://core:26657 -e DAPI_CHAIN_NODE__SEED_API_URL=http://core:1317 \
  -e DAPI_CHAIN_NODE__IS_GENESIS=true -e DAPI_CHAIN_NODE__KEYRING_BACKEND=test \
  -e DAPI_CHAIN_NODE__KEYRING_DIR=/root/.inference -e DAPI_CHAIN_NODE__ACCOUNT_PUBLIC_KEY="$account_pubkey" \
  -e DAPI_TX_BATCHING__DISABLED=true -e DAPI_OTEL_ENABLED=false "$dapi_image" >/dev/null
wait_api

stage=worker
api nodes | jq -e '
  length == 2 and
  ([.[].node.id] | sort) == ["draining-node", "retained-node"]
' >/dev/null

stage=inflight
wait_for_file "$scratch/drain-inflight" || {
  echo 'pinned DAPI did not start the draining worker command' >&2
  exit 1
}

stage=remove
docker run --rm --pull never --network "$network" --entrypoint curl "$probe_image" \
  -fsS --max-time 20 -X DELETE http://api:9200/admin/v1/nodes/draining-node >"$scratch/delete.json" &
delete_pid=$!
sleep 2
if ! kill -0 "$delete_pid" 2>/dev/null; then
  echo 'pinned DAPI DELETE returned before the in-flight worker command completed' >&2
  wait "$delete_pid" || true
  exit 1
fi
touch "$scratch/drain-release"
wait "$delete_pid"
jq -e '. == true' "$scratch/delete.json" >/dev/null
api nodes | jq -e 'length == 1 and .[0].node.id == "retained-node"' >/dev/null
printf 'PASS pinned DAPI DELETE waits for in-flight worker work and removes only the configured worker\n'
