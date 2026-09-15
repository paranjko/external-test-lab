#!/usr/bin/env bash
# Real binary primitive rehearsal, with fresh disposable identities. It does
# not claim that the incident's SSH deployments or PoC have been rehearsed.
set -Eeuo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
denom_metadata="${GONKA_UPSTREAM_WORKTREE:-$ROOT/vendor/gonka}/inference-chain/denom.json"
[[ -f "$denom_metadata" ]] || { echo 'set GONKA_UPSTREAM_WORKTREE to the existing Gonka checkout for its Genesis denomination metadata' >&2; exit 2; }
image="$(docker image inspect -f '{{.Id}}' ghcr.io/product-science/inferenced:0.2.15)"
probe_image="$(docker image inspect -f '{{.Id}}' gdc-runbook-bats:local)"
scratch="$(mktemp -d)"
export GDC_HOME="$scratch/operator"
unset GDC_INTERNAL_DATA_ROOT GDC_ENV
# Use the same isolated configuration preparation as the incident script.
source "$ROOT/scripts/recover-incident.sh"
container="gdc-recovery-primitive-${scratch##*.}"
follower="$container-follower"
network="$container-network"
cleanup() {
  docker rm -f "$container" "$follower" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf -- "$scratch"
}
stage=dependencies
on_exit() {
  local rc=$?
  if (( rc != 0 )); then
    printf 'FAIL primitive rehearsal stage=%s\n' "$stage" >&2
    case "$stage" in init|gentx|collect|patch) tail -n 12 "$scratch/$stage.log" >&2 ;; esac
  fi
  cleanup
  exit "$rc"
}
trap on_exit EXIT
uid="$(id -u):$(id -g)"
cli() { docker run --rm --pull never --network none --user "$uid" -v "$scratch:/test" --entrypoint inferenced "$image" "$@"; }
rpc() { docker run --rm --pull never --network "container:$container" --entrypoint curl "$probe_image" -fsS --max-time 5 "http://127.0.0.1:26657/$1"; }
wait_height() {
  local minimum="$1" end=$((SECONDS + 90)) height
  while (( SECONDS < end )); do
    [[ "$(docker inspect -f '{{.State.Running}}' "$container")" == true ]] || break
    height="$(rpc status 2>/dev/null | jq -r '.result.sync_info.latest_block_height // 0' || true)"
    if [[ "$height" =~ ^[0-9]+$ ]] && (( height >= minimum )); then return; fi
    sleep 2
  done
  docker logs "$container" 2>&1 | grep -E 'panic|ERR|error|invalid|failed' >&2 || true
  return 1
}
stage=init
cli init original --chain-id recovery-primitive --default-denom ngonka --home /test/original >"$scratch/init.log" 2>&1
jq -s '.[0] * .[1]' "$scratch/original/config/genesis.json" "$denom_metadata" >"$scratch/genesis.json"
mv "$scratch/genesis.json" "$scratch/original/config/genesis.json"
stage=keys
cli keys add operator --keyring-backend test --home /test/original >"$scratch/key.private.log" 2>&1
cli keys add warm --keyring-backend test --home /test/original >"$scratch/warm.private.log" 2>&1
address="$(cli keys show operator -a --keyring-backend test --home /test/original)"
warm="$(cli keys show warm -a --keyring-backend test --home /test/original)"
valoper="$(cli keys show operator -a --bech val --keyring-backend test --home /test/original)"
denom="$(jq -r .app_state.staking.params.bond_denom "$scratch/original/config/genesis.json")"
cli genesis add-genesis-account "$address" "1000000000000000000$denom" --home /test/original
public_key="$(jq -r .pub_key.value "$scratch/original/config/priv_validator_key.json")"
stage=gentx
cli genesis gentx operator "1000000000000000$denom" --pubkey "$public_key" --ml-operational-address "$warm" \
  --url http://recovery.example.com:8000 --chain-id recovery-primitive --keyring-backend test --home /test/original >"$scratch/gentx.log" 2>&1
stage=collect
cli genesis collect-gentxs --home /test/original >"$scratch/collect.log" 2>&1
stage='patch'
cli genesis patch-genesis --home /test/original >"$scratch/patch.log" 2>&1
stage='original-chain'
sed -i "s|^minimum-gas-prices *=.*|minimum-gas-prices = \"0$denom\"|" "$scratch/original/config/app.toml"
docker run -d --pull never --network none --user "$uid" --name "$container" -v "$scratch:/test" --entrypoint inferenced "$image" \
  start --home /test/original >/dev/null
wait_height 3
original_hash="$(rpc 'block?height=3' | jq -r .result.block_id.hash)"
docker stop "$container" >/dev/null
docker rm "$container" >/dev/null
cp -a "$scratch/original" "$scratch/recovered"
cli init transition --chain-id recovery-primitive --home /test/fresh >"$scratch/fresh.log" 2>&1
cp "$scratch/fresh/config/priv_validator_key.json" "$scratch/recovered/config/priv_validator_key.json"
cp "$scratch/fresh/data/priv_validator_state.json" "$scratch/recovered/data/priv_validator_state.json"
new_key="$(jq -r .pub_key.value "$scratch/fresh/config/priv_validator_key.json")"
stage='in-place-testnet'
sed -i 's|^external_address *=.*|external_address = "validator.example.invalid:26656"|' "$scratch/recovered/config/config.toml"
cp "$scratch/recovered/config/config.toml" "$scratch/public-config.toml"
isolate_testnet_config "$scratch/recovered/config/config.toml"
grep -Fxq 'external_address = ""' "$scratch/recovered/config/config.toml"
docker run -d --pull never --network none --user "$uid" --name "$container" -v "$scratch:/test" --entrypoint inferenced "$image" \
  in-place-testnet recovery-primitive "$valoper" --home /test/recovered --skip-confirmation >/dev/null
wait_height 8
[[ "$(rpc 'block?height=3' | jq -r .result.block_id.hash)" == "$original_hash" ]]
rpc validators | jq -e --arg key "$new_key" '.result.total == "1" and .result.validators[0].pub_key.value == $key' >/dev/null
cmp "$scratch/original/config/genesis.json" "$scratch/recovered/config/genesis.json"
before="$(rpc status | jq -r .result.sync_info.latest_block_height)"
docker stop "$container" >/dev/null
docker rm "$container" >/dev/null
stage='ordinary-restart'
jq -cS . "$scratch/recovered/config/genesis.json" >"$scratch/reformatted.json"
mv "$scratch/reformatted.json" "$scratch/recovered/config/genesis.json"
restore_genesis_bytes "$scratch/original/config/genesis.json" "$scratch/recovered/config/genesis.json" "$(sha "$scratch/original/config/genesis.json")"
cmp "$scratch/original/config/genesis.json" "$scratch/recovered/config/genesis.json"
restore_external_address "$scratch/public-config.toml" "$scratch/recovered/config/config.toml"
grep -Fxq 'external_address = "validator.example.invalid:26656"' "$scratch/recovered/config/config.toml"
# The rehearsal's ordinary restart is also network-isolated.
isolate_testnet_config "$scratch/recovered/config/config.toml"
docker run -d --pull never --network none --user "$uid" --name "$container" -v "$scratch:/test" --entrypoint inferenced "$image" \
  start --home /test/recovered >/dev/null
wait_height "$((before + 2))"
[[ "$(rpc 'block?height=3' | jq -r .result.block_id.hash)" == "$original_hash" ]]
printf 'PASS real in-place-testnet preserves Genesis/history, changes the signer, and survives an ordinary restart\n'

stage='native-snapshot'
snapshot_height="$(rpc status | jq -er .result.sync_info.latest_block_height)"
docker stop "$container" >/dev/null
docker rm "$container" >/dev/null
cli snapshots export --height "$snapshot_height" --home /test/recovered >"$scratch/snapshot.log" 2>&1
cli snapshots list --home /test/recovered | grep -Eq "^height: $snapshot_height format: [0-9]+ chunks: [1-9][0-9]*$"
docker network create --internal "$network" >/dev/null
docker run -d --pull never --network "$network" --network-alias recovery-source --user "$uid" --name "$container" \
  -v "$scratch:/test" --entrypoint inferenced "$image" start --home /test/recovered --rpc.laddr tcp://0.0.0.0:26657 >/dev/null
wait_height "$((snapshot_height + 2))"
trust_height="$(rpc status | jq -er .result.sync_info.latest_block_height)"
trust_hash="$(rpc "block?height=$trust_height" | jq -er .result.block_id.hash)"
peer="$(rpc status | jq -er .result.node_info.id)@recovery-source:26656"
cli init follower --chain-id recovery-primitive --home /test/follower >"$scratch/follower.log" 2>&1
cp "$scratch/original/config/genesis.json" "$scratch/follower/config/genesis.json"
configure_recovery_statesync "$scratch/follower/config/config.toml" http://recovery-source:26657 "$trust_height" "$trust_hash"
cp "$scratch/follower/config/priv_validator_key.json" "$scratch/follower-key.json"
stage='native-state-sync'
docker run -d --pull never --network "$network" --user "$uid" --name "$follower" \
  -v "$scratch:/test" --entrypoint inferenced "$image" start --home /test/follower \
  --minimum-gas-prices "0$denom" --priv_validator_laddr '' --p2p.persistent_peers "$peer" --p2p.seeds '' --p2p.pex=false >/dev/null
follower_rpc() { docker run --rm --pull never --network "container:$follower" --entrypoint curl "$probe_image" -fsS --max-time 5 "http://127.0.0.1:26657/$1"; }
end=$((SECONDS + 180)); synced=false
while (( SECONDS < end )); do
  [[ "$(docker inspect -f '{{.State.Running}}' "$follower")" == true ]] || break
  if follower_rpc status 2>/dev/null | jq -e --argjson minimum "$trust_height" \
    '.result.sync_info.catching_up == false and (.result.sync_info.latest_block_height|tonumber) > $minimum' >/dev/null; then
    synced=true; break
  fi
  sleep 2
done
if [[ "$synced" != true ]]; then docker logs --tail 60 "$follower" >&2; exit 1; fi
common="$(follower_rpc status | jq -er .result.sync_info.latest_block_height)"
[[ "$(follower_rpc "block?height=$common" | jq -er '.result.block_id.hash + .result.block.header.app_hash')" \
  == "$(rpc "block?height=$common" | jq -er '.result.block_id.hash + .result.block.header.app_hash')" ]]
follower_rpc status | jq -e --argjson height "$snapshot_height" '.result.sync_info.earliest_block_height|tonumber >= $height' >/dev/null
cmp "$scratch/follower-key.json" "$scratch/follower/config/priv_validator_key.json"
[[ "$(jq -r .height "$scratch/follower/data/priv_validator_state.json")" == 0 ]]
printf 'PASS fresh signerless node state-syncs the recovered fork via P2P and matches source state; no database archive transfer\n'
