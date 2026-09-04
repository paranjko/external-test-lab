#!/usr/bin/env bash
# Stop the local runbook-owned signer and retain bounded proof of the stop.
set -Eeuo pipefail

[[ $# -eq 4 ]] || { echo "Usage: sudo $0 DEPLOY_DIR RUN_ID CONSENSUS_PUBKEY HOST_IDENTITY" >&2; exit 2; }
deploy="$1"; run_id="$2"; consensus_pubkey="$3"; host_identity="$4"
[[ $EUID -eq 0 && -d "$deploy" && -r "$deploy/.env" && -r "$deploy/compose.yaml" ]] \
  || { echo 'invalid signer-fence input' >&2; exit 2; }
[[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ && -n "$consensus_pubkey" && ${#consensus_pubkey} -le 256 && -n "$host_identity" && ${#host_identity} -le 256 ]] \
  || { echo 'invalid signer-fence identity binding' >&2; exit 2; }

if ! docker compose --env-file "$deploy/.env" -f "$deploy/compose.yaml" --profile signer stop tmkms; then
  echo 'signer_activation_unsafe: controlled TMKMS stop failed' >&2
  exit 1
fi
if ! running="$(docker compose --env-file "$deploy/.env" -f "$deploy/compose.yaml" ps -q tmkms)"; then
  echo 'signer_activation_unsafe: cannot inspect TMKMS after controlled stop' >&2
  exit 1
fi
[[ -z "$running" ]] || { echo 'signer_activation_unsafe: existing TMKMS remains running on the recovery Host' >&2; exit 1; }

evidence="$(docker compose --env-file "$deploy/.env" -f "$deploy/compose.yaml" ps --all tmkms)"
evidence_sha256="$(printf '%s\n' "$evidence" | sha256sum | awk '{print $1}')"
receipt_dir="$deploy/.gdc/runs/$run_id"
install -d -m 0700 "$receipt_dir"
temporary="$(mktemp "$receipt_dir/.signer-fence.XXXXXX")"
chmod 600 "$temporary"
jq -cn --arg run_id "$run_id" --arg consensus "$consensus_pubkey" --arg host "$host_identity" \
  --arg observed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg evidence "$evidence_sha256" \
  '{schema_version:1,kind:"gdc-signer-fence-receipt",run_id:$run_id,consensus_pubkey:$consensus,old_host_identity:$host,observed_at:$observed_at,method:"same_host_controlled_stop",controls:["compose_stop","process_readback"],old_signer_process_absent:true,old_signer_network_path_disabled:false,fence_height:0,evidence_sha256:$evidence}' >"$temporary"
sync -f "$temporary"
mv -f "$temporary" "$receipt_dir/signer-fence-receipt.v1.json"
sync -f "$receipt_dir"
printf 'PASS local runbook-owned TMKMS is fenced receipt=%s\n' "$receipt_dir/signer-fence-receipt.v1.json"
