#!/usr/bin/env bash
# Build a separate recovery namespace from a verified completed JOIN. Retained
# runtime selection is preserved, not presented as a new network observation.
# This command performs operator-local work only.
set -Eeuo pipefail
{ set +x; } 2>/dev/null
umask 077
source "$(dirname "$0")/validator-backup.sh"

[[ $# == 6 ]] || { echo "Usage: $0 NODE PARENT_RUN ARCHIVE NEW_RUN_ID OUTPUT_DIR PUBLIC_HOST" >&2; exit 2; }
node="$1"; parent="$2"; archive="$3"; new_id="$4"; output="$5"; public_host="$6"
[[ "$node" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ && "$new_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || exit 2
[[ -d "$parent" && ! -L "$parent" && -f "$archive" && ! -L "$archive" && ! -e "$output" && ! -L "$output" ]] || {
  echo 'consensus recovery requires a retained parent, regular archive and new output directory' >&2; exit 2;
}
parent_id="$(jq -er .run_id "$parent/join-profile.v1.json")"
[[ "$parent_id" != "$new_id" ]] || { echo 'consensus recovery must not rewrite its parent JOIN' >&2; exit 2; }
"$ROOT/scripts/verify-join-resume-inputs.sh" --run-dir "$parent" --run-id "$parent_id" \
  --node-name "$node" --public-host "$public_host" >/dev/null
chain="$("$ROOT/scripts/verify-join-receipt-chain.sh" --receipt-dir "$parent/receipts")"
jq -e '.last_state == "COMPLETE" and .signer_ever_started == true' <<<"$chain" >/dev/null || {
  echo 'consensus recovery requires a completed parent JOIN' >&2; exit 2;
}
head="$(find "$parent/receipts" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.json' -printf '%f\n' | LC_ALL=C sort | tail -n1)"
mkdir -m 0700 "$output"
install -m 0600 "$archive" "$output/restore-validator-backup.tar"
install -m 0600 "$parent/receipts/$head" "$output/parent-final-receipt.json"
[[ "$(sha256sum "$output/parent-final-receipt.json" | awk '{print $1}')" == "$(jq -er .head_sha256 <<<"$chain")" ]] || {
  echo 'parent JOIN changed while preparing recovery inputs' >&2; exit 1;
}
install -m 0600 "$parent/join-profile.v1.json" "$output/parent-join-profile.v1.json"
install -m 0600 "$parent/network-observation.v1.json" "$output/network-observation.v1.json"
[[ "$(sha256sum "$output/parent-join-profile.v1.json" | awk '{print $1}')" == "$(jq -er .join_profile_sha256 "$output/parent-final-receipt.json")" &&
   "$(sha256sum "$output/network-observation.v1.json" | awk '{print $1}')" == "$(jq -er .network_observation_sha256 "$output/parent-final-receipt.json")" ]] || {
  echo 'parent JOIN inputs changed while preparing recovery inputs' >&2; exit 1;
}
expected_chain="$(jq -er .spec.network.chain_id "$output/parent-join-profile.v1.json")"
[[ -f "$GDC_HOME/genesis/genesis.json" && ! -L "$GDC_HOME/genesis/genesis.json" ]] || {
  echo 'consensus recovery lacks the retained Genesis' >&2; exit 1;
}
raw_genesis_sha="$(sha256sum "$GDC_HOME/genesis/genesis.json" | awk '{print $1}')"
[[ "$raw_genesis_sha" == "$(jq -er .spec.network.genesis_sha256 "$output/parent-join-profile.v1.json")" ]] || {
  echo 'retained Genesis no longer matches the parent profile' >&2; exit 1;
}
expected_genesis="$(genesis_sha256 "$GDC_HOME/genesis/genesis.json")"
GDC_JOIN_PROFILE="$output/parent-join-profile.v1.json"
export GDC_JOIN_PROFILE
verify_backup_archive "$output/restore-validator-backup.tar" "$node" "$expected_chain" "$expected_genesis"
safe_extract "$output/restore-validator-backup.tar" "$output/archive" backup "$node"
archive_sha="$(sha256sum "$output/restore-validator-backup.tar" | awk '{print $1}')"
jq --arg run "$new_id" --arg archive "$archive_sha" '
  .run_id = $run | .operation = "restore" |
  .spec.identity.mode = "restore" | .spec.identity.restore_archive_sha256 = $archive
' "$output/parent-join-profile.v1.json" >"$output/profile.tmp"
spec_sha="$(jq -cS .spec "$output/profile.tmp" | sha256sum | awk '{print $1}')"
jq -cS --arg sha "$spec_sha" '.profile_id = $sha' "$output/profile.tmp" >"$output/join-profile.v1.json"
chmod 600 "$output/join-profile.v1.json"
rm "$output/profile.tmp"
# Keep the original observation times/expiry. A fresh checkpoint and live
# runtime readback, not a forged new observation timestamp, gate this recovery.
"$ROOT/scripts/join-profile.sh" validate --allow-expired "$output/join-profile.v1.json" >/dev/null
jq -cn --arg parent "$parent_id" --arg run "$new_id" --arg archive "$archive_sha" \
  --arg head "$(sha256sum "$output/parent-final-receipt.json" | awk '{print $1}')" \
  --arg profile "$(sha256sum "$output/parent-join-profile.v1.json" | awk '{print $1}')" \
  '{schema_version:1,kind:"gdc-consensus-recovery-parent",run_id:$run,parent_run_id:$parent,
    parent_receipt_sha256:$head,parent_profile_sha256:$profile,archive_sha256:$archive,
    activation_authorized:false}' >"$output/recovery-parent.json"
# Start a new ordinary receipt chain rather than append a different consensus
# identity to the completed parent. RUN_CREATED records intent, not activation.
jq --arg run "$new_id" \
  --arg profile "$(sha256sum "$output/join-profile.v1.json" | awk '{print $1}')" \
  --arg parent_sha "$(sha256sum "$output/recovery-parent.json" | awk '{print $1}')" \
  --arg archive_sha "$archive_sha" \
  --slurpfile manifest "$output/archive/manifest.json" \
  --slurpfile signing "$output/archive/remote-state/tmkms/state/priv_validator_state.json" '
  del(.sequence,.recorded_at,.previous_receipt_sha256)
  | .run_id = $run | .operation = "restore" | .state = "RUN_CREATED"
  | .join_profile_sha256 = $profile
  | .identity_fingerprints.consensus_pubkey = $manifest[0].identity.consensus_pubkey
  | .signer_ever_started = true
  | .tmkms_state = {height:($signing[0].height|tonumber),round:($signing[0].round|tonumber),
      step:($signing[0].step|tonumber),block_id:($signing[0].block_id.hash // "" | ascii_downcase)}
  | .evidence = [{kind:"recovery_parent",sha256:$parent_sha},{kind:"restore_archive",sha256:$archive_sha}]
  | .outcome = "in_progress" | .resume_policy = "manual_recovery"
' "$output/parent-final-receipt.json" >"$output/initial-transition.json"
"$ROOT/scripts/record-join-receipt.sh" --receipt-dir "$output/receipts" --input "$output/initial-transition.json" >/dev/null
printf 'PASS separate consensus recovery inputs prepared run_id=%s parent_run_id=%s\n' "$new_id" "$parent_id"
