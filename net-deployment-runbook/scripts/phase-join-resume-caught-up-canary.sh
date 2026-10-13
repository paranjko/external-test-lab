#!/usr/bin/env bash
# Continue a receipt-bound signerless state-sync canary.  This is deliberately
# limited to the pre-membership lifecycle: no account, registration, funding,
# permission, identity or signer operation occurs before the promoted
# canonical runtime is independently verified by the existing continuation.
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
load_project
# shellcheck source=lib-join-resume.sh
source "$(dirname "$0")/lib-join-resume.sh"

[[ $# -eq 3 ]] || { echo "Usage: $0 NODE RUN_DIR new|restore" >&2; exit 2; }
NODE="$(node_name "$1")"
RUN="$2"
operation="$3"

join_resume_prepare_caught_up_canary "$operation"

# A running TMKMS means the retained signerless receipt no longer describes
# this Host.  Stop here rather than inferring which generation it signed.
# shellcheck disable=SC2154 # join_resume_prepare_caught_up_canary binds deploy.
tmkms="$(ssh "$NODE" "cd '$deploy' && docker compose --env-file .env -f compose.yaml ps -q tmkms")"
[[ -z "$(printf '%s\n' "$tmkms" | sed '/^$/d')" ]] || {
  echo 'caught-up canary resume refused: signer is already running' >&2
  exit 1
}
canary="$(ssh "$NODE" "cd '$deploy' && docker compose --env-file .env -f compose.yaml ps -q node")"
[[ -n "$(printf '%s\n' "$canary" | sed '/^$/d')" ]] || {
  echo 'caught-up canary resume refused: signerless canary is no longer running' >&2
  exit 1
}

# shellcheck disable=SC2154 # join_resume_prepare_caught_up_canary binds remote.
ssh "$NODE" "rm -rf '$remote' && mkdir -p '$remote'"
scp -q "$ROOT/scripts/verify-join-lineage-state.sh" "$NODE:$remote/verify-join-lineage-state.sh"
# shellcheck disable=SC2154 # join_resume_prepare_caught_up_canary binds lineage.
scp -q "$lineage" "$NODE:$remote/lineage-receipt.json"

step "Verify retained signerless canary for $NODE before promotion"
ssh "$NODE" "bash '$remote/verify-join-lineage-state.sh' http://127.0.0.1:26657 '$remote/lineage-receipt.json' --resume-current"
ssh "$NODE" "cd '$deploy' && ./verify-state-sync-config.sh '$deploy' '$remote/lineage-receipt.json' --consumed-trust"
ssh "$NODE" "cd '$deploy' && ./record-state-sync-canary.sh '$deploy' '$remote/lineage-receipt.json'"
scp -q "$NODE:$remote/lineage-receipt.json" "$RUN/lineage-state-sync-receipt.json"
join_resume_append_transition CANARY_VERIFIED

step "Stop signerless P2P canary before promoting $NODE state"
ssh "$NODE" "sudo '$deploy/stop-state-sync-canary.sh' '$deploy'"
join_resume_append_transition CANARY_STOPPED
join_resume_append_transition PROMOTION_PREPARED
join_resume_append_transition PROMOTING
step "Promote verified $NODE state-sync generation atomically"
# shellcheck disable=SC2154 # join_resume_prepare_caught_up_canary binds generation.
ssh "$NODE" "sudo '$deploy/promote-state-sync-generation.sh' '$NODE' '$generation' '/srv/dai/data'"
join_resume_append_transition PROMOTED

step "Bind $NODE warm account to the promoted signerless generation"
# shellcheck disable=SC2154 # join_resume_prepare_caught_up_canary binds warm mnemonic and address.
printf '%s\n' "$(<"$warm_mnemonic")" \
  | ssh -T "$NODE" "cd '$deploy' && ./ensure-warm-key.sh --expected-address '$warm_address'"

step "Start signerless canonical application stack for $NODE"
ssh "$NODE" "cd '$deploy' && ./start-node.sh"
join_resume_append_transition CANONICAL_RUNNING

case "$operation" in
  new) exec "$ROOT/scripts/phase-join-resume-new-canonical.sh" "$NODE" "$RUN" ;;
  restore) exec "$ROOT/scripts/phase-join-resume-canonical.sh" "$NODE" "$RUN" ;;
esac
