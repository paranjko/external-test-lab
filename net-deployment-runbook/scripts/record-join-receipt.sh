#!/usr/bin/env bash
# Append one immutable, secret-safe GDC Host JOIN transition receipt.
set -Eeuo pipefail

usage() { echo "Usage: $0 --receipt-dir DIR --input FILE" >&2; }
RECEIPT_DIR=''; INPUT=''
while (($#)); do
  case "$1" in
    --receipt-dir) RECEIPT_DIR="${2:-}"; shift 2 ;;
    --input) INPUT="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ -n "$RECEIPT_DIR" && -r "$INPUT" ]] || { usage; exit 2; }
command -v jq >/dev/null || { echo 'jq is required to record a JOIN receipt' >&2; exit 2; }

state_rank() {
  case "$1" in
    RUN_CREATED) echo 10 ;; BOOTSTRAP_VERIFIED) echo 20 ;; NETWORK_OBSERVED) echo 30 ;;
    JOIN_PROFILE_READY) echo 40 ;; TARGET_CLASSIFIED) echo 50 ;; HOST_BASE_PREPARED) echo 60 ;;
    IDENTITY_READY) echo 70 ;; CANDIDATE_RENDERED) echo 80 ;; CANARY_RUNNING) echo 90 ;;
    CANARY_CAUGHT_UP) echo 100 ;; CANARY_VERIFIED) echo 110 ;; CANARY_STOPPED) echo 120 ;;
    PROMOTION_PREPARED) echo 130 ;; PROMOTING) echo 140 ;; PROMOTED) echo 150 ;;
    CANONICAL_RUNNING) echo 160 ;; CANONICAL_VERIFIED) echo 170 ;; APPLICATION_ACTIVE) echo 180 ;;
    MEMBERSHIP_RECONCILED) echo 190 ;; PERMISSIONS_RECONCILED) echo 200 ;; SIGNER_FENCE_VERIFIED) echo 210 ;;
    SIGNER_ACTIVATING) echo 220 ;; SIGNER_ACTIVE_VERIFIED) echo 230 ;; ACTIVE_CONFIRMED) echo 240 ;;
    RECOVERY_ARCHIVE_VERIFIED) echo 250 ;; COMPLETE) echo 260 ;; REFUSED|FAILED) echo 270 ;;
    *) return 1 ;;
  esac
}

# Input intentionally excludes sequence, timestamp and the parent hash. This
# prevents a caller from forging a receipt-chain position or a prior receipt.
jq -e '
  type == "object" and
  (keys | sort) == ["evidence","generation_id","identity_fingerprints","join_profile_sha256","kind","network_observation_sha256","node_name","operation","outcome","resume_policy","run_id","schema_version","signer_ever_started","state","tmkms_state"] and
  .schema_version == 2 and .kind == "gdc-host-join-receipt" and
  (.run_id | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")) and
  (.operation == "new" or .operation == "restore") and
  (.node_name | test("^[a-z0-9][a-z0-9_-]{0,62}$")) and
  (.state | IN("RUN_CREATED","BOOTSTRAP_VERIFIED","NETWORK_OBSERVED","JOIN_PROFILE_READY","TARGET_CLASSIFIED","HOST_BASE_PREPARED","IDENTITY_READY","CANDIDATE_RENDERED","CANARY_RUNNING","CANARY_CAUGHT_UP","CANARY_VERIFIED","CANARY_STOPPED","PROMOTION_PREPARED","PROMOTING","PROMOTED","CANONICAL_RUNNING","CANONICAL_VERIFIED","APPLICATION_ACTIVE","MEMBERSHIP_RECONCILED","PERMISSIONS_RECONCILED","SIGNER_FENCE_VERIFIED","SIGNER_ACTIVATING","SIGNER_ACTIVE_VERIFIED","ACTIVE_CONFIRMED","RECOVERY_ARCHIVE_VERIFIED","COMPLETE","REFUSED","FAILED")) and
  (.join_profile_sha256 | test("^[a-f0-9]{64}$")) and
  (.network_observation_sha256 | test("^[a-f0-9]{64}$")) and
  (.generation_id | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")) and
  (.identity_fingerprints | type == "object" and (keys | sort) == ["consensus_pubkey","p2p_node_id","participant_address","warm_address"] and (.p2p_node_id | test("^$|^[a-f0-9]{40}$"))) and
  (.signer_ever_started | type == "boolean") and
  (.tmkms_state | type == "object" and (keys | sort) == ["block_id","height","round","step"] and (.height | type == "number" and . >= 0 and floor == .) and (.round | type == "number" and . >= 0 and floor == .) and (.step | type == "number" and . >= 0 and floor == .) and (.block_id | test("^[a-f0-9]{0,64}$"))) and
  (.evidence | type == "array" and length <= 16 and all(.[]; type == "object" and (keys | sort) == ["kind","sha256"] and (.kind | test("^[a-z][a-z0-9_-]{0,63}$")) and (.sha256 | test("^[a-f0-9]{64}$")))) and
  (.outcome | IN("in_progress","succeeded","no_op","refused","failed","manual_recovery_required")) and
  (.resume_policy | IN("resume_same_run","new_profile","manual_recovery","automatic_retry_forbidden","not_applicable"))
' "$INPUT" >/dev/null || { echo 'invalid JOIN transition receipt input' >&2; exit 2; }

umask 077
mkdir -p "$RECEIPT_DIR"
if find "$RECEIPT_DIR" -maxdepth 1 -type f -name '*.json' -print -quit | grep -q .; then
  "$(dirname "$0")/verify-join-receipt-chain.sh" --receipt-dir "$RECEIPT_DIR" >/dev/null
fi
mapfile -t receipts < <(find "$RECEIPT_DIR" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-*.json' -printf '%f\n' | LC_ALL=C sort)
sequence=$(( ${#receipts[@]} + 1 ))
previous=''
if (( sequence > 1 )); then
  previous_file="$RECEIPT_DIR/${receipts[-1]}"
  previous="$(sha256sum "$previous_file" | awk '{print $1}')"
  jq -e --arg expected "$previous" --argjson expected_sequence "$((sequence - 1))" '
    .sequence == $expected_sequence
  ' "$previous_file" >/dev/null || { echo 'latest JOIN receipt is invalid or tampered' >&2; exit 1; }
  previous_signer="$(jq -r .signer_ever_started "$previous_file")"
  next_signer="$(jq -r .signer_ever_started "$INPUT")"
  [[ "$previous_signer" != true || "$next_signer" == true ]] || { echo 'JOIN receipt would regress signer_ever_started' >&2; exit 1; }
  previous_rank="$(state_rank "$(jq -r .state "$previous_file")")"
  next_rank="$(state_rank "$(jq -r .state "$INPUT")")"
  (( next_rank > previous_rank )) || { echo 'JOIN receipt would regress or repeat lifecycle state' >&2; exit 1; }
  # A receipt chain is the authority for one operation only. Refuse a caller
  # that tries to append a valid-looking transition for another observed
  # network, profile, identity operation or generation.
  previous_binding="$(jq -cS '{run_id,operation,node_name,join_profile_sha256,network_observation_sha256,generation_id}' "$previous_file")"
  next_binding="$(jq -cS '{run_id,operation,node_name,join_profile_sha256,network_observation_sha256,generation_id}' "$INPUT")"
  [[ "$previous_binding" == "$next_binding" ]] || { echo 'JOIN receipt would change the immutable run binding' >&2; exit 1; }
  previous_identity="$(jq -cS .identity_fingerprints "$previous_file")"
  next_identity="$(jq -cS .identity_fingerprints "$INPUT")"
  jq -en --argjson previous "$previous_identity" --argjson next "$next_identity" '
    ["participant_address", "consensus_pubkey", "p2p_node_id", "warm_address"]
    | all(.[]; $previous[.] == "" or $previous[.] == $next[.])
  ' | grep -qx true || { echo 'JOIN receipt would change an established identity fingerprint' >&2; exit 1; }
fi

basename="$(printf '%04d-%s.json' "$sequence" "$(jq -r .state "$INPUT" | tr '[:upper:]' '[:lower:]')")"
destination="$RECEIPT_DIR/$basename"
[[ ! -e "$destination" ]] || { echo 'JOIN receipt sequence collision' >&2; exit 1; }
temporary="$(mktemp "$RECEIPT_DIR/.join-receipt.XXXXXX")"
chmod 600 "$temporary"
jq -cS --arg recorded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg previous "$previous" --argjson sequence "$sequence" '
  . + {sequence:$sequence, recorded_at:$recorded_at}
  | if $previous == "" then . else . + {previous_receipt_sha256:$previous} end
' "$INPUT" >"$temporary"
sync -f "$temporary"
mv -f "$temporary" "$destination"
sync -f "$RECEIPT_DIR"
printf '%s\n' "$destination"
