#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
assert_baseline_release
NODE="$(node_name "${1:-}")"
[[ -s "$GENESIS/genesis.json" && -s "$GENESIS/genesis-seeds.txt" ]] || die 'run genesis before creating a node handoff'
[[ ! -e "$STATE/joined/$NODE" ]] || die "$NODE is already coordinated for handoff; reset it before handoff"
PUBLIC_URL="$(node_url "$NODE")"
participants="$(curl --connect-timeout 5 --max-time 10 -fsS \
  "https://$GENESIS_PUBLIC_HOST/chain-api/productscience/inference/inference/participant")"
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
{
  printf '%s\n' '# Safe topology parameters for the operator. Add ACME_EMAIL locally.'
  printf 'GDC_NODE_ALIASES=%q\n' "$GDC_NODE_ALIASES"
  printf 'GDC_NODE_PUBLIC_HOSTS=%q\n' "$GDC_NODE_PUBLIC_HOSTS"
  printf 'GDC_NODE_GPU_PROFILES=%q\n' "$GDC_NODE_GPU_PROFILES"
  printf 'GDC_NODE_P2P_PORTS=%q\n' "$GDC_NODE_P2P_PORTS"
  printf 'GDC_NODE_ML_HOSTS=%q\n' "${GDC_NODE_ML_HOSTS:-}"
  printf 'GDC_GENESIS_NODE=%q\n' "$GENESIS_NODE"
  printf 'GDC_PUBLIC_EDGE_NODE=%q\n' "$PUBLIC_EDGE_NODE"
  printf 'GDC_GATEWAY_NODE=%q\n' "$GATEWAY_NODE"
  printf 'GDC_TELEGRAM_BOT_HOST=%q\n' "$TELEGRAM_BOT_HOST"
  printf '%s\n' '# The receiving operator must not inherit the coordinator skip list.'
  printf 'GDC_SKIP_HOSTS=\n'
} >"$OUT/operator.env"
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
