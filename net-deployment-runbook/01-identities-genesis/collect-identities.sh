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
SSH_OPTIONS=(-o ConnectTimeout=5 -o BatchMode=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=3)

validate_identity_readback() {
  local file="$1" host="$2"
  jq -e --arg host "$host" '
    .node_name == $host and
    (.node_id | type == "string" and test("^[0-9a-f]{40}$")) and
    (.consensus_pubkey | type == "string" and length > 0) and
    (.warm_address | type == "string" and test("^gonka1[0-9a-z]{20,90}$")) and
    (.warm_pubkey_b64 | type == "string" and length > 0)
  ' "$file" >/dev/null
}

verify_remote_temporary_tmkms_stopped() {
  local host="$1" states state
  states="$(ssh "${SSH_OPTIONS[@]}" "$host" "docker ps -a --filter 'name=^/${host}-tmkms-' --format '{{.State}}'")" || return 1
  while IFS= read -r state; do
    [[ -z "$state" ]] && continue
    if [[ "$state" != exited ]]; then
      printf 'temporary TMKMS signer is not definitively stopped: host=%s state=%s\n' "$host" "$state" >&2
      return 1
    fi
  done <<<"$states"
}

# The remote initializer creates its public identity document before it stops
# its temporary TMKMS container.  A lost SSH session at that exact boundary is
# ambiguous: rerunning could overwrite transient state, while accepting the
# document without a signer check could leave an unobserved signer alive.
# Resume only when a fresh readback validates and no temporary signer runs.
recover_interrupted_identity_bootstrap() {
  local host="$1" remote="$2" destination="$3" readback
  readback="$(mktemp "${destination}.readback.XXXXXX")"
  if ! ssh "${SSH_OPTIONS[@]}" "$host" "test -s '$remote/$host.json'"; then
    rm -f "$readback"
    return 1
  fi
  if ! scp -q "${SSH_OPTIONS[@]}" "$host:$remote/$host.json" "$readback"; then
    rm -f "$readback"
    return 1
  fi
  if ! validate_identity_readback "$readback" "$host"; then
    rm -f "$readback"
    return 1
  fi
  if ! verify_remote_temporary_tmkms_stopped "$host"; then
    rm -f "$readback"
    return 1
  fi
  mv "$readback" "$destination"
  return 0
}

failed=0
restore_warm_mnemonic="${GDC_RESTORE_WARM_MNEMONIC:-}"
[[ -z "$restore_warm_mnemonic" || -s "$restore_warm_mnemonic" ]] || {
  echo "FAILED  restore warm mnemonic is not readable: $restore_warm_mnemonic" >&2
  exit 1
}
for HOST in "${NODES[@]}"; do
  topology_contains_node "$HOST" || { echo "Invalid node alias outside the supplied inventory: $HOST" >&2; failed=1; continue; }
  REMOTE="/srv/dai/identity-bootstrap"
  if ! ssh "${SSH_OPTIONS[@]}" "$HOST" true; then
    echo "FAILED  $HOST is unreachable" >&2
    failed=1
    continue
  fi
  render_args=(
    --inventory "$INVENTORY" --node-name "$HOST"
    --account-public "$GDC_HOME/accounts/$HOST-cold.json" --bootstrap
    --secrets-dir "$SECRETS" --output "$BOOT/$HOST.env"
  )
  if [[ -n "${GDC_JOIN_PROFILE:-}" ]]; then
    render_args+=(--join-profile "$GDC_JOIN_PROFILE")
  fi
  "$ROOT/02-node/render-node-env.sh" "${render_args[@]}" >/dev/null
  ssh "${SSH_OPTIONS[@]}" "$HOST" "rm -rf '$REMOTE' && mkdir -p '$REMOTE'"
  rsync -a --delete "$ROOT/02-node/" "$HOST:$REMOTE/02-node/"
  scp -q "${SSH_OPTIONS[@]}" "$BOOT/$HOST.env" "$HOST:$REMOTE/bootstrap.env"
  remote_mnemonic="$REMOTE/$HOST-warm.mnemonic"
  remote_restore_mnemonic="$REMOTE/$HOST-warm.restore.mnemonic"
  log="$LOGS/$HOST.log"
  init_args="--env '$REMOTE/bootstrap.env' --output '$REMOTE/$HOST.json' --mnemonic-output '$remote_mnemonic'"
  if [[ -n "$restore_warm_mnemonic" ]]; then
    scp -q "${SSH_OPTIONS[@]}" "$restore_warm_mnemonic" "$HOST:$remote_restore_mnemonic"
    init_args+=" --warm-mnemonic '$remote_restore_mnemonic'"
  fi
  if ! ssh -T "${SSH_OPTIONS[@]}" "$HOST" "chmod 600 '$REMOTE/bootstrap.env' '$remote_restore_mnemonic' 2>/dev/null || true; trap 'rm -f \"$REMOTE/bootstrap.env\" \"$remote_restore_mnemonic\"' EXIT; cd '$REMOTE/02-node' && ./init-identity.sh $init_args" >"$log" 2>&1; then
    if recover_interrupted_identity_bootstrap "$HOST" "$REMOTE" "$OUT/$HOST.json"; then
      printf 'READY  %s identity bootstrap completed before SSH interruption; signer is stopped and public identity was re-read\n' "$HOST"
    else
      echo "FAILED  $HOST identity bootstrap; details: $log" >&2
      failed=1
      continue
    fi
  else
    readback="$(mktemp "$OUT/$HOST.json.readback.XXXXXX")"
    if ! scp -q "${SSH_OPTIONS[@]}" "$HOST:$REMOTE/$HOST.json" "$readback" \
      || ! validate_identity_readback "$readback" "$HOST"; then
      rm -f "$readback"
      echo "FAILED  $HOST identity bootstrap returned an invalid public identity; details: $log" >&2
      failed=1
      continue
    fi
    if ! verify_remote_temporary_tmkms_stopped "$HOST"; then
      rm -f "$readback"
      echo "FAILED  $HOST identity bootstrap did not prove temporary signer stopped; details: $log" >&2
      failed=1
      continue
    fi
    mv "$readback" "$OUT/$HOST.json"
  fi
  local_mnemonic="$MNEMONICS/$HOST-warm.mnemonic"
  if ssh -T "${SSH_OPTIONS[@]}" "$HOST" "test -s '$remote_mnemonic'"; then
    if [[ -e "$local_mnemonic" ]]; then
      mv "$local_mnemonic" "$MNEMONICS/$HOST-warm.previous.$(date -u +%Y%m%dT%H%M%SZ).mnemonic"
    fi
    scp -q "${SSH_OPTIONS[@]}" "$HOST:$remote_mnemonic" "$local_mnemonic"
    chmod 600 "$local_mnemonic"
  elif [[ ! -s "$local_mnemonic" ]]; then
    echo "FAILED  $HOST warm key exists without $local_mnemonic; rotate the warm key" >&2
    failed=1
    continue
  fi
  ssh -T "${SSH_OPTIONS[@]}" "$HOST" "rm -f '$REMOTE/$HOST.json' '$remote_mnemonic' '$remote_restore_mnemonic'"
  jq -r '"READY  \(.node_name) node_id=\(.node_id) warm=\(.warm_address)"' "$OUT/$HOST.json"
done
exit "$failed"
