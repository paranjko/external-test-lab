#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
assert_baseline_release
NODE="$(node_name "${1:-}")"
REQUEST="${2:-}"
[[ -s "$REQUEST" ]] || die "missing activation request: $REQUEST"
[[ -s "$SECRETS/operator.keyring" ]] || die 'coordinator operator key is required for activation'
jq -e --arg node "$NODE" --arg chain "$CHAIN_ID" \
  '.schema == "gonka-devnet-community-node-handoff-v1" and .node == $node and .chain_id == $chain and (.cold_address | type == "string") and (.identity.node_name == $node)' \
  "$REQUEST" >/dev/null || die 'activation request has an unexpected schema, node or chain ID'
ADDRESS="$(jq -r .cold_address "$REQUEST")"
EXPECTED="$(jq -r .address "$ACCOUNTS/$NODE-cold.json")"
[[ "$ADDRESS" == "$EXPECTED" ]] || die 'activation request cold address does not match coordinator-created account'
IDENTITY="$STATE/handoff-identities/$NODE.json"
install -d -m 0700 "$(dirname "$IDENTITY")"
jq '.identity' "$REQUEST" >"$IDENTITY"
chmod 600 "$IDENTITY"
step "Confirm $NODE registration on chain"
"$ROOT/03-join/wait-registered.sh" "https://$NODE0_PUBLIC_HOST" "$ADDRESS"
step "Fund $NODE and grant ML operational permissions"
"$ROOT/03-join/fund-account.sh" "$ACCOUNTS/$NODE-cold.json" "$INVENTORY"
"$ROOT/03-join/grant-ml-ops.sh" "$NODE" "$IDENTITY" "$INVENTORY"
step "Wait until $NODE is ACTIVE"
"$ROOT/03-join/wait-active.sh" "https://$NODE0_PUBLIC_HOST" "$ADDRESS"
mkdir -p "$STATE/joined"
touch "$STATE/joined/$NODE"
printf '\n%s independently joined and activated successfully.\n' "$NODE"
