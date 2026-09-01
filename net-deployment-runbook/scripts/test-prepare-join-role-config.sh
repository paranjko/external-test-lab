#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; temporary="$(mktemp -d)"; trap 'rm -rf -- "$temporary"' EXIT
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
DATA_ROOT=/srv/dai
GENESIS_INSTALL_PATH=/srv/dai/shared/genesis.json
HF_CACHE_ROOT=/srv/dai/hf-cache
GENESIS_P2P_PORT=5000
EOF
# Render against the actual JOIN role input: the local role configuration, not
# any retained inventory, is the authority for the joining host's public name.
"$ROOT/02-node/render-node-env.sh" --inventory "$temporary/inventory.env" --node-name mitch-demo --account-public "$temporary/account.json" --bootstrap --secrets-dir "$temporary" --output "$temporary/node.env" >/dev/null
grep -Fxq 'PUBLIC_HOST=host.example.net' "$temporary/node.env"
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
"$ROOT/02-node/render-node-env.sh" --inventory "$temporary/inventory.env" --node-name mitch-demo --account-public "$temporary/account.json" --seeds-file "$temporary/genesis-seeds.txt" --secrets-dir "$temporary" --state-sync-env "$temporary/lineage.env" --data-dir /srv/dai/data/mitch-demo.generations/test-run --output "$temporary/node-state-sync.env" >/dev/null
grep -Fxq 'DATA_DIR=/srv/dai/data/mitch-demo.generations/test-run' "$temporary/node-state-sync.env"
# A joining Host has no local gateway or Telegram role. Its participant edge
# must still render, with auxiliary routes directed to the validated seed.
"$ROOT/04-ops/edge-node/render-env.sh" --inventory "$temporary/inventory.env" --node-name mitch-demo --output "$temporary/edge.env" >/dev/null
grep -Fxq 'PUBLIC_EDGE=false' "$temporary/edge.env"
grep -Fxq 'GATEWAY_PUBLIC_HOST=one.example' "$temporary/edge.env"
grep -Fxq 'TELEGRAM_BOT_PUBLIC_HOST=one.example' "$temporary/edge.env"
grep -Fxq 'PUBLIC_GRAFANA_PROMETHEUS_URL=https://one.example/ops-prometheus' "$temporary/edge.env"
sed -i 's/^GDC_GATEWAY_NODE=.*/GDC_GATEWAY_NODE=/; s/^GDC_PUBLIC_EDGE_NODE=.*/GDC_PUBLIC_EDGE_NODE=/; s/^TELEGRAM_BOT_HOST=.*/TELEGRAM_BOT_HOST=/' "$temporary/inventory.env"
"$ROOT/04-ops/edge-node/render-env.sh" --inventory "$temporary/inventory.env" --node-name mitch-demo --output "$temporary/edge-no-roles.env" >/dev/null
grep -Fxq 'GATEWAY_PUBLIC_HOST=one.example' "$temporary/edge-no-roles.env"
grep -Fxq 'TELEGRAM_BOT_PUBLIC_HOST=one.example' "$temporary/edge-no-roles.env"
grep -Fxq 'PUBLIC_GRAFANA_PROMETHEUS_URL=https://one.example/ops-prometheus' "$temporary/edge-no-roles.env"
! grep -Rq 'JOIN_BOOTSTRAP_FORMAT\|join-bootstrap\|topology.env\|profile/genesis.env' "$ROOT/scripts/prepare-join-role-config.sh"
printf 'PASS one-file JOIN role preparation accepts arbitrary local aliases without topology import\n'
