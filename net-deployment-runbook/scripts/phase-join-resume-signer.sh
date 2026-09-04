#!/usr/bin/env bash
# This former dispatcher intentionally stops before parsing any operator
# receipt.  A replacement-host receipt cannot prove that the old signer was
# fenced; do not re-enable this path until that evidence can be acquired and
# authenticated independently.
printf '%s\n' 'restore signer activation is unavailable: independently acquired prior-Host evidence is not implemented' >&2
exit 1
# shellcheck disable=SC2317
# Resume the sole restore interruption point that is safe to automate: a
# signerless canonical Host after membership reconciliation.  This dispatcher
# deliberately does not infer an arbitrary phase from stderr or rerun setup.
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
# Resume must consume only the retained run bindings.  In particular it must
# not require, or reconstruct, a mutable role input from a fresh JOIN.
ROOT="${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

[[ $# -eq 3 ]] || { echo "Usage: $0 NODE RUN_DIR OLD_SIGNER_FENCE_RECEIPT" >&2; exit 2; }
NODE="$1"
[[ "$NODE" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]] || { echo 'invalid restored Host alias' >&2; exit 2; }
RUN="$2"
SOURCE_FENCE="$3"
[[ -d "$RUN" && -f "$SOURCE_FENCE" && ! -L "$SOURCE_FENCE" ]] || {
  echo 'invalid receipt-bound restore resume input' >&2; exit 2;
}
[[ -n "${GDC_RUN_ID:-}" && -r "${GDC_JOIN_PROFILE:-}" && -r "${GDC_JOIN_OBSERVATION:-}" && -n "${GDC_JOIN_RESULT_OUTPUT:-}" ]] || {
  echo 'restore resume lacks retained run bindings' >&2; exit 2;
}

receipts="$RUN/receipts"
"$ROOT/scripts/verify-join-receipt-chain.sh" --receipt-dir "$receipts" >/dev/null
head_name="$(find "$receipts" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.json' -printf '%f\n' | LC_ALL=C sort | tail -n1)"
head="$receipts/$head_name"
jq -e --arg run_id "$GDC_RUN_ID" --arg node "$NODE" '
  .run_id == $run_id and .operation == "restore" and .node_name == $node and
  .state == "PERMISSIONS_RECONCILED" and .signer_ever_started == false and
  (.identity_fingerprints.consensus_pubkey | type == "string" and length > 0)
' "$head" >/dev/null || {
  echo 'restore resume is allowed only from retained signerless PERMISSIONS_RECONCILED state' >&2
  exit 1
}
jq -e '
  .kind == "gdc-host-join-result" and .outcome == "manual_recovery_required" and
  .reason == "old_signer_fence_unprovable" and .mutation == "canonical_signer_off" and
  .signer_state == "disabled"
' "$GDC_JOIN_RESULT_OUTPUT" >/dev/null || {
  echo 'restore resume requires the retained signerless old-signer-fence refusal' >&2
  exit 1
}
minimum_tmkms_state="$RUN/restore-tmkms-signing-state.json"
[[ -f "$minimum_tmkms_state" && ! -L "$minimum_tmkms_state" && "$(stat -c %a "$minimum_tmkms_state")" == 600 ]] || {
  echo 'restore resume lacks the retained TMKMS signing state from its verified archive' >&2
  exit 1
}

consensus_pubkey="$(jq -er .identity_fingerprints.consensus_pubkey "$head")"
target_fence="$RUN/signer-fence-receipt.v1.json"
install -m 0600 "$SOURCE_FENCE" "$target_fence"
old_host="$(jq -r .old_host_identity "$target_fence")"
[[ "$old_host" != "$NODE" ]] || {
  echo 'replacement signer fence must identify a previous Host, not the restored target' >&2
  exit 1
}
"$ROOT/scripts/verify-signer-fence-receipt.sh" --receipt "$target_fence" \
  --run-id "$GDC_RUN_ID" --consensus-pubkey "$consensus_pubkey" --replacement
fence_height="$(jq -er .fence_height "$target_fence")"

append_transition() {
  local state="$1" signer_started="$2" height="$3" additions="${4:-[]}" input evidence
  input="$(mktemp "$RUN/.resume-transition.XXXXXX")"
  evidence="$(jq -c .evidence "$head")"
  evidence="$(jq -c --argjson additions "$additions" '. + $additions' <<<"$evidence")"
  jq --arg state "$state" --argjson signer_started "$signer_started" --argjson height "$height" --argjson evidence "$evidence" '
    del(.sequence, .recorded_at, .previous_receipt_sha256)
    | .state = $state | .signer_ever_started = $signer_started
    | .tmkms_state.height = $height | .evidence = $evidence
    | .outcome = "in_progress" | .resume_policy = "resume_same_run"
  ' "$head" >"$input"
  "$ROOT/scripts/record-join-receipt.sh" --receipt-dir "$receipts" --input "$input" >/dev/null
  rm -f "$input"
  head_name="$(find "$receipts" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.json' -printf '%f\n' | LC_ALL=C sort | tail -n1)"
  head="$receipts/$head_name"
}

remote_deploy="/srv/dai/deploy/$NODE"
ssh "$NODE" "cd '$remote_deploy' && test -r .env && test -r compose.yaml"
remote_tmkms="$(ssh "$NODE" "cd '$remote_deploy' && docker compose --env-file .env -f compose.yaml ps -q tmkms")"
[[ -z "$remote_tmkms" ]] || { echo 'restore resume refused: target TMKMS is already running' >&2; exit 1; }
remote_node="$(ssh "$NODE" "cd '$remote_deploy' && docker compose --env-file .env -f compose.yaml ps -q node")"
[[ -n "$remote_node" ]] || { echo 'restore resume refused: canonical node is not running signerless' >&2; exit 1; }
before_tmkms_state="$RUN/tmkms-signing-state-before.json"
ssh "$NODE" "sudo cat '/srv/dai/signer/$NODE/tmkms/state/priv_validator_state.json'" >"$before_tmkms_state"
chmod 600 "$before_tmkms_state"
"$ROOT/scripts/verify-tmkms-signing-state.sh" --minimum "$minimum_tmkms_state" --observed "$before_tmkms_state" \
  --fence-height "$fence_height" >/dev/null
status="$(ssh "$NODE" "curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:26657/status")"
height="$(jq -er '.result.sync_info.latest_block_height | tonumber | select(. > 0)' <<<"$status")"
catching_up="$(jq -er '.result.sync_info.catching_up | type == "boolean" and . == false' <<<"$status")"
[[ "$catching_up" == true && "$height" -gt "$fence_height" ]] || {
  echo 'restore resume refused: canonical node has not advanced beyond the external signer fence' >&2; exit 1;
}

fence_sha="$(sha256sum "$target_fence" | awk '{print $1}')"
before_tmkms_sha="$(sha256sum "$before_tmkms_state" | awk '{print $1}')"
fence_evidence="$(jq -cn --arg fence "$fence_sha" --arg tmkms "$before_tmkms_sha" '[{kind:"signer_fence",sha256:$fence},{kind:"tmkms_state_before",sha256:$tmkms}]')"
append_transition SIGNER_FENCE_VERIFIED false "$height" "$fence_evidence"
record_join_state "$NODE" SIGNER_FENCE_VERIFIED "$(jq -r .identity_fingerprints.participant_address "$head")"
append_transition SIGNER_ACTIVATING true "$height"
ssh "$NODE" "cd '$remote_deploy' && ./start-node.sh --enable-signer"
remote_tmkms="$(ssh "$NODE" "cd '$remote_deploy' && docker compose --env-file .env -f compose.yaml ps -q tmkms")"
[[ "$(printf '%s\n' "$remote_tmkms" | sed '/^$/d' | wc -l)" == 1 ]] || {
  echo 'restore resume failed: signer start did not produce exactly one TMKMS container' >&2; exit 1;
}
status="$(ssh "$NODE" "curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:26657/status")"
height="$(jq -er '.result.sync_info.latest_block_height | tonumber | select(. > 0)' <<<"$status")"
catching_up="$(jq -er '.result.sync_info.catching_up | type == "boolean" and . == false' <<<"$status")"
[[ "$catching_up" == true && "$height" -gt "$fence_height" ]] || {
  echo 'restore resume failed: signer started without a current caught-up canonical node' >&2; exit 1;
}
after_tmkms_state="$RUN/tmkms-signing-state-after.json"
ssh "$NODE" "sudo cat '/srv/dai/signer/$NODE/tmkms/state/priv_validator_state.json'" >"$after_tmkms_state"
chmod 600 "$after_tmkms_state"
"$ROOT/scripts/verify-tmkms-signing-state.sh" --minimum "$before_tmkms_state" --observed "$after_tmkms_state" \
  --fence-height "$fence_height" >/dev/null
after_tmkms_sha="$(sha256sum "$after_tmkms_state" | awk '{print $1}')"
after_evidence="$(jq -cn --arg tmkms "$after_tmkms_sha" '[{kind:"tmkms_state_after",sha256:$tmkms}]')"
append_transition SIGNER_ACTIVE_VERIFIED true "$height" "$after_evidence"
record_join_state "$NODE" SIGNER_ENABLED "$(jq -r .identity_fingerprints.participant_address "$head")"

input="$(mktemp "$RUN/.resume-result.XXXXXX")"
jq -cn --arg profile "$(sha256sum "$GDC_JOIN_PROFILE" | awk '{print $1}')" \
  '{schema_version:1,kind:"gdc-host-join-result",outcome:"manual_recovery_required",phase:"acceptance",category:"signer",reason:"resume_signer_active_acceptance_pending",exit_code:1,mutation:"signer_may_be_on",signer_state:"enabled",resume:"manual_recovery",join_profile_sha256:$profile,evidence:[]}' >"$input"
"$ROOT/scripts/record-join-result.sh" --output "$GDC_JOIN_RESULT_OUTPUT" --input "$input" >/dev/null
rm -f "$input"
echo 'restore signer activation is receipt-bound, but independent acceptance is still required' >&2
exit 1
