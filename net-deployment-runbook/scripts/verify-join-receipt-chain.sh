#!/bin/sh
# Verify the append-only, local Host JOIN transition receipt chain.
set -eu
usage() { echo "Usage: $0 --receipt-dir DIR" >&2; }
RECEIPT_DIR=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --receipt-dir) [ "$#" -ge 2 ] || { usage; exit 2; }; RECEIPT_DIR=$2; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[ -n "$RECEIPT_DIR" ] && [ -d "$RECEIPT_DIR" ] || { usage; exit 2; }
ROOT=$(CDPATH='' cd -P "$(dirname "$0")/.." && pwd -P)
. "$ROOT/scripts/portable.sh"
gdc_require_jq || exit $?
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
receipt_tmp=$(gdc_mktemp_dir)
trap 'rm -rf "$receipt_tmp"' EXIT HUP INT TERM
: >"$receipt_tmp/names"
for receipt_path in "$RECEIPT_DIR"/*.json; do
  [ -f "$receipt_path" ] || continue
  receipt_name=${receipt_path##*/}
  printf '%s\n' "$receipt_name" | grep -Eq '^[0-9]{4}-[a-z0-9_]+\.json$' || { echo "invalid JOIN receipt filename: $receipt_name" >&2; exit 1; }
  printf '%s\n' "$receipt_name" >>"$receipt_tmp/names"
done
[ -s "$receipt_tmp/names" ] || { echo 'JOIN receipt chain is empty' >&2; exit 1; }
LC_ALL=C sort "$receipt_tmp/names" >"$receipt_tmp/sorted"
previous_sha=''; signer_started=false; immutable=''; established_identity=''; previous_rank=0; expected=1; receipt_count=0; last_state=''
while IFS= read -r receipt_name; do
  receipt="$RECEIPT_DIR/$receipt_name"
  [ "$(gdc_file_mode "$receipt")" = 600 ] || { echo "JOIN receipt does not have mode 0600: $receipt_name" >&2; exit 1; }
  jq -e --argjson expected "$expected" --arg previous "$previous_sha" '
    type == "object" and .schema_version == 2 and .kind == "gdc-host-join-receipt" and .sequence == $expected and
    (keys | sort) == (if $expected == 1 then
      ["evidence","generation_id","identity_fingerprints","join_profile_sha256","kind","network_observation_sha256","node_name","operation","outcome","recorded_at","resume_policy","run_id","schema_version","sequence","signer_ever_started","state","tmkms_state"]
    else
      ["evidence","generation_id","identity_fingerprints","join_profile_sha256","kind","network_observation_sha256","node_name","operation","outcome","previous_receipt_sha256","recorded_at","resume_policy","run_id","schema_version","sequence","signer_ever_started","state","tmkms_state"]
    end) and ($expected == 1 or .previous_receipt_sha256 == $previous) and
    (.run_id | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")) and (.operation == "new" or .operation == "restore") and
    (.node_name | test("^[a-z0-9][a-z0-9_-]{0,62}$")) and (.join_profile_sha256 | test("^[a-f0-9]{64}$")) and
    (.network_observation_sha256 | test("^[a-f0-9]{64}$")) and (.generation_id | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")) and
    (.signer_ever_started | type == "boolean") and
    (.tmkms_state | type == "object" and (keys | sort) == ["block_id","height","round","step"] and (.height | type == "number" and . >= 0 and floor == .) and (.round | type == "number" and . >= 0 and floor == .) and (.step | type == "number" and . >= 0 and floor == .) and (.block_id | test("^[a-f0-9]{0,64}$"))) and
    (.identity_fingerprints | type == "object" and (keys | sort) == ["consensus_pubkey","p2p_node_id","participant_address","warm_address"] and (.p2p_node_id | test("^$|^[a-f0-9]{40}$"))) and
    (.evidence | type == "array" and length <= 16 and all(.[]; type == "object" and (keys | sort) == ["kind","sha256"] and (.kind | test("^[a-z][a-z0-9_-]{0,63}$")) and (.sha256 | test("^[a-f0-9]{64}$")))) and
    (.outcome | IN("in_progress","succeeded","no_op","refused","failed","manual_recovery_required")) and
    (.resume_policy | IN("resume_same_run","new_profile","manual_recovery","automatic_retry_forbidden","not_applicable"))
  ' "$receipt" >/dev/null || { echo "invalid or tampered JOIN receipt: $receipt_name" >&2; exit 1; }
  current_immutable=$(jq -cS '{run_id,operation,node_name,join_profile_sha256,network_observation_sha256,generation_id}' "$receipt")
  if [ -z "$immutable" ]; then immutable=$current_immutable; elif [ "$current_immutable" != "$immutable" ]; then echo "JOIN receipt immutable binding changed: $receipt_name" >&2; exit 1; fi
  current_identity=$(jq -cS .identity_fingerprints "$receipt")
  if [ -n "$established_identity" ]; then jq -en --argjson previous "$established_identity" --argjson next "$current_identity" '["participant_address", "consensus_pubkey", "p2p_node_id", "warm_address"] | all(.[]; $previous[.] == "" or $previous[.] == $next[.])' | grep -qx true || { echo "JOIN receipt established identity changed: $receipt_name" >&2; exit 1; }; fi
  established_identity=$current_identity
  current_signer=$(jq -r .signer_ever_started "$receipt")
  [ "$signer_started" != true ] || [ "$current_signer" = true ] || { echo "JOIN receipt signer_ever_started regressed: $receipt_name" >&2; exit 1; }
  [ "$current_signer" = true ] && signer_started=true
  current_rank=$(state_rank "$(jq -r .state "$receipt")")
  [ "$current_rank" -gt "$previous_rank" ] || { echo "JOIN receipt lifecycle state regressed or repeated: $receipt_name" >&2; exit 1; }
  previous_rank=$current_rank
  previous_sha=$(gdc_sha256 "$receipt")
  last_state=$(jq -r .state "$receipt")
  expected=$((expected + 1))
  receipt_count=$((receipt_count + 1))
done <"$receipt_tmp/sorted"
jq -cn --arg head_sha256 "$previous_sha" --argjson receipt_count "$receipt_count" --arg last_state "$last_state" --argjson signer_ever_started "$signer_started" '{head_sha256:$head_sha256,receipt_count:$receipt_count,last_state:$last_state,signer_ever_started:$signer_ever_started}'
