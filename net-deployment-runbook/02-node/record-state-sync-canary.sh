#!/usr/bin/env bash
# Append a bounded, sanitized observation to the immutable preflight contract.
# This is deliberately not called "snapshot verified": CometBFT discovers
# snapshots over P2P and its RPC status endpoint does not disclose which
# provider or snapshot was selected. It proves only the facts we observed:
# the configured signerless canary caught up after its P2P-only configuration
# was validated.
set -Eeuo pipefail
[[ $# -eq 2 ]] || { echo "Usage: $0 DEPLOY_DIR RECEIPT" >&2; exit 2; }
deploy="$1"; receipt="$2"
[[ -d "$deploy" && -r "$receipt" ]] || { echo 'invalid canary receipt input' >&2; exit 2; }
jq -e '
  .kind == "gdc-host-join-lineage-preflight"
  and .bootstrap.mode == "state_sync"
  and .bootstrap.snapshot.discovery == "p2p_canary_pending"
  and (.bootstrap.snapshot.providers | type == "array" and length >= 2)
' "$receipt" >/dev/null || { echo 'lineage_verification_failed: receipt lacks the minimum two-provider P2P canary contract' >&2; exit 1; }
status="$(curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:26657/status)" \
  || { echo 'lineage_verification_failed: cannot read signerless canary status' >&2; exit 1; }
height="$(jq -er '.result.sync_info.latest_block_height | tonumber | select(. > 0)' <<<"$status")" \
  || { echo 'lineage_verification_failed: canary has no positive height' >&2; exit 1; }
catching_up="$(jq -r 'if .result.sync_info.catching_up == true then "true" elif .result.sync_info.catching_up == false then "false" else empty end' <<<"$status")" \
  || { echo 'lineage_verification_failed: canary has no sync status' >&2; exit 1; }
[[ "$catching_up" == false ]] || { echo 'lineage_verification_failed: canary is still catching up' >&2; exit 1; }
node_id="$(jq -er '.result.node_info.id // empty' <<<"$status")"
[[ "$node_id" =~ ^[0-9a-f]{40}$ ]] || { echo 'lineage_verification_failed: canary returned invalid node id' >&2; exit 1; }
tmp="${receipt}.tmp.$$"
jq --arg observed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg node_id "$node_id" --argjson height "$height" '
  .bootstrap.snapshot = {
    discovery: "p2p_canary_caught_up",
    providers: .bootstrap.snapshot.providers,
    observed_at: $observed_at,
    canary_node_id: $node_id,
    canary_height: $height
  }
  | .signer.state = "LINEAGE_VERIFIED"
  | .result.terminal_state = "canary_verified"
' "$receipt" >"$tmp"
mv "$tmp" "$receipt"
printf 'PASS recorded signerless P2P canary observation height=%s receipt=%s\n' "$height" "$receipt"
