#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

state="$tmp/state"
genesis_dir="$tmp/genesis"
mkdir -p "$state" "$genesis_dir"
bootstrap="$tmp/bootstrap.json"
profile="$tmp/join-profile.json"
genesis="$genesis_dir/genesis.json"
seed="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
rpc='https://node0.example.invalid/chain-rpc'
p2p='tcp://node0.example.invalid:26656'
eval "$(sed -n '/^genesis_sha256() {$/,/^}$/p' "$ROOT/scripts/lib.sh")"

jq -n --arg seed "$seed" --arg rpc "$rpc" --arg p2p "$p2p" '{
  bootstrap_mode:"genesis-single-seed", chain_id:"fixture-chain",
  genesis:{sha256:"placeholder"}, seeds:[{node_id:$seed,rpc:$rpc,p2p:$p2p}]
}' >"$bootstrap"
jq -n '{chain_id:"fixture-chain",app_hash:"",initial_height:"1"}' >"$genesis"
genesis_sha="$(genesis_sha256 "$genesis")"
genesis_distribution_sha="$(sha256sum "$genesis" | awk '{print $1}')"
jq --arg sha "$genesis_distribution_sha" '.genesis.sha256=$sha' "$bootstrap" >"$tmp/bootstrap.tmp"
mv "$tmp/bootstrap.tmp" "$bootstrap"
bootstrap_sha="$(sha256sum "$bootstrap" | awk '{print $1}')"
jq -n --arg chain "fixture-chain" --arg genesis "$genesis_sha" --arg distribution "$genesis_distribution_sha" --arg bootstrap "$bootstrap_sha" '{
  spec:{network:{chain_id:$chain,genesis_sha256:$genesis,bootstrap_genesis_sha256:$distribution,bootstrap_sha256:$bootstrap}}
}' >"$profile"
printf '%s@%s\n' "$seed" "${p2p#tcp://}" >"$genesis_dir/genesis-seeds.txt"

jq -n --arg chain "fixture-chain" --arg genesis "$genesis_sha" --arg distribution "$genesis_distribution_sha" --arg seed "$seed" --arg rpc "$rpc" --arg p2p "$p2p" '{
  schema_version:1, kind:"gdc-host-join-lineage-preflight",
  runtime:{observation_sha256:("b" * 64)},
  bootstrap:{mode:"full_sync",chain_id:$chain,genesis_sha256:$genesis,distribution_sha256:$distribution,
    seed:{node_id:$seed,rpc_url:$rpc,p2p:$p2p}},
  trust_authority:{kind:"genesis_single_seed",rpc_url:$rpc},
  fault_domains:[{id:"genesis-single-seed",rpc_url:$rpc,chain_id:$chain,genesis_sha256:$genesis}],
  checkpoints:null
}' >"$state/lineage-preflight.json"
receipt_sha="$(sha256sum "$state/lineage-preflight.json" | awk '{print $1}')"
cat >"$state/lineage-preflight.env" <<EOF
GDC_JOIN_BOOTSTRAP_MODE=full_sync
GDC_JOIN_SOURCE_RPC=$rpc
GDC_JOIN_TRUST_HEIGHT=0
GDC_JOIN_TRUST_HASH=''
GDC_JOIN_SNAPSHOT_PEERS=''
GDC_JOIN_RPC_SERVER_1=$rpc/
GDC_JOIN_RPC_SERVER_2=''
GDC_JOIN_TRUSTED_BLOCK_PERIOD=0
GDC_JOIN_LINEAGE_RECEIPT=$state/lineage-preflight.json
EOF

export ROOT GDC_HOME="$tmp/gdc" STATE="$state" GENESIS="$genesis_dir" CHAIN_ID=fixture-chain
export GDC_JOIN_BOOTSTRAP_FILE="$bootstrap" GDC_JOIN_BOOTSTRAP_SHA256="$bootstrap_sha"
export GDC_JOIN_PROFILE="$profile" GDC_JOIN_LINEAGE_RECEIPT_SHA256="$receipt_sha"
die() { echo "full-sync guard rejected input: $*" >&2; exit 1; }
eval "$(sed -n '/^verify_join_bootstrap_authority() {$/,/^}$/p' "$ROOT/scripts/phase-join.sh")"

# Exercise the exact export statement used by the GDC parent after sourcing
# the preflight output, then invoke the child's complete authority guard.
source "$state/lineage-preflight.env"
export_statement="$(sed -n '/^    export GDC_JOIN_SOURCE_RPC GDC_JOIN_RPC_SERVER_1 /p' "$ROOT/gdc.sh")"
[[ -n "$export_statement" ]] || { echo 'GDC full-sync export statement not found' >&2; exit 1; }
eval "$export_statement"
verify_join_bootstrap_authority

expect_rejected() {
  local name="$1" field="$2" value="$3"
  if ( export "$field=$value"; verify_join_bootstrap_authority ) >/dev/null 2>&1; then
    echo "unsafe full-sync tuple accepted: $name" >&2
    exit 1
  fi
}
expect_rejected extra-rpc GDC_JOIN_RPC_SERVER_2 https://other.example.invalid/
expect_rejected wrong-seed-rpc GDC_JOIN_RPC_SERVER_1 https://other.example.invalid/
expect_rejected state-sync-height GDC_JOIN_TRUST_HEIGHT 1
expect_rejected state-sync-hash GDC_JOIN_TRUST_HASH deadbeef
expect_rejected snapshot-provider GDC_JOIN_SNAPSHOT_PEERS other-seed@host:26656
expect_rejected trusted-period GDC_JOIN_TRUSTED_BLOCK_PERIOD 1

printf 'PASS GDC exports the hash-bound full-sync source RPC and JOIN guard rejects unsafe tuples\n'
