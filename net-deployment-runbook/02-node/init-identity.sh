#!/usr/bin/env bash
set -Eeuo pipefail
usage(){ echo "Usage: $0 --env .env --output ssh-alias.json --mnemonic-output ssh-alias-warm.mnemonic [--warm-mnemonic FILE]" >&2; }
ENV_FILE=""; OUTPUT=""; MNEMONIC_OUTPUT=""; WARM_MNEMONIC=""
while (($#)); do case "$1" in --env) ENV_FILE="$2"; shift 2;; --output) OUTPUT="$2"; shift 2;; --mnemonic-output) MNEMONIC_OUTPUT="$2"; shift 2;; --warm-mnemonic) WARM_MNEMONIC="$2"; shift 2;; *) usage; exit 2;; esac; done
[[ -s "$ENV_FILE" && -n "$OUTPUT" && -n "$MNEMONIC_OUTPUT" ]] || { usage; exit 2; }
[[ -z "$WARM_MNEMONIC" || -s "$WARM_MNEMONIC" ]] || { echo "Warm mnemonic is not readable: $WARM_MNEMONIC" >&2; exit 1; }
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

# First-time identity bootstrap lets the upstream initializer create a P2P
# key in its disposable data directory once, then installs that key into the
# stable identity mount.  Restores already provide this file and never replace
# it with candidate-generation state.
if ! "${compose[@]}" run --rm --no-deps -T --entrypoint /bin/sh node -c 'test -s /gdc-identity/p2p/node_key.json'; then
  "${compose[@]}" run --rm --no-deps -T --entrypoint /bin/sh node -c \
    'install -d -m 0700 /gdc-identity/p2p; install -m 0600 /root/.inference/config/node_key.json /gdc-identity/p2p/node_key.json'
fi

warm_key_restore_failure_reason() {
  local output="$1"
  # Do not relay CLI output: it can include interactive material. The bounded
  # category is sufficient to distinguish an unusable mnemonic, a stale local
  # keyring and an unexpected runtime failure in retained JOIN evidence.
  if grep -qiE 'already exists|duplicate key|overwrite' "$output"; then
    printf 'existing_key_conflict\n'
  elif grep -qiE 'mnemonic|recovery phrase|bip39' "$output"; then
    printf 'mnemonic_rejected\n'
  elif grep -qiE 'passphrase|password|keyring' "$output"; then
    printf 'keyring_authentication_failed\n'
  else
    printf 'inferenced_rejected_recovery\n'
  fi
}

# Create or reuse the warm key in the persistent /root/.inference keyring.
if ! "${compose[@]}" run --rm --no-deps -T --entrypoint /bin/sh api -c \
  'printf "%s\n" "$KEYRING_PASSWORD" | inferenced keys show "$KEY_NAME" --keyring-backend file -a' >/dev/null 2>&1; then
  key_output="$TMP/warm-key.out"
  if [[ -n "$WARM_MNEMONIC" ]]; then
    # A validator backup's mnemonic is authoritative for the warm identity.
    # `keyring-file` is now a stable bind mount, so renaming that mount fails
    # with EBUSY.  Refuse links and clear only its contents before importing
    # the archived identity; the mount point itself must remain in place.
    keyring_state="$("${compose[@]}" run --rm --no-deps -T --entrypoint /bin/sh api -c \
      'if [ -L /root/.inference/keyring-file ]; then exit 64; fi; if [ -e /root/.inference/keyring-file ]; then test -d /root/.inference/keyring-file && find /root/.inference/keyring-file -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + && printf cleared; else printf absent; fi')" || {
      echo 'Cannot clear stale warm keyring before restoring validator backup' >&2
      exit 1
    }
    case "$keyring_state" in
      cleared) printf 'READY cleared stale Host keyring before restoring validator backup identity\n' ;;
      absent) ;;
      *) echo 'Cannot determine whether a stale warm keyring was cleared' >&2; exit 1 ;;
    esac
    if ! printf '%s\n%s\n%s\n' "$(<"$WARM_MNEMONIC")" "$KEYRING_PASSWORD" "$KEYRING_PASSWORD" \
      | "${compose[@]}" run --rm --no-deps -T --entrypoint /bin/sh api -c \
        'inferenced keys add "$KEY_NAME" --recover --keyring-backend file' >"$key_output" 2>&1; then
      printf 'Cannot restore warm key: reason=%s\n' "$(warm_key_restore_failure_reason "$key_output")" >&2
      exit 1
    fi
  else
    "${compose[@]}" run --rm --no-deps -T --entrypoint /bin/sh api -c \
      'printf "%s\n%s\n" "$KEYRING_PASSWORD" "$KEYRING_PASSWORD" | inferenced keys add "$KEY_NAME" --keyring-backend file' \
      >"$key_output" 2>&1
    mapfile -t phrases < <(awk 'NF == 24 {valid=1; for (i=1; i<=NF; i++) if ($i !~ /^[a-z]+$/) valid=0; if (valid) print}' "$key_output")
    (( ${#phrases[@]} == 1 )) || { echo 'Cannot extract one warm-key mnemonic' >&2; exit 1; }
    umask 077
    mkdir -p "$(dirname "$MNEMONIC_OUTPUT")"
    printf '%s\n' "${phrases[0]}" >"$MNEMONIC_OUTPUT"
  fi
fi
NODE_ID="$("${compose[@]}" run --rm --no-deps -T --entrypoint inferenced node tendermint show-node-id | tail -n1 | tr -d '\r')"
CONSENSUS="$("${compose[@]}" run --rm --no-deps -T --entrypoint /bin/sh tmkms -c 'tmkms-pubkey' | grep -Eo '[A-Za-z0-9+/]{43}=' | tail -n1)"
WARM_ADDRESS="$("${compose[@]}" run --rm --no-deps -T --entrypoint /bin/sh api -c 'printf "%s\n" "$KEYRING_PASSWORD" | inferenced keys show "$KEY_NAME" --keyring-backend file -a' | tail -n1 | tr -d '\r')"
WARM_PUB_JSON="$("${compose[@]}" run --rm --no-deps -T --entrypoint /bin/sh api -c 'printf "%s\n" "$KEYRING_PASSWORD" | inferenced keys show "$KEY_NAME" --keyring-backend file --pubkey')"
[[ "$NODE_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || {
  echo "Invalid node SSH alias: $NODE_NAME" >&2
  exit 2
}
[[ "$NODE_ID" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid node ID: $NODE_ID" >&2; exit 1; }
[[ "$WARM_ADDRESS" =~ ^gonka1[0-9a-z]{20,90}$ ]] || { echo "Invalid warm address" >&2; exit 1; }
[[ "$(base64 -d <<<"$CONSENSUS" | wc -c)" -eq 32 ]] || { echo 'Consensus key is not 32 bytes' >&2; exit 1; }
WARM_PUB="$(jq -er .key <<<"$WARM_PUB_JSON")"
[[ "$(base64 -d <<<"$WARM_PUB" | wc -c)" -eq 33 ]] || { echo 'Warm public key is not 33 bytes' >&2; exit 1; }
mkdir -p "$(dirname "$OUTPUT")"
jq -n --arg name "$NODE_NAME" --arg node "$NODE_ID" --arg consensus "$CONSENSUS" \
  --arg warm "$WARM_ADDRESS" --arg pub "$WARM_PUB" \
  '{node_name:$name,node_id:$node,consensus_pubkey:$consensus,warm_address:$warm,warm_pubkey_b64:$pub}' >"$OUTPUT"

if ! "${compose[@]}" stop tmkms >/dev/null; then
  echo 'Temporary TMKMS signer stop failed; refusing to accept generated identity' >&2
  exit 1
fi

compose_project="${COMPOSE_PROJECT_NAME:-$NODE_NAME}"
tmkms_states="$(docker ps -a --filter "name=^/${compose_project}-tmkms-" --format '{{.State}}')" || {
  echo 'Unable to verify temporary TMKMS signer state; refusing to accept generated identity' >&2
  exit 1
}
while IFS= read -r tmkms_state; do
  [[ -z "$tmkms_state" ]] && continue
  if [[ "$tmkms_state" != exited ]]; then
    printf 'Temporary TMKMS signer is not definitively stopped: state=%s\n' "$tmkms_state" >&2
    exit 1
  fi
done <<<"$tmkms_states"
