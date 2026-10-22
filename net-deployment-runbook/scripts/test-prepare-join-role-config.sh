#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; temporary="$(mktemp -d)"; trap 'rm -rf -- "$temporary"' EXIT
export GDC_MONITORING_DOCKER_CIDR=172.21.0.0/16
ssh() {
  if [[ "$*" == *'collector-fixture test -d /srv/dai/ops/prometheus/targets'* ]]; then return 0; fi
  [[ "$*" == '-G mitch-ml' ]] || { echo "unexpected SSH: $*" >&2; return 99; }
  printf 'hostname 192.0.2.45\n'
}
export -f ssh
cat >"$temporary/bootstrap.json" <<'EOF'
{"$schema":"https://gonka-dev.net/v1.bootstrap.schema.json","chain_id":"gonka-fixture","genesis":{"sha256":"dd6dc738e3856745253925b77596e1cfc1680a2eefc44fd2d7879e0f879fbce5"},"seeds":[{"node_id":"0123456789abcdef0123456789abcdef01234567","rpc":"http://one.example:8000/chain-rpc","p2p":"tcp://one.example:5000","api":"http://one.example:8000"},{"node_id":"89abcdef0123456789abcdef0123456789abcdef","rpc":"http://two.example:8000/chain-rpc","p2p":"tcp://two.example:5000"}],"brokers":[]}
EOF
cat >"$temporary/inferenced" <<'EOF'
#!/usr/bin/env bash
printf '{"chain_id":"gonka-fixture"}\n' >"$3"
EOF
chmod +x "$temporary/inferenced"
INFERENCED="$temporary/inferenced" "$ROOT/scripts/prepare-join-role-config.sh" --output "$temporary/mitch-demo.env" --ssh-alias mitch-demo --public-host host.example.net --p2p-port 5200 --gpu-ssh-alias mitch-ml --bootstrap-file "$temporary/bootstrap.json"
source "$temporary/mitch-demo.env"
[[ "$GDC_NODE_ALIASES" == mitch-demo && "$GDC_NODE_ML_HOSTS" == mitch-demo=mitch-ml && "$SEED_API_URL" == http://one.example:8000 ]]
[[ "$GDC_JOIN_REGISTRATION_ENDPOINTS" == http://one.example:8000 ]]
cat >"$temporary/account.json" <<'EOF'
{"address":"gonka1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq","account_pubkey_b64":"YWJj"}
EOF
printf 'keyring\n' >"$temporary/mitch-demo.keyring"
printf 'postgres\n' >"$temporary/mitch-demo.postgres"
cp "$temporary/mitch-demo.env" "$temporary/inventory.env"
cat >>"$temporary/inventory.env" <<'EOF'
CHAIN_ID=gonka-fixture
BASE_DENOM=ngonka
API_HOST=api.example.net
MONITORING_CIDR=127.0.0.1/32
PUBLIC_EDGE_CIDR=127.0.0.1/32
GDC_GATEWAY_METRICS_TARGETS='[{"id":"A","node":"mitch-demo","port":18087},{"id":"B","node":"seed","port":18088}]'
DATA_ROOT=/srv/dai
GENESIS_INSTALL_PATH=/srv/dai/shared/genesis.json
HF_CACHE_ROOT=/srv/hf-cache
GENESIS_P2P_PORT=5000
EOF
# Render against the actual JOIN role input: the local role configuration, not
# any retained inventory, is the authority for the joining host's public name.
"$ROOT/02-node/render-node-env.sh" --inventory "$temporary/inventory.env" --node-name mitch-demo --account-public "$temporary/account.json" --bootstrap --secrets-dir "$temporary" --output "$temporary/node.env" >/dev/null
grep -Fxq 'PUBLIC_HOST=host.example.net' "$temporary/node.env"
grep -Fxq 'PROXY_BIND_ADDRESS=127.0.0.1' "$temporary/node.env"
grep -Fxq 'HF_HOME=/srv/hf-cache' "$temporary/node.env"
printf '%s\n%s\n' 'first@one.example:5000' 'second@two.example:5000' >"$temporary/genesis-seeds.txt"
"$ROOT/02-node/render-node-env.sh" --inventory "$temporary/inventory.env" --node-name mitch-demo --account-public "$temporary/account.json" --seeds-file "$temporary/genesis-seeds.txt" --secrets-dir "$temporary" --output "$temporary/node-with-seeds.env" >/dev/null
grep -Fxq 'GENESIS_SEEDS=first@one.example:5000,second@two.example:5000' "$temporary/node-with-seeds.env"
cat >"$temporary/lineage.env" <<'EOF'
GDC_JOIN_BOOTSTRAP_MODE=state_sync
GDC_JOIN_TRUST_HEIGHT=123
GDC_JOIN_TRUST_HASH=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
GDC_JOIN_RPC_SERVER_1=https://one.example/chain-rpc/
GDC_JOIN_RPC_SERVER_2=https://two.example/chain-rpc/
GDC_JOIN_SNAPSHOT_PEERS=0123456789abcdef0123456789abcdef01234567@tcp://one.example:5000,89abcdef0123456789abcdef0123456789abcdef@tcp://two.example:5000
EOF
"$ROOT/02-node/render-node-env.sh" --inventory "$temporary/inventory.env" --node-name mitch-demo --account-public "$temporary/account.json" --seeds-file "$temporary/genesis-seeds.txt" --secrets-dir "$temporary" --state-sync-env "$temporary/lineage.env" --data-dir /srv/dai/data.generations/test-run --output "$temporary/node-state-sync.env" >/dev/null
grep -Fxq 'DATA_DIR=/srv/dai/data.generations/test-run' "$temporary/node-state-sync.env"
grep -Fxq 'GDC_JOIN_SNAPSHOT_PEERS=0123456789abcdef0123456789abcdef01234567@tcp://one.example:5000,89abcdef0123456789abcdef0123456789abcdef@tcp://two.example:5000' "$temporary/node-state-sync.env"
grep -Fxq 'GDC_JOIN_PERSISTENT_PEERS=0123456789abcdef0123456789abcdef01234567@one.example:5000,89abcdef0123456789abcdef0123456789abcdef@two.example:5000' "$temporary/node-state-sync.env"
grep -Fxq 'GDC_JOIN_SEEDS=first@one.example:5000,second@two.example:5000' "$temporary/node-state-sync.env"

# Explicit single-Genesis-seed Bootstrap may use ordinary full P2P sync, but
# only when its lineage receipt, chain/Genesis bytes and sole peer all agree.
genesis_file="$temporary/full-sync-genesis.json"
jq -n '{chain_id:"gonka-single-seed-fixture",app_hash:"",initial_height:"1",consensus_params:{block:{max_bytes:"22020096"}}}' >"$genesis_file"
full_genesis_sha="$(jq -eS 'del(.app_name,.app_version) | if has("app_hash") then .app_hash=(.app_hash // "") else . end | if has("initial_height") then .initial_height=(.initial_height|tostring) else . end | if .consensus.params? then .consensus_params=.consensus.params | del(.consensus) else . end' "$genesis_file" | sha256sum | awk '{print $1}')"
full_distribution_sha="$(sha256sum "$genesis_file" | awk '{print $1}')"
[[ "$full_distribution_sha" != "$full_genesis_sha" ]] || { echo 'full-sync fixture must distinguish raw distribution from canonical identity' >&2; exit 1; }
full_seed_node='0123456789abcdef0123456789abcdef01234567'
cat >"$temporary/full-sync-bootstrap.json" <<EOF
{"\$schema":"https://gonka-dev.net/v1.bootstrap.schema.json","chain_id":"gonka-single-seed-fixture","genesis":{"sha256":"$full_distribution_sha"},"bootstrap_mode":"genesis-single-seed","seeds":[{"node_id":"$full_seed_node","rpc":"https://one.example/chain-rpc","p2p":"tcp://one.example:5000","api":"https://one.example"}],"brokers":[]}
EOF
printf '%s@one.example:5000\n' "$full_seed_node" >"$temporary/full-sync-seeds.txt"
cat >"$temporary/full-sync-receipt.json" <<EOF
{"schema_version":1,"kind":"gdc-host-join-lineage-preflight","runtime":{"observation_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"bootstrap":{"mode":"full_sync","chain_id":"gonka-single-seed-fixture","genesis_sha256":"$full_genesis_sha","distribution_sha256":"$full_distribution_sha","seed":{"node_id":"$full_seed_node","rpc_url":"https://one.example/chain-rpc","p2p":"tcp://one.example:5000"}},"fault_domains":[{"id":"genesis-single-seed","rpc_url":"https://one.example/chain-rpc","host":"one.example","port":443,"ip":"192.0.2.10","chain_id":"gonka-single-seed-fixture","genesis_sha256":"$full_genesis_sha"}],"trust_authority":{"kind":"genesis_single_seed","rpc_url":"https://one.example/chain-rpc"},"checkpoints":null}
EOF
cat >"$temporary/full-sync.env" <<EOF
GDC_JOIN_BOOTSTRAP_MODE=full_sync
GDC_JOIN_TRUST_HEIGHT=0
GDC_JOIN_TRUST_HASH=''
GDC_JOIN_SNAPSHOT_PEERS=''
GDC_JOIN_RPC_SERVER_1=https://one.example/chain-rpc/
GDC_JOIN_RPC_SERVER_2=''
GDC_JOIN_SOURCE_RPC=https://one.example/chain-rpc
GDC_JOIN_TRUSTED_BLOCK_PERIOD=0
GDC_JOIN_LINEAGE_RECEIPT=$temporary/full-sync-receipt.json
EOF
full_receipt_sha="$(sha256sum "$temporary/full-sync-receipt.json" | awk '{print $1}')"
GDC_JOIN_LINEAGE_RECEIPT_SHA256="$full_receipt_sha" \
  "$ROOT/02-node/render-node-env.sh" --inventory "$temporary/inventory.env" --node-name mitch-demo \
  --account-public "$temporary/account.json" --seeds-file "$temporary/full-sync-seeds.txt" --secrets-dir "$temporary" \
  --state-sync-env "$temporary/full-sync.env" --bootstrap-file "$temporary/full-sync-bootstrap.json" \
  --genesis-file "$genesis_file" --data-dir /srv/dai/data.generations/full-sync --output "$temporary/full-sync-node.env" >/dev/null
grep -Fxq 'SYNC_WITH_SNAPSHOTS=false' "$temporary/full-sync-node.env"
grep -Fxq 'GDC_JOIN_STATESYNC_ENABLE=false' "$temporary/full-sync-node.env"
grep -Fxq 'GDC_JOIN_RPC_SERVERS=' "$temporary/full-sync-node.env"
grep -Fxq 'GDC_JOIN_SNAPSHOT_PEERS=' "$temporary/full-sync-node.env"
grep -Fxq "GDC_JOIN_PERSISTENT_PEERS=$full_seed_node@one.example:5000" "$temporary/full-sync-node.env"
grep -Fxq "GENESIS_SEEDS=$full_seed_node@one.example:5000" "$temporary/full-sync-node.env"
grep -Fxq 'GDC_JOIN_SEEDS=' "$temporary/full-sync-node.env"
grep -Fxq 'GDC_JOIN_PEX=false' "$temporary/full-sync-node.env"
grep -Fxq 'TRUSTED_BLOCK_PERIOD=0' "$temporary/full-sync-node.env"

# Staged distribution bytes are checked against Bootstrap's raw SHA, while
# the canonical identity is separately checked against the full-sync lineage.
jq '.genesis.sha256 = ("e" * 64)' "$temporary/full-sync-bootstrap.json" >"$temporary/full-sync-bootstrap-canonical-hash.json"
if GDC_JOIN_LINEAGE_RECEIPT_SHA256="$full_receipt_sha" \
  "$ROOT/02-node/render-node-env.sh" --inventory "$temporary/inventory.env" --node-name mitch-demo \
  --account-public "$temporary/account.json" --seeds-file "$temporary/full-sync-seeds.txt" --secrets-dir "$temporary" \
  --state-sync-env "$temporary/full-sync.env" --bootstrap-file "$temporary/full-sync-bootstrap-canonical-hash.json" \
  --genesis-file "$genesis_file" --data-dir /srv/dai/data.generations/full-sync --output "$temporary/raw-hash-mismatch.env" \
  >"$temporary/raw-hash-mismatch.out" 2>&1; then
  echo 'full_sync accepted canonical identity in place of the Bootstrap raw distribution hash' >&2; exit 1
fi
grep -Fq 'single-seed Bootstrap does not match the canonical staged Genesis identity and chain ID' "$temporary/raw-hash-mismatch.out"
[[ ! -e "$temporary/raw-hash-mismatch.env" ]]

jq '.bootstrap.genesis_sha256 = ("e" * 64) | .fault_domains[0].genesis_sha256 = ("e" * 64)' \
  "$temporary/full-sync-receipt.json" >"$temporary/full-sync-wrong-identity-receipt.json"
wrong_identity_receipt_sha="$(sha256sum "$temporary/full-sync-wrong-identity-receipt.json" | awk '{print $1}')"
sed "s|$temporary/full-sync-receipt.json|$temporary/full-sync-wrong-identity-receipt.json|" \
  "$temporary/full-sync.env" >"$temporary/full-sync-wrong-identity.env"
if GDC_JOIN_LINEAGE_RECEIPT_SHA256="$wrong_identity_receipt_sha" \
  "$ROOT/02-node/render-node-env.sh" --inventory "$temporary/inventory.env" --node-name mitch-demo \
  --account-public "$temporary/account.json" --seeds-file "$temporary/full-sync-seeds.txt" --secrets-dir "$temporary" \
  --state-sync-env "$temporary/full-sync-wrong-identity.env" --bootstrap-file "$temporary/full-sync-bootstrap.json" \
  --genesis-file "$genesis_file" --data-dir /srv/dai/data.generations/full-sync --output "$temporary/wrong-identity.env" \
  >"$temporary/wrong-identity.out" 2>&1; then
  echo 'full_sync accepted a mismatched canonical chain identity receipt' >&2; exit 1
fi
grep -Fq 'single-seed Bootstrap does not match the canonical staged Genesis identity and chain ID' "$temporary/wrong-identity.out"
[[ ! -e "$temporary/wrong-identity.env" ]]

# Resolve the actual Compose inputs, not only the generated env text. The
# explicit empty seed override must win over GENESIS_SEEDS as its fallback.
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  docker compose --env-file "$temporary/full-sync-node.env" -f "$ROOT/02-node/compose.yaml" config --format json >"$temporary/full-sync-compose.json"
  jq -e --arg peer "$full_seed_node@one.example:5000" '
    .services.node.environment.CONFIG_p2p__persistent_peers == $peer and
    .services.node.environment.CONFIG_p2p__seeds == "" and
    .services.node.environment.CONFIG_p2p__pex == "false"
  ' "$temporary/full-sync-compose.json" >/dev/null
  printf 'PASS full-sync Compose resolves the single seed as persistent peer with discovery disabled\n'
fi

# The full-sync canary proof is anchored to the one receipt seed, pins its
# address, checks node/chain identity, then compares the latest common block.
cat >"$temporary/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
resolve=''
while (($#)); do
  if [[ "$1" == --resolve ]]; then resolve="$2"; shift 2; else url="$1"; shift; fi
done
case "$url" in
  https://one.example/chain-rpc/status)
    [[ "$resolve" == one.example:443:192.0.2.10 ]]
    printf '{"result":{"node_info":{"id":"0123456789abcdef0123456789abcdef01234567","network":"gonka-single-seed-fixture"},"sync_info":{"latest_block_height":"100","catching_up":false}}}\n' ;;
  http://127.0.0.1:26657/status)
    printf '{"result":{"node_info":{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","network":"gonka-single-seed-fixture"},"sync_info":{"latest_block_height":"99","catching_up":false}}}\n' ;;
  https://one.example/chain-rpc/block\?height=99)
    [[ "$resolve" == one.example:443:192.0.2.10 ]]
    printf '{"result":{"block_id":{"hash":"%064d"},"block":{"header":{"height":"99","app_hash":"%064d"}}}}\n' 1 2 ;;
  http://127.0.0.1:26657/block\?height=99)
    printf '{"result":{"block_id":{"hash":"%064d"},"block":{"header":{"height":"99","app_hash":"%064d"}}}}\n' 1 2 ;;
  *) echo "unexpected canary RPC: $url" >&2; exit 90 ;;
esac
EOF
chmod +x "$temporary/curl"
PATH="$temporary:$PATH" "$ROOT/scripts/verify-genesis-single-seed-canary.sh" \
  "$temporary/full-sync-receipt.json" http://127.0.0.1:26657 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$temporary/full-sync-canary.json"
jq -e '.kind == "gdc-genesis-single-seed-canary" and .common_height == 99 and .seed_node_id == "0123456789abcdef0123456789abcdef01234567"' "$temporary/full-sync-canary.json" >/dev/null
if PATH="$temporary:$PATH" "$ROOT/scripts/verify-genesis-single-seed-canary.sh" \
  "$temporary/full-sync-receipt.json" http://127.0.0.1:26657 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$temporary/wrong-node-canary.json" \
  >"$temporary/wrong-node-canary.out" 2>&1; then
  echo 'full-sync canary accepted a node ID other than the prepared JOIN identity' >&2; exit 1
fi
grep -Fq 'joining canary node ID differs from its prepared identity' "$temporary/wrong-node-canary.out"

sed 's/gonka-single-seed-fixture/other-chain/' "$temporary/full-sync-receipt.json" >"$temporary/wrong-chain-receipt.json"
if PATH="$temporary:$PATH" "$ROOT/scripts/verify-genesis-single-seed-canary.sh" \
  "$temporary/wrong-chain-receipt.json" http://127.0.0.1:26657 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$temporary/wrong-chain-canary.json" \
  >"$temporary/wrong-chain-canary.out" 2>&1; then
  echo 'full-sync canary accepted a source with a different chain ID' >&2; exit 1
fi
grep -Fq 'pinned seed status differs from declared node or chain' "$temporary/wrong-chain-canary.out"

if GDC_JOIN_LINEAGE_RECEIPT_SHA256="$full_receipt_sha" \
  "$ROOT/02-node/render-node-env.sh" --inventory "$temporary/inventory.env" --node-name mitch-demo \
  --account-public "$temporary/account.json" --seeds-file "$temporary/full-sync-seeds.txt" --secrets-dir "$temporary" \
  --state-sync-env "$temporary/full-sync.env" --bootstrap-file "$temporary/bootstrap.json" \
  --genesis-file "$genesis_file" --data-dir /srv/dai/data.generations/full-sync --output "$temporary/unmarked-full-sync.env" \
  >"$temporary/unmarked-full-sync.out" 2>&1; then
  echo 'full_sync rendered without explicit genesis-single-seed Bootstrap opt-in' >&2; exit 1
fi
grep -Fq 'requires explicit genesis-single-seed Bootstrap opt-in' "$temporary/unmarked-full-sync.out"

cp "$temporary/full-sync-receipt.json" "$temporary/full-sync-receipt-drift.json"
printf ' ' >>"$temporary/full-sync-receipt-drift.json"
sed "s|$temporary/full-sync-receipt.json|$temporary/full-sync-receipt-drift.json|" "$temporary/full-sync.env" >"$temporary/full-sync-drift.env"
if GDC_JOIN_LINEAGE_RECEIPT_SHA256="$full_receipt_sha" \
  "$ROOT/02-node/render-node-env.sh" --inventory "$temporary/inventory.env" --node-name mitch-demo \
  --account-public "$temporary/account.json" --seeds-file "$temporary/full-sync-seeds.txt" --secrets-dir "$temporary" \
  --state-sync-env "$temporary/full-sync-drift.env" --bootstrap-file "$temporary/full-sync-bootstrap.json" \
  --genesis-file "$genesis_file" --data-dir /srv/dai/data.generations/full-sync --output "$temporary/drift-full-sync.env" \
  >"$temporary/drift-full-sync.out" 2>&1; then
  echo 'full_sync rendered a lineage receipt changed after preflight' >&2; exit 1
fi
grep -Fq 'lineage receipt is missing or changed after preflight' "$temporary/drift-full-sync.out"

sed 's/^GDC_JOIN_TRUST_HEIGHT=0$/GDC_JOIN_TRUST_HEIGHT=1/' "$temporary/full-sync.env" >"$temporary/full-sync-with-trust.env"
if GDC_JOIN_LINEAGE_RECEIPT_SHA256="$full_receipt_sha" \
  "$ROOT/02-node/render-node-env.sh" --inventory "$temporary/inventory.env" --node-name mitch-demo \
  --account-public "$temporary/account.json" --seeds-file "$temporary/full-sync-seeds.txt" --secrets-dir "$temporary" \
  --state-sync-env "$temporary/full-sync-with-trust.env" --bootstrap-file "$temporary/full-sync-bootstrap.json" \
  --genesis-file "$genesis_file" --data-dir /srv/dai/data.generations/full-sync --output "$temporary/trust-full-sync.env" \
  >"$temporary/trust-full-sync.out" 2>&1; then
  echo 'full_sync accepted nonempty state-sync trust' >&2; exit 1
fi
grep -Fq 'contains state-sync trust, snapshot, or extra RPC settings' "$temporary/trust-full-sync.out"

# A normal deployment may place the gateway on a non-Genesis Host. Only that
# Host binds its proxy beyond loopback so the public edge can reach it.
grep -v '^GDC_JOIN_ROLE_INPUT=' "$temporary/inventory.env" >"$temporary/normal-inventory.env"
cat >>"$temporary/normal-inventory.env" <<'EOF'
GDC_NODE_ALIASES='seed mitch-demo'
GDC_NODE_PUBLIC_HOSTS='seed=seed.example mitch-demo=host.example.net'
GDC_NODE_P2P_PORTS='seed=5000 mitch-demo=5200'
GDC_NODE_ML_HOSTS=
GDC_GENESIS_NODE=seed
GDC_PUBLIC_EDGE_NODE=seed
GDC_GATEWAY_NODE=mitch-demo
GDC_TELEGRAM_BOT_HOST=mitch-demo
GDC_RELEASE_PROFILE=v2026.08.06
SITE_HOST=status.example.net
GRAFANA_HOST=grafana.example.net
EOF
"$ROOT/02-node/render-node-env.sh" --inventory "$temporary/normal-inventory.env" --node-name mitch-demo --account-public "$temporary/account.json" --seeds-file "$temporary/genesis-seeds.txt" --secrets-dir "$temporary" --output "$temporary/gateway-node.env" >/dev/null
grep -Fxq 'PROXY_BIND_ADDRESS=0.0.0.0' "$temporary/gateway-node.env"
printf 'keyring\n' >"$temporary/seed.keyring"
printf 'postgres\n' >"$temporary/seed.postgres"
"$ROOT/02-node/render-node-env.sh" --inventory "$temporary/normal-inventory.env" --node-name seed --account-public "$temporary/account.json" --bootstrap --secrets-dir "$temporary" --output "$temporary/genesis-node.env" >/dev/null
grep -Fxq 'SYNC_WITH_SNAPSHOTS=false' "$temporary/genesis-node.env"
grep -Fxq 'GDC_JOIN_STATESYNC_ENABLE=false' "$temporary/genesis-node.env"
"$ROOT/04-ops/edge-node/render-env.sh" --inventory "$temporary/normal-inventory.env" --node-name mitch-demo --output "$temporary/gateway-edge.env" >/dev/null
grep -Fxq 'GATEWAY_DAPI_UPSTREAM=http://127.0.0.1:8000' "$temporary/gateway-edge.env"
# A joining Host has no local gateway or Telegram role. Its participant edge
# must still render, with auxiliary routes directed to the validated seed.
"$ROOT/04-ops/edge-node/render-env.sh" --inventory "$temporary/inventory.env" --node-name mitch-demo --output "$temporary/edge.env" >/dev/null
grep -Fxq 'PUBLIC_EDGE=false' "$temporary/edge.env"
grep -Fxq 'COMPOSE_PROJECT_NAME=gdc-edge-mitch-demo' "$temporary/edge.env"
grep -Fxq 'GATEWAY_PUBLIC_HOST=one.example' "$temporary/edge.env"
grep -Fxq 'GATEWAY_DAPI_UPSTREAM=http://one.example:8000' "$temporary/edge.env"
grep -Fxq 'TELEGRAM_BOT_PUBLIC_HOST=one.example' "$temporary/edge.env"
grep -Fxq 'PUBLIC_GRAFANA_PROMETHEUS_URL=https://one.example/ops-prometheus' "$temporary/edge.env"
"$ROOT/04-ops/edge-node/render-env.sh" --inventory "$temporary/normal-inventory.env" --node-name seed --output "$temporary/public-edge.env" >/dev/null
grep -Fxq 'PUBLIC_EDGE=true' "$temporary/public-edge.env"
grep -Fxq 'COMPOSE_PROJECT_NAME=gdc-edge' "$temporary/public-edge.env"
sed -i 's/^GDC_GATEWAY_NODE=.*/GDC_GATEWAY_NODE=/; s/^GDC_PUBLIC_EDGE_NODE=.*/GDC_PUBLIC_EDGE_NODE=/; s/^TELEGRAM_BOT_HOST=.*/TELEGRAM_BOT_HOST=/' "$temporary/inventory.env"
"$ROOT/04-ops/edge-node/render-env.sh" --inventory "$temporary/inventory.env" --node-name mitch-demo --output "$temporary/edge-no-roles.env" >/dev/null
grep -Fxq 'GATEWAY_PUBLIC_HOST=one.example' "$temporary/edge-no-roles.env"
grep -Fxq 'GATEWAY_DAPI_UPSTREAM=http://one.example:8000' "$temporary/edge-no-roles.env"
grep -Fxq 'TELEGRAM_BOT_PUBLIC_HOST=one.example' "$temporary/edge-no-roles.env"
grep -Fxq 'PUBLIC_GRAFANA_PROMETHEUS_URL=https://one.example/ops-prometheus' "$temporary/edge-no-roles.env"
! grep -Rq 'JOIN_BOOTSTRAP_FORMAT\|join-bootstrap\|topology.env\|profile/genesis.env' "$ROOT/scripts/prepare-join-role-config.sh"
printf 'PASS one-file JOIN role preparation accepts arbitrary local aliases without topology import\n'
INFERENCED="$temporary/inferenced" "$ROOT/scripts/prepare-join-role-config.sh" --output "$temporary/source.env" \
  --ssh-alias mitch-demo --public-host host.example.net --bootstrap-file "$temporary/bootstrap.json" --source-rpc http://two.example:8000/chain-rpc
(
  source "$temporary/source.env"
  [[ "$GDC_JOIN_NETWORK_HOST" == two.example && "$SEED_NODE_RPC_URL" == http://two.example:8000/chain-rpc && "$SEED_API_URL" == http://two.example:8000 ]]
)
printf 'PASS explicit JOIN source also selects the membership/API role, not the first seed\n'

# Execute the generated role through load_project: a different seed must not
# change the monitoring firewall source selected by the registry handoff.
INFERENCED="$temporary/inferenced" "$ROOT/scripts/prepare-join-role-config.sh" --output "$temporary/collector.env" \
  --ssh-alias mitch-demo --public-host host.example.net --bootstrap-file "$temporary/bootstrap.json" \
  --source-rpc http://two.example:8000/chain-rpc --monitoring-registry-host collector-fixture
(
  export GDC_HOME="$temporary/collector-home" GDC_ENV="$temporary/collector.env"
  unset GDC_MONITORING_HOST GDC_JOIN_RESUME
  source "$ROOT/scripts/lib.sh"
  ssh() {
    [[ "$*" == '-G collector-fixture' ]] || return 99
    printf 'hostname collector.example\n'
  }
  getent() {
    case "$*" in
      'ahostsv4 collector.example') printf '192.0.2.44 STREAM collector.example\n' ;;
      'ahostsv4 two.example') printf '192.0.2.10 STREAM two.example\n' ;;
      *) return 99 ;;
    esac
  }
  load_project
  [[ "$MONITORING_CIDR" == 192.0.2.44/32 && "$PUBLIC_EDGE_CIDR" == 192.0.2.10/32 ]]
  grep -Fxq 'MONITORING_CIDR=192.0.2.44/32' "$INVENTORY"
  grep -Fxq 'GDC_MONITORING_DOCKER_CIDR=172.21.0.0/16' "$INVENTORY"
)
printf 'PASS generated JOIN retains independent collector firewall source\n'
GDC_MONITORING_HOST=explicit.example INFERENCED="$temporary/inferenced" \
  "$ROOT/scripts/prepare-join-role-config.sh" --output "$temporary/explicit-collector.env" \
  --ssh-alias mitch-demo --public-host host.example.net --bootstrap-file "$temporary/bootstrap.json"
grep -Fxq 'GDC_MONITORING_HOST=explicit.example' "$temporary/explicit-collector.env"
printf 'PASS explicit collector survives generated JOIN role persistence\n'

[[ "$(GDC_MONITORING_DOCKER_CIDR='' bash "$ROOT/scripts/join-monitoring-cidr.sh")" == 127.0.0.1/32 ]]
for invalid in 999.21.0.0/16 172.21.0.0/33 '172.21.0.0/16 0.0.0.0/0'; do
  if GDC_MONITORING_DOCKER_CIDR="$invalid" INFERENCED="$temporary/inferenced" \
    "$ROOT/scripts/prepare-join-role-config.sh" --output "$temporary/rejected.env" \
    --ssh-alias mitch-demo --public-host host.example.net --bootstrap-file "$temporary/bootstrap.json" \
    >"$temporary/rejected.log" 2>&1; then
    echo 'invalid monitoring CIDR was accepted' >&2
    exit 1
  fi
  [[ ! -e "$temporary/rejected.env" ]]
  grep -q '^JOIN ' "$temporary/rejected.log"
done
(
  unset GDC_MONITORING_DOCKER_CIDR
  ssh() {
    case "$*" in
      *'collector-fixture test -d /srv/dai/ops/prometheus/targets'*) return 0 ;;
      "-o BatchMode=yes -o ConnectTimeout=10 collector-fixture sudo -n docker ps --filter label=com.docker.compose.service=prometheus --format '{{.ID}}'")
        printf '%s\n' abcdef012345 ;;
      "-o BatchMode=yes -o ConnectTimeout=10 collector-fixture sudo -n docker inspect 'abcdef012345' --format '{{json .NetworkSettings.Networks}}'")
        printf '%s\n' '{"gdc-ops_default":{"IPAddress":"172.21.0.2"}}' ;;
      "-o BatchMode=yes -o ConnectTimeout=10 collector-fixture sudo -n docker network inspect 'gdc-ops_default' --format '{{json .IPAM.Config}}'")
        printf '%s\n' '[{"Subnet":"172.21.0.0/16"}]' ;;
      *) echo "unexpected SSH: $*" >&2; return 99 ;;
    esac
  }
  export -f ssh
  INFERENCED="$temporary/inferenced" "$ROOT/scripts/prepare-join-role-config.sh" \
    --output "$temporary/discovered.env" --ssh-alias mitch-demo --public-host host.example.net \
    --bootstrap-file "$temporary/bootstrap.json" --monitoring-registry-host collector-fixture
  grep -Fxq 'GDC_MONITORING_DOCKER_CIDR=172.21.0.0/16' "$temporary/discovered.env"
  ssh() {
    case "$*" in
      *'docker ps '*) printf '%s\n' abcdef012345 ;;
      *"docker inspect 'abcdef012345'"*) printf '%s\n' '{"first":{},"second":{}}' ;;
      *) return 99 ;;
    esac
  }
  export -f ssh
  if bash "$ROOT/scripts/join-monitoring-cidr.sh" collector-fixture >"$temporary/ambiguous.log" 2>&1; then exit 1; fi
  grep -q 'requires one Prometheus Docker network' "$temporary/ambiguous.log"
  ssh() { return 255; }
  export -f ssh
  if bash "$ROOT/scripts/join-monitoring-cidr.sh" collector-fixture >"$temporary/unreachable.log" 2>&1; then exit 1; fi
  grep -q 'cannot inspect Prometheus' "$temporary/unreachable.log"
)
printf 'PASS monitoring configuration fails early and discovers only an unambiguous collector subnet\n'
grep -Fq 'staged_genesis_sha="$(genesis_sha256 "$GENESIS/genesis.json")"' "$ROOT/scripts/phase-join.sh"
! grep -Fq 'raw_genesis_sha="$(sha256sum "$GENESIS/genesis.json")' "$ROOT/scripts/phase-join.sh"
grep -Fq 'genesis_sha256 "$GENESIS_FILE"' "$ROOT/02-node/render-node-env.sh"
grep -Fq 'actual_distribution_sha="$(sha256sum "$GENESIS_FILE"' "$ROOT/02-node/render-node-env.sh"
grep -Fq 'distribution_sha256:$distribution' "$ROOT/02-node/render-node-env.sh"
printf 'PASS single-seed JOIN renderer separately binds raw distribution bytes and canonical Genesis identity\n'
