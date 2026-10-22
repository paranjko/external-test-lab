#!/usr/bin/env bash
# Verify that an interrupted JOIN may safely continue from IDENTITY_READY.
# This helper is read-only; phase-join.sh consumes its validated public context.
set -Eeuo pipefail

usage() {
  echo 'Usage: verify-join-identity-ready-resume.sh NODE RUN_ID RUN_DIR PROFILE OBSERVATION BOOTSTRAP GENESIS IDENTITY ACCOUNT' >&2
  exit 2
}
[[ $# == 9 ]] || usage
node="$1"; run_id="$2"; run_dir="$3"; profile="$4"; observation="$5"
bootstrap="$6"; genesis="$7"; identity="$8"; account="$9"
[[ "${GDC_JOIN_RESUME:-false}" == true && "${GDC_JOIN_RESUME_IDENTITY_READY:-false}" == true ]] \
  || { echo 'identity-ready resume requires the internal same-run dispatcher context' >&2; exit 2; }
[[ "$node" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ && "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] \
  || usage
[[ -d "$run_dir" && ! -L "$run_dir" && -d "$run_dir/receipts" && ! -L "$run_dir/receipts" ]] \
  || { echo 'identity-ready resume run or receipt directory is missing or unsafe' >&2; exit 1; }
for file in "$profile" "$observation" "$bootstrap" "$genesis" "$identity" "$account"; do
  [[ -f "$file" && ! -L "$file" && -r "$file" ]] || { echo 'identity-ready resume input is missing or unsafe' >&2; exit 1; }
done
[[ "$(realpath -e -- "$profile")" == "$(realpath -e -- "$run_dir/join-profile.v1.json")" \
  && "$(realpath -e -- "$observation")" == "$(realpath -e -- "$run_dir/network-observation.v1.json")" ]] \
  || { echo 'identity-ready resume profile or observation is outside the retained run' >&2; exit 1; }
[[ -r "${GDC_JOIN_LINEAGE_RECEIPT:-}" && -f "$GDC_JOIN_LINEAGE_RECEIPT" && ! -L "$GDC_JOIN_LINEAGE_RECEIPT" \
  && "${GDC_JOIN_LINEAGE_RECEIPT_SHA256:-}" =~ ^[0-9a-f]{64}$ \
  && "$(sha256sum "$GDC_JOIN_LINEAGE_RECEIPT" | awk '{print $1}')" == "$GDC_JOIN_LINEAGE_RECEIPT_SHA256" ]] \
  || { echo 'identity-ready resume lineage receipt is missing, changed, or unsafe' >&2; exit 1; }
[[ -r "${STATE:-}/lineage-preflight.env" && -f "$STATE/lineage-preflight.env" && ! -L "$STATE/lineage-preflight.env" ]] \
  || { echo 'identity-ready resume lineage environment is missing or unsafe' >&2; exit 1; }

chain="$("$(dirname "${BASH_SOURCE[0]}")/verify-join-receipt-chain.sh" --receipt-dir "$run_dir/receipts")" \
  || { echo 'identity-ready resume receipt chain is invalid' >&2; exit 1; }
[[ "$(jq -er .last_state <<<"$chain")" == IDENTITY_READY \
  && "$(jq -er .signer_ever_started <<<"$chain")" == false ]] \
  || { echo 'identity-ready resume requires the signerless IDENTITY_READY boundary' >&2; exit 1; }
mapfile -t receipt_names < <(find "$run_dir/receipts" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.json' -printf '%f\n' | LC_ALL=C sort)
((${#receipt_names[@]} > 0)) || { echo 'identity-ready resume receipt chain is empty' >&2; exit 1; }
head="$run_dir/receipts/${receipt_names[-1]}"
profile_sha="$(sha256sum "$profile" | awk '{print $1}')"
observation_sha="$(sha256sum "$observation" | awk '{print $1}')"
jq -e --arg run "$run_id" --arg node "$node" --arg profile "$profile_sha" --arg observation "$observation_sha" '
  .run_id == $run and .generation_id == $run and .operation == "new" and .node_name == $node and
  .state == "IDENTITY_READY" and .signer_ever_started == false and
  .join_profile_sha256 == $profile and .network_observation_sha256 == $observation and
  (.identity_fingerprints.participant_address | type == "string" and test("^gonka1[0-9a-z]{20,90}$")) and
  (.identity_fingerprints.consensus_pubkey | type == "string" and test("^[A-Za-z0-9+/]{43}=$")) and
  (.identity_fingerprints.p2p_node_id | type == "string" and test("^[0-9a-f]{40}$")) and
  (.identity_fingerprints.warm_address | type == "string" and test("^gonka1[0-9a-z]{20,90}$"))
' "$head" >/dev/null || { echo 'identity-ready resume receipt does not bind this run and complete identity' >&2; exit 1; }

participant="$(jq -er .identity_fingerprints.participant_address "$head")"
node_id="$(jq -er .identity_fingerprints.p2p_node_id "$head")"
consensus="$(jq -er .identity_fingerprints.consensus_pubkey "$head")"
warm_address="$(jq -er .identity_fingerprints.warm_address "$head")"
jq -e --arg node "$node" --arg node_id "$node_id" --arg consensus "$consensus" --arg warm "$warm_address" '
  type == "object" and (keys | sort) == ["consensus_pubkey","node_id","node_name","warm_address","warm_pubkey_b64"] and
  .node_name == $node and .node_id == $node_id and .consensus_pubkey == $consensus and .warm_address == $warm and
  (.warm_pubkey_b64 | type == "string" and test("^[A-Za-z0-9+/]+=*$"))
' "$identity" >/dev/null || { echo 'retained local identity does not match the IDENTITY_READY receipt' >&2; exit 1; }
jq -e --arg address "$participant" '
  type == "object" and (.address | type == "string") and .address == $address
' "$account" >/dev/null || { echo 'retained cold account does not match the IDENTITY_READY participant' >&2; exit 1; }

profile_chain="$(jq -er '.spec.network.chain_id' "$profile")"
profile_genesis="$(jq -er '.spec.network.genesis_sha256' "$profile")"
profile_distribution="$(jq -er '.spec.network.bootstrap_genesis_sha256' "$profile")"
profile_bootstrap="$(jq -er '.spec.network.bootstrap_sha256' "$profile")"
bootstrap_sha="$(sha256sum "$bootstrap" | awk '{print $1}')"
genesis_distribution_sha="$(sha256sum "$genesis" | awk '{print $1}')"
genesis_canonical_sha="$(jq -eS '
  del(.app_name,.app_version)
  | if has("app_hash") then .app_hash=(.app_hash // "") else . end
  | if has("initial_height") then .initial_height=(.initial_height|tostring) else . end
  | if .consensus.params? then .consensus_params=.consensus.params | del(.consensus) else . end
' "$genesis" | sha256sum | awk '{print $1}')"
[[ "${GDC_JOIN_BOOTSTRAP_SHA256:-}" == "$profile_bootstrap" \
  && "$bootstrap_sha" == "$profile_bootstrap" \
  && "$genesis_distribution_sha" == "$profile_distribution" \
  && "$genesis_canonical_sha" == "$profile_genesis" \
  && "$(jq -er .chain_id "$bootstrap")" == "$profile_chain" \
  && "$(jq -er .genesis.sha256 "$bootstrap")" == "$profile_distribution" \
  && "$(jq -er .chain_id "$genesis")" == "$profile_chain" ]] \
  || { echo 'retained profile, Bootstrap, and staged Genesis no longer have exact matching pins' >&2; exit 1; }
jq -e --arg chain "$profile_chain" --arg genesis "$profile_genesis" --arg distribution "$profile_distribution" \
  --arg bootstrap "$profile_bootstrap" '
  .spec.network.chain_id == $chain and .spec.network.genesis_sha256 == $genesis and
  .spec.network.bootstrap_genesis_sha256 == $distribution and .spec.network.bootstrap_sha256 == $bootstrap
' "$profile" >/dev/null || { echo 'retained JOIN profile does not bind the selected Genesis and Bootstrap' >&2; exit 1; }
jq -e --arg chain "$profile_chain" --arg genesis "$profile_genesis" '
  .bootstrap.chain_id == $chain and .bootstrap.genesis_sha256 == $genesis
' "$GDC_JOIN_LINEAGE_RECEIPT" >/dev/null \
  || { echo 'retained lineage receipt does not match the selected chain identity' >&2; exit 1; }
[[ "$(jq -er '.bootstrap_mode' "$bootstrap")" == genesis-single-seed \
  && "$(jq -er '.seeds | length' "$bootstrap")" == 1 ]] \
  || { echo 'IDENTITY_READY continuation supports only the explicit single-seed full-sync Bootstrap' >&2; exit 1; }
seed_node="$(jq -er '.seeds[0].node_id' "$bootstrap")"
seed_rpc="$(jq -er '.seeds[0].rpc | rtrimstr("/")' "$bootstrap")"
seed_p2p="$(jq -er '.seeds[0].p2p' "$bootstrap")"
jq -e --arg chain "$profile_chain" --arg genesis "$profile_genesis" --arg distribution "$profile_distribution" \
  --arg node "$seed_node" --arg rpc "$seed_rpc" --arg p2p "$seed_p2p" '
  .bootstrap == {mode:"full_sync",chain_id:$chain,genesis_sha256:$genesis,distribution_sha256:$distribution,
    seed:{node_id:$node,rpc_url:$rpc,p2p:$p2p}} and
  .trust_authority == {kind:"genesis_single_seed",rpc_url:$rpc} and
  (.runtime.observation_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
  (.fault_domains | length) == 1 and .fault_domains[0].id == "genesis-single-seed" and
  .fault_domains[0].rpc_url == $rpc and .fault_domains[0].chain_id == $chain and
  .fault_domains[0].genesis_sha256 == $genesis and .checkpoints == null
' "$GDC_JOIN_LINEAGE_RECEIPT" >/dev/null \
  || { echo 'retained lineage receipt does not prove the exact single-seed full-sync authority' >&2; exit 1; }

remote_output="$(ssh -T "$node" "sudo -n bash -s -- '$node' '$node_id' '$consensus' '$profile_chain'" \
  <"$(dirname "${BASH_SOURCE[0]}")/check-join-identity-ready-target.sh" 2>&1)" || {
  [[ -z "$remote_output" ]] || printf '%s\n' "$remote_output" >&2
  echo 'fresh remote IDENTITY_READY boundary check failed; no render or install was attempted' >&2
  exit 1
}
grep -Fxq "PASS JOIN IDENTITY_READY target verified node=$node; no deployment, chain state, or signature found" <<<"$remote_output" \
  || { echo 'fresh remote IDENTITY_READY boundary did not return its exact success receipt' >&2; exit 1; }

jq -cn --arg participant "$participant" --arg node_id "$node_id" --arg consensus "$consensus" \
  --arg warm_address "$warm_address" --arg chain "$profile_chain" --arg genesis "$profile_genesis" \
  '{participant_address:$participant,node_id:$node_id,consensus_pubkey:$consensus,warm_address:$warm_address,chain_id:$chain,genesis_sha256:$genesis,remote_boundary:"clean_identity_ready"}'
