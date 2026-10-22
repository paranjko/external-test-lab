#!/usr/bin/env bash
# Continue a receipt-bound signerless state-sync or full-sync canary. This is deliberately
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
# These values are bound by the receipt loader above, not caller defaults.
: "${bootstrap_mode:?}" "${lineage:?}" "${resume_state:?}"
if [[ "$bootstrap_mode" == full_sync ]]; then
  source_rpc="$(jq -er '.bootstrap.seed.rpc_url' "$lineage")"
  expected_node_id="$(jq -er '.node_id' "$IDENTITY")"
  [[ "$source_rpc" =~ ^https?://[A-Za-z0-9.-]+(:[1-9][0-9]{0,4})?/chain-rpc$ \
    && "$expected_node_id" =~ ^[0-9a-f]{40}$ ]] || {
    echo 'full-sync canary resume has an invalid retained seed RPC or node identity' >&2
    exit 1
  }
  [[ ! -e "$RUN/genesis-single-seed-canary.json" && ! -L "$RUN/genesis-single-seed-canary.json" ]] || {
    echo 'full-sync canary resume refuses to overwrite existing canary evidence' >&2
    exit 1
  }
fi

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
if [[ "$bootstrap_mode" == full_sync ]]; then
  scp -q "$ROOT/scripts/verify-genesis-single-seed-canary.sh" "$NODE:$remote/verify-genesis-single-seed-canary.sh"
else
  scp -q "$ROOT/scripts/verify-join-lineage-state.sh" "$NODE:$remote/verify-join-lineage-state.sh"
fi
# shellcheck disable=SC2154 # join_resume_prepare_caught_up_canary binds lineage.
scp -q "$lineage" "$NODE:$remote/lineage-receipt.json"

if [[ "$bootstrap_mode" == full_sync ]]; then
  if [[ "$resume_state" == CANARY_RUNNING ]]; then
    step "Wait for signerless full-sync canary on $NODE to catch up"
    ssh "$NODE" "cd '$deploy' && ./wait-state-sync-canary.sh '$deploy' '${source_rpc%/}'"
  fi

  # Core's config.toml can appear after the compose service becomes visible.
  # Poll it read-only for a bounded interval before proving lineage; never
  # treat a transient missing file as a reason to regenerate the candidate.
  step "Verify full-sync configuration and single-seed canary for $NODE"
  config_script="$(cat <<'REMOTE'
set -Eeuo pipefail
deploy="$1"
cd "$deploy"
attempt=0
while (( attempt < 30 )); do
  if grep -Fxq 'SYNC_WITH_SNAPSHOTS=false' .env \
    && grep -Fxq 'GDC_JOIN_STATESYNC_ENABLE=false' .env; then
    config="$(docker compose --env-file .env -f compose.yaml exec -T node sh -c 'cat /root/.inference/config/config.toml' 2>/dev/null || true)"
    if grep -Eq '^enable = false$' <<<"$config" \
      && grep -Fq 'rpc_servers = ""' <<<"$config" \
      && grep -Eq '^trust_height = 0$' <<<"$config"; then
      printf 'PASS full-sync canary config is ready\n'
      exit 0
    fi
  fi
  attempt=$((attempt + 1))
  sleep 2
done
echo 'full-sync canary config did not become readable and exact before timeout' >&2
exit 1
REMOTE
)"
  printf '%s\n' "$config_script" | ssh "$NODE" "bash -s -- '$deploy'"
  ssh "$NODE" "bash '$remote/verify-genesis-single-seed-canary.sh' '$remote/lineage-receipt.json' http://127.0.0.1:26657 '$expected_node_id' '$remote/genesis-single-seed-canary.json'"
  scp -q "$NODE:$remote/genesis-single-seed-canary.json" "$RUN/genesis-single-seed-canary.json"
  if [[ "$resume_state" == CANARY_RUNNING ]]; then
    join_resume_append_transition CANARY_CAUGHT_UP
  fi
  join_resume_retain_full_sync_lineage "$operation" canary
else
  step "Verify retained signerless canary for $NODE before promotion"
  ssh "$NODE" "bash '$remote/verify-join-lineage-state.sh' http://127.0.0.1:26657 '$remote/lineage-receipt.json' --resume-current"
  ssh "$NODE" "cd '$deploy' && ./verify-state-sync-config.sh '$deploy' '$remote/lineage-receipt.json' --consumed-trust"
  ssh "$NODE" "cd '$deploy' && ./record-state-sync-canary.sh '$deploy' '$remote/lineage-receipt.json'"
  scp -q "$NODE:$remote/lineage-receipt.json" "$RUN/lineage-state-sync-receipt.json"
fi
join_resume_append_transition CANARY_VERIFIED

step "Stop signerless canary before promoting $NODE state"
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
