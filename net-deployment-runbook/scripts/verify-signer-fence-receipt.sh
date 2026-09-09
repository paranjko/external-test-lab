#!/usr/bin/env bash
set -Eeuo pipefail

usage() { echo "Usage: $0 --receipt FILE --run-id ID --consensus-pubkey KEY [--replacement]" >&2; }
receipt=''; run_id=''; consensus_pubkey=''; replacement=false
while (($#)); do
  case "$1" in
    --receipt) receipt="${2:-}"; shift 2 ;;
    --run-id) run_id="${2:-}"; shift 2 ;;
    --consensus-pubkey) consensus_pubkey="${2:-}"; shift 2 ;;
    --replacement) replacement=true; shift ;;
    *) usage; exit 2 ;;
  esac
done
[[ -f "$receipt" && ! -L "$receipt" && "$(stat -c %a "$receipt")" == 600 && "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ && -n "$consensus_pubkey" ]] || { usage; exit 2; }
jq -e --arg run_id "$run_id" --arg consensus "$consensus_pubkey" '
  type == "object" and (keys | sort) == ["consensus_pubkey","controls","evidence_sha256","fence_height","kind","method","observed_at","old_host_identity","old_signer_network_path_disabled","old_signer_process_absent","run_id","schema_version"] and
  .schema_version == 1 and .kind == "gdc-signer-fence-receipt" and
  .run_id == $run_id and .consensus_pubkey == $consensus and
  (.old_host_identity | type == "string" and length > 0 and length <= 256) and
  (.method | IN("same_host_controlled_stop","remote_host_controlled_stop","infrastructure_hard_fence")) and
  (.controls | type == "array" and length > 0 and length <= 8 and unique and all(.[]; IN("power_off","service_disabled","network_acl","credentials_revoked","disk_detached","old_identity_removed","compose_stop","process_readback"))) and
  .old_signer_process_absent == true and (.old_signer_network_path_disabled | type == "boolean") and
  (.fence_height | type == "number" and floor == . and . >= 0) and
  (.evidence_sha256 | test("^[a-f0-9]{64}$"))
' "$receipt" >/dev/null || { echo 'invalid signer-fence receipt' >&2; exit 1; }
if [[ "$replacement" == true ]]; then
  # A digest asserted inside an operator-provided JSON document proves neither
  # its issuer nor the bytes it purports to describe.  Do not let that form
  # authorize a replacement validator until a separately reviewed remote or
  # infrastructure evidence acquisition protocol exists.
  echo 'replacement signer fence requires independently acquired prior-Host evidence; externally authored receipts are not accepted' >&2
  exit 1
fi
printf 'PASS verified signer-fence receipt=%s\n' "$receipt"
