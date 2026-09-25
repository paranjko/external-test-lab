#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$ROOT/.data/public-preview-inventory-tests"
mkdir -p "$tmp_root"
tmp="$(mktemp -d "$tmp_root/run.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

cat >"$tmp/bootstrap.json" <<'EOF'
{"chain_id":"gonka-devnet-community","seeds":[{"rpc":"https://node0.gonka-dev.net/chain-rpc","p2p":"tcp://node0.gonka-dev.net:5000"},{"rpc":"https://node4.gonka-dev.net/chain-rpc","p2p":"tcp://node4.gonka-dev.net:5000"}],"brokers":[{"api_urls":["https://api.gonka-dev.net"]}]}
EOF
cat >"$tmp/participants.json" <<'EOF'
{"participant":[{"address":"gonka1one","status":"ACTIVE","inference_url":"https://node7.gonka-dev.net"},{"address":"gonka1two","status":"ACTIVE","inference_url":"https://node8.gonka-dev.net"}]}
EOF
mkdir "$tmp/net-info"
cat >"$tmp/net-info/node0.gonka-dev.net.json" <<'EOF'
{"result":{"peers":[{"node_info":{"listen_addr":"tcp://node5.gonka-dev.net:5000"}},{"node_info":{"listen_addr":"tcp://node4.gonka-dev.net:5000"}}]}}
EOF
cat >"$tmp/net-info/node4.gonka-dev.net.json" <<'EOF'
{"result":{"peers":[{"node_info":{"listen_addr":"tcp://node8.gonka-dev.net:5000"}},{"node_info":{"listen_addr":"tcp://node0.gonka-dev.net:5000"}}]}}
EOF

"$ROOT/scripts/prepare-public-preview-inventory.sh" --output "$tmp/inventory.env" --bootstrap-file "$tmp/bootstrap.json" --net-info-dir "$tmp/net-info" --participants-file "$tmp/participants.json" --no-geo
(
  # shellcheck disable=SC1090
  source "$tmp/inventory.env"
  [[ "$GDC_NODE_ALIASES" == 'node0 node4 node5 node7 node8' ]]
  [[ "$GDC_NODE_PUBLIC_HOSTS" == 'node0=node0.gonka-dev.net node4=node4.gonka-dev.net node5=node5.gonka-dev.net node7=node7.gonka-dev.net node8=node8.gonka-dev.net' ]]
)
jq -e '.gateway_node == "node4" and .participant_source == "file:participants.json" and .nodes == ["node0", "node4", "node5", "node7", "node8"] and (.bootstrap_sha256 | test("^[0-9a-f]{64}$"))' "$tmp/inventory.env.receipt.json" >/dev/null

rm "$tmp/net-info/node4.gonka-dev.net.json"
# Fixture mode is intentionally strict: a missing fixture is a test setup
# error. Live mode retains a failing seed itself and records its observation.
if "$ROOT/scripts/prepare-public-preview-inventory.sh" --output "$tmp/missing.env" --bootstrap-file "$tmp/bootstrap.json" --net-info-dir "$tmp/net-info" --participants-file "$tmp/participants.json" --no-geo; then
  echo 'missing net_info fixture was accepted' >&2
  exit 1
fi
cat >"$tmp/net-info/node4.gonka-dev.net.json" <<'EOF'
{"result":{"peers":[{"node_info":{"listen_addr":"tcp://node8.gonka-dev.net:5000"}},{"node_info":{"listen_addr":"tcp://node0.gonka-dev.net:5000"}}]}}
EOF

sed 's,node5.gonka-dev.net:5000,evil.example.test:5000,' "$tmp/net-info/node0.gonka-dev.net.json" >"$tmp/net-info/node0.gonka-dev.net.invalid.json"
mv "$tmp/net-info/node0.gonka-dev.net.invalid.json" "$tmp/net-info/node0.gonka-dev.net.json"
if "$ROOT/scripts/prepare-public-preview-inventory.sh" --output "$tmp/invalid.env" --bootstrap-file "$tmp/bootstrap.json" --net-info-dir "$tmp/net-info" --participants-file "$tmp/participants.json" --no-geo; then
  echo 'unsafe peer was accepted' >&2
  exit 1
fi

printf 'PASS public preview inventory derives only canonical public nodes\n'
