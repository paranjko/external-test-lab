#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -ge 5 ]] || { echo "Usage: $0 inventory.env secrets-dir output-identities-dir mnemonic-dir ssh-alias [...]" >&2; exit 2; }
INVENTORY="$1"; SECRETS="$2"; OUT="$3"; MNEMONICS="$4"
shift 4
NODES=("$@")
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; BOOT="$(mktemp -d)"; trap 'rm -rf "$BOOT"' EXIT
# shellcheck disable=SC1091
source "$ROOT/scripts/lib.sh"
load_env "$INVENTORY"
load_topology
LOGS="$STATE/logs/identities"
umask 077
mkdir -p "$OUT" "$MNEMONICS" "$LOGS"
failed=0
restore_warm_mnemonic="${GDC_RESTORE_WARM_MNEMONIC:-}"
[[ -z "$restore_warm_mnemonic" || -s "$restore_warm_mnemonic" ]] || {
  echo "FAILED  restore warm mnemonic is not readable: $restore_warm_mnemonic" >&2
  exit 1
}
for HOST in "${NODES[@]}"; do
  topology_contains_node "$HOST" || { echo "Invalid node alias outside the supplied inventory: $HOST" >&2; failed=1; continue; }
  REMOTE="/srv/dai/identity-bootstrap"
  if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$HOST" true; then
    echo "FAILED  $HOST is unreachable" >&2
    failed=1
    continue
  fi
  "$ROOT/02-node/render-node-env.sh" --inventory "$INVENTORY" --node-name "$HOST" \
    --account-public "$GDC_HOME/accounts/$HOST-cold.json" --bootstrap \
    --secrets-dir "$SECRETS" --output "$BOOT/$HOST.env" >/dev/null
  ssh "$HOST" "rm -rf '$REMOTE' && mkdir -p '$REMOTE'"
  rsync -a --delete "$ROOT/02-node/" "$HOST:$REMOTE/02-node/"
  scp -q "$BOOT/$HOST.env" "$HOST:$REMOTE/bootstrap.env"
  remote_mnemonic="$REMOTE/$HOST-warm.mnemonic"
  remote_restore_mnemonic="$REMOTE/$HOST-warm.restore.mnemonic"
  log="$LOGS/$HOST.log"
  init_args="--env '$REMOTE/bootstrap.env' --output '$REMOTE/$HOST.json' --mnemonic-output '$remote_mnemonic'"
  if [[ -n "$restore_warm_mnemonic" ]]; then
    scp -q "$restore_warm_mnemonic" "$HOST:$remote_restore_mnemonic"
    init_args+=" --warm-mnemonic '$remote_restore_mnemonic'"
  fi
  if ! ssh -T "$HOST" "chmod 600 '$REMOTE/bootstrap.env' '$remote_restore_mnemonic' 2>/dev/null || true; trap 'rm -f \"$REMOTE/bootstrap.env\" \"$remote_restore_mnemonic\"' EXIT; cd '$REMOTE/02-node' && ./init-identity.sh $init_args" >"$log" 2>&1; then
    echo "FAILED  $HOST identity bootstrap; details: $log" >&2
    failed=1
    continue
  fi
  scp -q "$HOST:$REMOTE/$HOST.json" "$OUT/$HOST.json"
  local_mnemonic="$MNEMONICS/$HOST-warm.mnemonic"
  if ssh -T "$HOST" "test -s '$remote_mnemonic'"; then
    if [[ -e "$local_mnemonic" ]]; then
      mv "$local_mnemonic" "$MNEMONICS/$HOST-warm.previous.$(date -u +%Y%m%dT%H%M%SZ).mnemonic"
    fi
    scp -q "$HOST:$remote_mnemonic" "$local_mnemonic"
    chmod 600 "$local_mnemonic"
  elif [[ ! -s "$local_mnemonic" ]]; then
    echo "FAILED  $HOST warm key exists without $local_mnemonic; rotate the warm key" >&2
    failed=1
    continue
  fi
  ssh -T "$HOST" "rm -f '$REMOTE/$HOST.json' '$remote_mnemonic' '$remote_restore_mnemonic'"
  jq -r '"READY  \(.node_name) node_id=\(.node_id) warm=\(.warm_address)"' "$OUT/$HOST.json"
done
exit "$failed"
