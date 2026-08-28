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
! grep -Rq 'JOIN_BOOTSTRAP_FORMAT\|join-bootstrap\|topology.env\|profile/genesis.env' "$ROOT/scripts/prepare-join-role-config.sh"
printf 'PASS one-file JOIN role preparation accepts arbitrary local aliases without topology import\n'
