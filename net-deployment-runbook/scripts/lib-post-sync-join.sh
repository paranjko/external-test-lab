#!/usr/bin/env bash
# One invocation boundary for the post-promotion signerless runtime proof.
# Callers retain their own receipt transition authority; this helper only
# passes the profile-bound runtime expectation to the verifier.

join_verify_promoted_signerless_state() {
  [[ $# -eq 10 ]] || {
    echo 'post-sync JOIN verifier requires ten bound inputs' >&2
    return 2
  }
  local node="$1" run="$2" profile="$3" remote="$4" chain_id="$5" p2p_node_id="$6"
  local core_version="$7" core_commit="$8" dapi_version="$9" dapi_commit="${10}"
  "$ROOT/scripts/verify-post-sync-join-state.sh" \
    --node "$node" --run-dir "$run" --profile "$profile" --remote-dir "$remote" \
    --expected-chain-id "$chain_id" --expected-p2p-node-id "$p2p_node_id" \
    --expected-core-version "$core_version" --expected-core-commit "$core_commit" \
    --expected-dapi-version "$dapi_version" --expected-dapi-commit "$dapi_commit"
}
# Publish only the auxiliary services that are safe after the signerless
# promoted generation has passed its current-checkpoint proof. This is shared
# by uninterrupted JOIN and its retained canonical continuations.
join_start_verified_auxiliary_services() {
  [[ $# -eq 2 ]] || {
    echo 'post-sync auxiliary service start requires node and public edge node' >&2
    return 2
  }
  local node="$1" public_edge_node="$2"
  if [[ "$node" != "$public_edge_node" ]]; then
    start_stack "$node" /srv/dai/deploy/edge caddy
  else
    printf 'READY retained shared public edge on %s during participant JOIN\n' "$node"
  fi
  start_stack "$node" /srv/dai/deploy/monitoring-agent
}
