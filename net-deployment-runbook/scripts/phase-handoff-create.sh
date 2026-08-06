#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
assert_baseline_release
NODE="$(node_name "${1:-}")"
[[ "$NODE" != gdc-node0 && "$NODE" != gdc-node4 ]] || die 'v2 handoff supports independently operated GPU Network Nodes gdc-node1 through gdc-node3'
[[ -s "$GENESIS/genesis.json" && -s "$GENESIS/genesis-seeds.txt" ]] || die 'run genesis before creating a node handoff'
[[ ! -e "$STATE/joined/$NODE" ]] || die "$NODE is already coordinated for handoff; reset it before handoff"
PUBLIC_URL="$(node_url "$NODE")"
participants="$(curl --connect-timeout 5 --max-time 10 -fsS \
  "https://$NODE0_PUBLIC_HOST/chain-api/productscience/inference/inference/participant")"
jq -e --arg url "$PUBLIC_URL" \
  '[.participant[]? | select(.inference_url == $url)] | length == 0' \
  <<<"$participants" >/dev/null || die "$PUBLIC_URL is already registered; restore that operator's keys and runtime instead of creating a second validator identity"

OUT="${GDC_HANDOFF_OUTPUT:-$ROOT/artifacts/operator-handoffs/$NODE}"
[[ "$OUT" == "$ROOT/artifacts/"* ]] || die 'handoff output must stay under artifacts/'
rm -rf "$OUT"
install -d -m 0700 "$OUT/genesis"
printf '%s\n' "$NODE" >"$OUT/node"
printf '%s\n' "$CHAIN_ID" >"$OUT/chain-id"
install -m 0600 "$GENESIS/genesis.json" "$OUT/genesis/genesis.json"
install -m 0600 "$GENESIS/genesis.sha256" "$OUT/genesis/genesis.sha256"
install -m 0600 "$GENESIS/genesis-seeds.txt" "$OUT/genesis/genesis-seeds.txt"
cat >"$OUT/operator.env" <<EOF
# Safe topology parameters for the operator. Add ACME_EMAIL locally.
GDC_NODE4_ML_ENDPOINT=$NODE4_ML_ENDPOINT
# The coordinator may exclude this not-yet-operated host from its own
# rehearsal. The receiving operator must be able to join the handed-off node.
GDC_SKIP_HOSTS=
EOF
chmod 600 "$OUT/operator.env"
(cd "$OUT" && find . -type f ! -name manifest.sha256 -print0 | LC_ALL=C sort -z | xargs -0 sha256sum >manifest.sha256)
chmod 600 "$OUT/manifest.sha256"
cat <<EOF
READY handoff bundle: $OUT
The bundle contains only public Genesis, seed and topology data. It contains no
validator, account, gateway, or Genesis-operator secret.
The operator adds ACME_EMAIL to operator.env and runs:
  GDC_ENV=$OUT/operator.env GDC_NODE_HANDOFF_DIR=<received-bundle> ./gdc.sh --release testnet-0.2.14 join $NODE
EOF
