#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
assert_baseline_release
NODE="$(node_name "${1:-}")"
[[ "$NODE" != gdc-node0 && "$NODE" != gdc-node4 ]] || die 'v1 handoff supports independently operated GPU Network Nodes node1 through node3'
[[ -s "$GENESIS/genesis.json" && -s "$GENESIS/genesis-seeds.txt" ]] || die 'run genesis before creating a node handoff'
[[ -s "$ACCOUNTS/$NODE-cold.json" ]] || die "missing public cold account for $NODE; run identities first"
[[ -s "$SECRETS/$NODE.keyring" && -s "$SECRETS/$NODE.postgres" ]] || die "missing target-only secrets for $NODE"
[[ ! -e "$STATE/joined/$NODE" ]] || die "$NODE is already coordinated for handoff; reset it before handoff"

OUT="${GDC_HANDOFF_OUTPUT:-$ROOT/artifacts/operator-handoffs/$NODE}"
[[ "$OUT" == "$ROOT/artifacts/"* ]] || die 'handoff output must stay under artifacts/'
rm -rf "$OUT"
install -d -m 0700 "$OUT/secrets" "$OUT/accounts" "$OUT/genesis"
printf '%s\n' "$NODE" >"$OUT/node"
printf '%s\n' "$CHAIN_ID" >"$OUT/chain-id"
install -m 0600 "$SECRETS/$NODE.keyring" "$OUT/secrets/$NODE.keyring"
install -m 0600 "$SECRETS/$NODE.postgres" "$OUT/secrets/$NODE.postgres"
install -m 0600 "$ACCOUNTS/$NODE-cold.json" "$OUT/accounts/$NODE-cold.json"
install -m 0600 "$GENESIS/genesis.json" "$OUT/genesis/genesis.json"
install -m 0600 "$GENESIS/genesis.sha256" "$OUT/genesis/genesis.sha256"
install -m 0600 "$GENESIS/genesis-seeds.txt" "$OUT/genesis/genesis-seeds.txt"
cat >"$OUT/operator.env" <<EOF
# Safe topology parameters for the operator. Add ACME_EMAIL locally.
GDC_NODE4_ML_ENDPOINT=$NODE4_ML_ENDPOINT
EOF
chmod 600 "$OUT/operator.env"
(cd "$OUT" && find . -type f ! -name manifest.sha256 -print0 | LC_ALL=C sort -z | xargs -0 sha256sum >manifest.sha256)
chmod 600 "$OUT/manifest.sha256"
cat <<EOF
READY handoff bundle: $OUT
Transfer it through an encrypted out-of-band channel. It contains only $NODE secrets, Genesis and public topology; it does not contain the coordinator operator key.
The operator must add ACME_EMAIL to operator.env, qualify only $NODE, then run:
  GDC_ENV=$OUT/operator.env GDC_NODE_HANDOFF_DIR=<received-bundle> ./gdc.sh join ${NODE#gdc-}
EOF
