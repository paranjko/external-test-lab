#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

action="${1:-}"
node="${2:-}"
[[ "$action" =~ ^(apply|status|verify)$ && -n "$node" ]] || die 'expected bridge observer apply, status, or verify and an SSH alias'
topology_contains_node "$node" || die "bridge observer host is not in GDC_NODE_ALIASES: $node"

contract="${GDC_SEPOLIA_CONTRACT:-}"
[[ "$contract" =~ ^0x[0-9A-Fa-f]{40}$ ]] || die 'GDC_SEPOLIA_CONTRACT must be the authorized Sepolia contract address'

RUN="$GDC_HOME/runs/$(date -u +%Y%m%dT%H%M%SZ)-bridge-observer-$action-$node"
mkdir -p "$RUN"
install_evidence_exit_trap 'Sepolia bridge observer'
record_phase_profile "bridge-observer-$action"

capture_canonical_genesis "https://$GENESIS_PUBLIC_HOST/chain-rpc/genesis" "$RUN/genesis.json" \
  || die 'could not capture the current Gonka Genesis'
genesis_sha256_value="$(genesis_sha256 "$RUN/genesis.json")"
{
  profile_summary
  printf 'chain_id=%s\n' "$CHAIN_ID"
  printf 'genesis_sha256=%s\n' "$genesis_sha256_value"
  printf 'observer_host=%s\n' "$node"
  printf 'sepolia_contract=%s\n' "$contract"
} >"$RUN/context.env"

verify_registration() {
  ssh -T "$node" "curl -fsS 'http://127.0.0.1:9000/v1/bridge/addresses?chain=sepolia'" \
    >"$RUN/bridge-addresses.json"
  jq -e --arg contract "$contract" \
    '.chain_name == "sepolia" and any(.addresses[]?; ascii_downcase == ($contract | ascii_downcase))' \
    "$RUN/bridge-addresses.json" >/dev/null \
    || die 'the Host does not observe the authorized Sepolia contract in Gonka governance state'
}

verify_runtime() {
  step "Verify the Sepolia observer on $node"
  ssh -T "$node" "set -Eeuo pipefail
    cd /srv/dai/deploy/$node
    docker compose --env-file .env --env-file .bridge.env -f compose.yaml -f compose.bridge-sepolia.yaml ps --status running --services \
      | grep -qx bridge
    docker compose --env-file .env --env-file .bridge.env -f compose.yaml -f compose.bridge-sepolia.yaml logs --no-color --tail=300 bridge" \
    >"$RUN/bridge.log"
  grep -Eqi 'Running on Sepolia testnet' "$RUN/bridge.log" || die 'bridge did not confirm Sepolia mode'
  verify_registration
  ssh -T "$node" "curl -fsS http://127.0.0.1:9000/v1/bridge/status" >"$RUN/bridge-status.json"
  jq -e '.pendingBlocksCount >= 0 and .pendingReceiptsCount >= 0 and (.blockCountByNumber | type) == "object"' \
    "$RUN/bridge-status.json" >/dev/null || die 'Host bridge queue status is invalid'
}

if [[ "$action" == apply ]]; then
  beacon_url="${GDC_SEPOLIA_BEACON_STATE_URL:-}"
  [[ "$beacon_url" =~ ^https:// ]] || die 'GDC_SEPOLIA_BEACON_STATE_URL must be an authorized HTTPS checkpoint endpoint'
  [[ "$BRIDGE_IMAGE" == *@sha256:* ]] || die 'bridge image must be pinned by digest'
  [[ -s "$SECRETS/bridge.jwt" ]] || die 'bridge JWT is absent; initialize operator secrets first'

  step 'Preflight the configured Sepolia checkpoint endpoint'
  curl -fsS --max-time "${GDC_BEACON_PREFLIGHT_TIMEOUT_SECONDS:-20}" "$beacon_url" \
    >"$RUN/beacon-checkpoint.json"
  jq -e . "$RUN/beacon-checkpoint.json" >/dev/null || die 'configured checkpoint endpoint did not return JSON'

  step "Measure bridge headroom on $node"
  ssh "$node" 'free -b; df -B1 /srv/dai' >"$RUN/headroom.txt"
  available_ram="$(awk '/MemAvailable:/ {print $2*1024}' "$RUN/headroom.txt" | head -n1)"
  available_disk="$(awk '$NF == "/srv/dai" {print $4}' "$RUN/headroom.txt")"
  min_ram="${GDC_BRIDGE_MIN_AVAILABLE_RAM_BYTES:-8589934592}"
  min_disk="${GDC_BRIDGE_MIN_AVAILABLE_DISK_BYTES:-107374182400}"
  [[ "$available_ram" =~ ^[0-9]+$ && "$available_disk" =~ ^[0-9]+$ ]] || die 'could not parse bridge host headroom'
  (( available_ram >= min_ram && available_disk >= min_disk )) \
    || die "bridge host lacks headroom (RAM=$available_ram disk=$available_disk)"

  step "Install the digest-pinned Sepolia observer on $node"
  remote="/tmp/gdc-bridge-$$"
  bridge_env="$RUN/bridge.env"
  write_env "$bridge_env" "BRIDGE_IMAGE=$BRIDGE_IMAGE" "GDC_SEPOLIA_BEACON_STATE_URL=$beacon_url"
  ssh "$node" "rm -rf '$remote' && mkdir -p '$remote'"
  scp -q "$ROOT/02-node/compose.bridge-sepolia.yaml" "$node:$remote/compose.bridge-sepolia.yaml"
  scp -q "$bridge_env" "$node:$remote/bridge.env"
  scp -q "$SECRETS/bridge.jwt" "$node:$remote/bridge.jwt"
  ssh -T "$node" "set -Eeuo pipefail
    dest=/srv/dai/deploy/$node
    sudo install -m 0644 '$remote/compose.bridge-sepolia.yaml' \"\$dest/compose.bridge-sepolia.yaml\"
    sudo install -m 0600 '$remote/bridge.env' \"\$dest/.bridge.env\"
    sudo install -d -m 0700 /srv/dai/$node/bridge/{geth,prysm,jwt,logs,persistent-db}
    sudo install -m 0600 '$remote/bridge.jwt' /srv/dai/$node/bridge/jwt/jwt.hex
    rm -rf '$remote'
    cd \"\$dest\"
    docker compose --env-file .env --env-file .bridge.env -f compose.yaml -f compose.bridge-sepolia.yaml pull bridge
    docker compose --env-file .env --env-file .bridge.env -f compose.yaml -f compose.bridge-sepolia.yaml up -d bridge"
fi

verify_runtime

if [[ "$action" == verify ]]; then
  step 'Wait for a finalized Sepolia block cursor from this observer'
  deadline=$((SECONDS + ${GDC_BRIDGE_OBSERVER_VERIFY_TIMEOUT_SECONDS:-600}))
  while (( SECONDS < deadline )); do
    if ssh -T "$node" "curl -fsS 'http://127.0.0.1:9000/v1/bridge/block/latest?chain=sepolia'" \
      >"$RUN/latest-block.json" \
      && jq -e '.chainId == "sepolia" and (.blockNumber | tonumber) > 0' "$RUN/latest-block.json" >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done
  jq -e '.chainId == "sepolia" and (.blockNumber | tonumber) > 0' "$RUN/latest-block.json" >/dev/null \
    || die 'observer did not submit a finalized Sepolia block before the verification timeout'
fi

cat >"$RUN/verdict.md" <<EOF
# Sepolia bridge observer: PASS

Host $node runs the digest-pinned Sepolia observer, reads the governance-registered
contract $contract and exposes a valid local bridge queue. This verdict does not
claim an ERC-20 deposit, wrapped-token mint, withdrawal or end-to-end paid inference.
EOF
printf 'PASS bridge observer evidence: %s\n' "$RUN"
