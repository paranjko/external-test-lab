#!/usr/bin/env bash
set -Eeuo pipefail
usage(){ echo "Usage: $0 --env .env --output ssh-alias.json --mnemonic-output ssh-alias-warm.mnemonic" >&2; }
ENV_FILE=""; OUTPUT=""; MNEMONIC_OUTPUT=""
while (($#)); do case "$1" in --env) ENV_FILE="$2"; shift 2;; --output) OUTPUT="$2"; shift 2;; --mnemonic-output) MNEMONIC_OUTPUT="$2"; shift 2;; *) usage; exit 2;; esac; done
[[ -s "$ENV_FILE" && -n "$OUTPUT" && -n "$MNEMONIC_OUTPUT" ]] || { usage; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '{}\n' > "$TMP/genesis.json"
printf '[]\n' > "$TMP/node-config.json"
# Shell variables override --env-file values, allowing identity init before final genesis exists.
export GENESIS_FILE="$TMP/genesis.json" NODE_CONFIG_FILE="$TMP/node-config.json" INIT_ONLY=true
compose=(docker compose --env-file "$ENV_FILE" -f "$HERE/compose.yaml")
"${compose[@]}" up -d tmkms
"${compose[@]}" run --rm --no-deps -e INIT_ONLY=true node >/dev/null

# Create or reuse the warm key in the persistent /root/.inference keyring.
if ! "${compose[@]}" run --rm --no-deps -T --entrypoint /bin/sh api -c \
  'printf "%s\n" "$KEYRING_PASSWORD" | inferenced keys show "$KEY_NAME" --keyring-backend file -a' >/dev/null 2>&1; then
  key_output="$TMP/warm-key.out"
  "${compose[@]}" run --rm --no-deps -T --entrypoint /bin/sh api -c \
    'printf "%s\n%s\n" "$KEYRING_PASSWORD" "$KEYRING_PASSWORD" | inferenced keys add "$KEY_NAME" --keyring-backend file' \
    >"$key_output" 2>&1
  mapfile -t phrases < <(awk 'NF == 24 {valid=1; for (i=1; i<=NF; i++) if ($i !~ /^[a-z]+$/) valid=0; if (valid) print}' "$key_output")
  (( ${#phrases[@]} == 1 )) || { echo 'Cannot extract one warm-key mnemonic' >&2; exit 1; }
  umask 077
  mkdir -p "$(dirname "$MNEMONIC_OUTPUT")"
  printf '%s\n' "${phrases[0]}" >"$MNEMONIC_OUTPUT"
fi
NODE_ID="$("${compose[@]}" run --rm --no-deps -T --entrypoint inferenced node tendermint show-node-id | tail -n1 | tr -d '\r')"
CONSENSUS="$("${compose[@]}" run --rm --no-deps -T --entrypoint /bin/sh tmkms -c 'tmkms-pubkey' | grep -Eo '[A-Za-z0-9+/]{43}=' | tail -n1)"
WARM_ADDRESS="$("${compose[@]}" run --rm --no-deps -T --entrypoint /bin/sh api -c 'printf "%s\n" "$KEYRING_PASSWORD" | inferenced keys show "$KEY_NAME" --keyring-backend file -a' | tail -n1 | tr -d '\r')"
WARM_PUB_JSON="$("${compose[@]}" run --rm --no-deps -T --entrypoint /bin/sh api -c 'printf "%s\n" "$KEYRING_PASSWORD" | inferenced keys show "$KEY_NAME" --keyring-backend file --pubkey')"
[[ "$NODE_NAME" =~ ^gdc-node[0-4]$ ]] || exit 1
[[ "$NODE_ID" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid node ID: $NODE_ID" >&2; exit 1; }
[[ "$WARM_ADDRESS" =~ ^gonka1[0-9a-z]{20,90}$ ]] || { echo "Invalid warm address" >&2; exit 1; }
[[ "$(base64 -d <<<"$CONSENSUS" | wc -c)" -eq 32 ]] || { echo 'Consensus key is not 32 bytes' >&2; exit 1; }
WARM_PUB="$(jq -er .key <<<"$WARM_PUB_JSON")"
[[ "$(base64 -d <<<"$WARM_PUB" | wc -c)" -eq 33 ]] || { echo 'Warm public key is not 33 bytes' >&2; exit 1; }
mkdir -p "$(dirname "$OUTPUT")"
jq -n --arg name "$NODE_NAME" --arg node "$NODE_ID" --arg consensus "$CONSENSUS" \
  --arg warm "$WARM_ADDRESS" --arg pub "$WARM_PUB" \
  '{node_name:$name,node_id:$node,consensus_pubkey:$consensus,warm_address:$warm,warm_pubkey_b64:$pub}' >"$OUTPUT"
"${compose[@]}" stop tmkms >/dev/null || true
