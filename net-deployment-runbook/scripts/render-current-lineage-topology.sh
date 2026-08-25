#!/usr/bin/env bash
set -Eeuo pipefail

# Render a portable, secret-free topology from JOIN receipts.  The observer
# never reads another operator's account directory; operators contribute only
# their sanitized receipts under its managed receipt inbox.
source "$(dirname "$0")/lib.sh"

CHAIN_BASE="${GDC_CHAIN_PUBLIC_BASE:-}"
[[ "$CHAIN_BASE" =~ ^https://[A-Za-z0-9.-]+$ ]] \
  || die 'GDC_CHAIN_PUBLIC_BASE must be an HTTPS public chain endpoint'
CHAIN_BASE="${CHAIN_BASE%/}"
RECEIPT_ROOT="$GDC_HOME/receipts/join"
OUTPUT="$STATE/lineage/current-topology.json"
RUN="$GDC_HOME/runs/${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-manual}/render-topology"
export EVIDENCE_PHASE_NAME=render-topology
mkdir -p "$RUN" "$(dirname "$OUTPUT")"

capture_canonical_genesis "$CHAIN_BASE/chain-rpc/genesis" "$RUN/genesis.json" \
  || die 'cannot read canonical Genesis while rendering topology'
GENESIS_SHA256="$(genesis_sha256 "$RUN/genesis.json")"
CHAIN_ID="$(jq -er .chain_id "$RUN/genesis.json")"
write_phase_lineage "$RUN" "$CHAIN_ID" "$GENESIS_SHA256"

shopt -s nullglob
receipts=("$RECEIPT_ROOT"/*/receipt.json)
shopt -u nullglob
[[ ! -s "$RECEIPT_ROOT/receipt.json" ]] || receipts+=("$RECEIPT_ROOT/receipt.json")
(( ${#receipts[@]} > 0 )) || die "no sanitized JOIN receipts in $RECEIPT_ROOT"

printf '[]' >"$RUN/participants.json"
for receipt in "${receipts[@]}"; do
  jq -e --arg genesis "$GENESIS_SHA256" --arg chain "$CHAIN_ID" '
    .schema_version == 1 and .verdict == "PASS"
    and .genesis_sha256 == $genesis and .chain_id == $chain
    and (.participant_address | type == "string" and length > 0)
    and (.validator_key | type == "string" and length > 0)
    and (.runtime_id == ("qwen3-0.6b:" + .participant_address))
    and (.public_host | test("^[A-Za-z0-9.-]+$"))
    and .poc_accepted_once == true
    and (.poc_participant_weight | tonumber) > 0
    and (.poc_accepted_weight_sum | tonumber) == (.poc_committed_total | tonumber)
    and (.poc_distribution_tx_code | tonumber) == 0
  ' "$receipt" >/dev/null \
    || die "receipt is not a current-lineage JOIN_PASS: $receipt"
  jq --slurpfile receipt "$receipt" '
    . + [$receipt[0] | {
      address:.participant_address, validator_key, runtime_id, public_host,
      run_id, runbook_commit, profile_hash, operator_mode,
      poc_accepted_epoch, poc_participant_weight, poc_accepted_weight_sum,
      poc_committed_total, poc_distribution_tx_hash, poc_distribution_tx_code
    }]
  ' "$RUN/participants.json" >"$RUN/participants.tmp"
  mv "$RUN/participants.tmp" "$RUN/participants.json"
done

jq -e '
  ([.[].address] | length) == ([.[].address] | unique | length)
  and ([.[].validator_key] | length) == ([.[].validator_key] | unique | length)
  and ([.[].runtime_id] | length) == ([.[].runtime_id] | unique | length)
' "$RUN/participants.json" >/dev/null \
  || die 'current-lineage JOIN receipts contain duplicate participant, validator, or runtime identities'

jq -n --arg chain_id "$CHAIN_ID" --arg genesis_sha256 "$GENESIS_SHA256" \
  --arg generated_at "$(date -u +%FT%TZ)" --slurpfile participants "$RUN/participants.json" \
  '{schema_version:1,chain_id:$chain_id,genesis_sha256:$genesis_sha256,
    generated_at:$generated_at,participants:($participants[0] | sort_by(.address))}' \
  >"$OUTPUT"
cp "$OUTPUT" "$RUN/current-topology.json"
printf 'PASS current-lineage topology: %s (%s participants)\n' "$OUTPUT" "$(jq length "$RUN/participants.json")"
