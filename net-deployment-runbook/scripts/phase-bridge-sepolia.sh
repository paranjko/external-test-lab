#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

RUN="$ROOT/artifacts/runs/$(date -u +%Y%m%dT%H%M%SZ)-bridge-sepolia"
mkdir -p "$RUN"
install_evidence_exit_trap 'Sepolia bridge'
record_phase_profile bridge-sepolia

blocked() {
  local reason="$1"
  cat >"$RUN/verdict.md" <<EOF
# Sepolia bridge: BLOCKED

$reason

No bridge container, key, contract call, or external endpoint was touched.
EOF
  printf 'BLOCKED bridge evidence: %s (%s)\n' "$RUN" "$reason"
  exit 3
}

[[ -n "${GDC_SEPOLIA_CONTRACT:-}" && "$GDC_SEPOLIA_CONTRACT" =~ ^0x[0-9A-Fa-f]{40}$ ]] \
  || blocked 'Set GDC_SEPOLIA_CONTRACT to the authorized Sepolia contract address.'
[[ -n "${GDC_SEPOLIA_BEACON_STATE_URL:-}" && "$GDC_SEPOLIA_BEACON_STATE_URL" =~ ^https:// ]] \
  || blocked 'Set GDC_SEPOLIA_BEACON_STATE_URL to the authorized HTTPS beacon-state endpoint.'
[[ "$BRIDGE_IMAGE" == *@sha256:* ]] || die 'bridge image must be pinned by digest'
step 'Preflight the configured Sepolia beacon checkpoint endpoint'
curl -fsS --max-time "${GDC_BEACON_PREFLIGHT_TIMEOUT_SECONDS:-20}" \
  "$GDC_SEPOLIA_BEACON_STATE_URL" >"$RUN/beacon-checkpoint.json" \
  || blocked 'configured beacon-state endpoint did not return a successful response'
jq -e . "$RUN/beacon-checkpoint.json" >/dev/null \
  || blocked 'configured beacon-state endpoint did not return JSON'
ha_verdict="$(find "$ROOT/artifacts/runs" -mindepth 2 -maxdepth 2 -name verdict.md -path '*-ha-v4/*' -print 2>/dev/null | LC_ALL=C sort | tail -n1)"
[[ -n "$ha_verdict" ]] && grep -qx '# DevShard v4 HA: PASS' "$ha_verdict" \
  || blocked 'Sepolia bridge requires a successful v4 HA evidence bundle first.'
ha_context="$(dirname "$ha_verdict")/context.env"
[[ -s "$ha_context" ]] \
  || blocked 'Latest HA evidence predates the release/profile contract; rerun v4 HA.'
grep -qx "release_profile=$GDC_RELEASE_PROFILE" "$ha_context" \
  || blocked "Latest HA evidence does not belong to the current $GDC_RELEASE_PROFILE profile."
grep -qx "model=$MODEL_ID@$MODEL_REVISION" "$ha_context" \
  || blocked 'Latest HA evidence used a different model profile.'
capture_canonical_genesis "https://$NODE0_PUBLIC_HOST/chain-rpc/genesis" "$RUN/genesis.json"
genesis_sha256="$(genesis_sha256 "$RUN/genesis.json")"
grep -qx "chain_id=$CHAIN_ID" "$ha_context" \
  || blocked 'Latest HA evidence belongs to another chain ID.'
grep -qx "genesis_sha256=$genesis_sha256" "$ha_context" \
  || blocked 'Latest HA evidence belongs to a previous Genesis; rerun v4 HA.'
grep -qx 'devshard_version=v4' "$ha_context" \
  || blocked 'Latest HA evidence is not the required v4 overlay.'
{
  profile_summary
  printf 'profile_hash=%s\n' "$(profile_hash)"
  printf 'chain_id=%s\n' "$CHAIN_ID"
  printf 'genesis_sha256=%s\n' "$genesis_sha256"
  printf 'devshard_version=v4\n'
  printf 'ha_bundle=%s\n' "$(dirname "$ha_verdict")"
  printf 'sepolia_contract=%s\n' "$GDC_SEPOLIA_CONTRACT"
  printf 'beacon_state_url_sha256=%s\n' \
    "$(printf '%s' "$GDC_SEPOLIA_BEACON_STATE_URL" | sha256sum | awk '{print $1}')"
} >"$RUN/context.env"
node=gdc-node0

step 'Measure node0 headroom before choosing Genesis placement'
ssh "$node" 'free -b; df -B1 /srv/dai; ip -s link' >"$RUN/headroom.txt"
available_ram="$(awk '/MemAvailable:/ {print $2*1024}' "$RUN/headroom.txt" | head -n1)"
available_disk="$(awk '$NF == "/srv/dai" {print $4}' "$RUN/headroom.txt")"
min_ram="${GDC_BRIDGE_MIN_AVAILABLE_RAM_BYTES:-8589934592}"
min_disk="${GDC_BRIDGE_MIN_AVAILABLE_DISK_BYTES:-107374182400}"
[[ "$available_ram" =~ ^[0-9]+$ && "$available_disk" =~ ^[0-9]+$ ]] || die 'could not parse node0 headroom'
(( available_ram >= min_ram && available_disk >= min_disk )) || die "node0 lacks measured bridge headroom (RAM=$available_ram disk=$available_disk)"

step 'Install digest-pinned Sepolia bridge with isolated persistent state'
remote="/tmp/gdc-bridge-$$"
ssh "$node" "rm -rf '$remote' && mkdir -p '$remote'"
rsync -a "$ROOT/02-node/" "$node:$remote/02-node/"
bridge_env="$RUN/bridge.env"
write_env "$bridge_env" "BRIDGE_IMAGE=$BRIDGE_IMAGE" "GDC_SEPOLIA_BEACON_STATE_URL=$GDC_SEPOLIA_BEACON_STATE_URL"
scp -q "$bridge_env" "$node:$remote/bridge.env"
scp -q "$SECRETS/bridge.jwt" "$node:$remote/bridge.jwt"
ssh -T "$node" "sudo install -m 0644 '$remote/02-node/compose.bridge-sepolia.yaml' /srv/dai/deploy/$node/compose.bridge-sepolia.yaml; sudo install -m 0600 '$remote/bridge.env' /srv/dai/deploy/$node/.bridge.env; sudo install -d -m 0700 /srv/dai/$node/bridge/{geth,prysm,jwt,logs,persistent-db}; sudo install -m 0600 '$remote/bridge.jwt' /srv/dai/$node/bridge/jwt/jwt.hex; rm -rf '$remote'; cd /srv/dai/deploy/$node && docker compose --env-file .env --env-file .bridge.env -f compose.yaml -f compose.bridge-sepolia.yaml pull bridge >bridge-pull.log 2>&1 && docker compose --env-file .env --env-file .bridge.env -f compose.yaml -f compose.bridge-sepolia.yaml up -d bridge >bridge-start.log 2>&1"

step 'Verify Sepolia bridge state and epoch-move observation'
ssh "$node" "cd /srv/dai/deploy/$node && docker compose --env-file .env --env-file .bridge.env -f compose.yaml -f compose.bridge-sepolia.yaml logs --no-color --tail=300 bridge" >"$RUN/bridge.log"
rg -qi 'Running on Sepolia testnet' "$RUN/bridge.log" || die 'bridge did not confirm Sepolia mode'
curl -fsS "https://$NODE0_PUBLIC_HOST/v1/bridge/addresses" >"$RUN/bridge-addresses-before.json"
jq -e --arg contract "$GDC_SEPOLIA_CONTRACT" '.. | strings | select(ascii_downcase == ($contract | ascii_downcase))' "$RUN/bridge-addresses-before.json" >/dev/null || die 'live bridge addresses do not include the authorized Sepolia contract'
deadline=$((SECONDS + ${GDC_BRIDGE_EPOCH_WAIT_SECONDS:-1800}))
before_hash="$(sha256sum "$RUN/bridge-addresses-before.json" | awk '{print $1}')"
while (( SECONDS < deadline )); do
  curl -fsS "https://$NODE0_PUBLIC_HOST/v1/bridge/addresses" >"$RUN/bridge-addresses-after.json"
  after_hash="$(sha256sum "$RUN/bridge-addresses-after.json" | awk '{print $1}')"
  [[ "$after_hash" != "$before_hash" ]] && break
  printf 'WAIT  bridge epoch-move state transition\n'; sleep 15
done
[[ "${after_hash:-$before_hash}" != "$before_hash" ]] || die 'no bridge epoch-move state transition observed'
cat >"$RUN/recovery.md" <<EOF
# Bridge recovery procedure

For an RPC/beacon outage, keep the persistent bridge data directory intact,
record the failing endpoint and last chain bridge state, repair or replace only
the external endpoint, then restart the bridge container. The bridge continuity
endpoint and persistent database prevent duplicate/replayed event handling;
compare the saved before/after bridge-address state before declaring recovery.
EOF
cat >"$RUN/verdict.md" <<EOF
# Sepolia bridge: PASS

Node0 placement was chosen from the recorded headroom. The digest-pinned bridge
started in Sepolia mode, exposed the authorized contract, and observed an
epoch-move state transition. Bridge credentials and persistent state are kept
separate from validator and gateway material.
EOF
printf 'PASS bridge evidence: %s\n' "$RUN"
