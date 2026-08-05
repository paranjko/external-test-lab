#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 3 ]] || { echo "Usage: $0 genesis.json genesis.sha256 expected-chain-id" >&2; exit 2; }
GENESIS="$1"; HASH_FILE="$2"; CHAIN_ID="$3"
(cd "$(dirname "$GENESIS")" && sha256sum -c "$(basename "$HASH_FILE")")
jq -e --arg chain "$CHAIN_ID" '
 .chain_id==$chain and
 (.app_state.inference.participant_list|length)==1 and
 (.app_state.genutil.gen_txs|length)==1 and
 (.app_state.bank.denom_metadata | length)==1 and
 .app_state.bank.denom_metadata[0].base=="ngonka" and
 (.app_state.bank.denom_metadata[0].denom_units | map(select(.denom=="gonka" and .exponent==9)) | length)==1 and
 [.app_state.inference.model_list[].id]==["Qwen/Qwen3-0.6B"] and
 .app_state.inference.params.epoch_params.epoch_length=="50" and
 .app_state.inference.params.epoch_params.epoch_shift=="0" and
 .app_state.inference.params.poc_params.poc_v2_enabled==true and
 .app_state.inference.params.devshard_escrow_params.allowed_creator_addresses == [] and
 .app_state.inference.params.devshard_escrow_params.approved_versions == []
' "$GENESIS" >/dev/null
printf 'Genesis structure: PASS\n'
