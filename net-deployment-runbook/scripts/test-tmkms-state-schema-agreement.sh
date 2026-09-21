#!/usr/bin/env bash
# Every program that judges a TMKMS signing state gives one verdict; the liveness reader may accept more, never less.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Gating readers, file|anchor: the anchor is the line before the jq program.
GATES=(
  "scripts/validator-backup.sh|validate_tmkms_state() {"
  "scripts/verify-tmkms-signing-state.sh|validate_state() {"
  "scripts/build-validator-identity-restore-command.sh|validate_tmkms_state() {"
  "scripts/same-host-restore.sh|validate_tmkms_state() {"
)
LENIENT=(
  "02-node/verify-active-signer-state.sh|state=\"\$signer_dir/tmkms/state/priv_validator_state.json\""
)
# Receipt summaries share the keys but describe another object.
RECEIPTS=(
  "scripts/record-join-receipt.sh"
  "scripts/verify-join-receipt-chain.sh"
)

signature='and (keys | sort) == ["block_id","height","round","step"]'
mapfile -t carriers < <(grep -rlF "$signature" "$ROOT/scripts" "$ROOT/02-node" 2>/dev/null | sed "s#^$ROOT/##" | sort -u)
mapfile -t known < <(printf '%s\n' "${GATES[@]%%|*}" "${LENIENT[@]%%|*}" "${RECEIPTS[@]}" \
  "scripts/test-tmkms-state-schema-agreement.sh" | sort -u)
if [[ "$(printf '%s\n' "${carriers[@]}")" != "$(printf '%s\n' "${known[@]}")" ]]; then
  echo 'the signing-state schema moved: these files carry it, and the contract knows the second list' >&2
  printf '  carrier: %s\n' "${carriers[@]}" >&2
  printf '  known:   %s\n' "${known[@]}" >&2
  exit 1
fi
for file in "${RECEIPTS[@]}"; do
  grep -Fq '.tmkms_state | type == "object"' "$ROOT/$file" \
    || { echo "$file no longer validates the receipt summary; it may now read the state file itself" >&2; exit 1; }
done

# Lift the jq program after the anchor, up to its closing quote.
extract_program() {
  local file="$1" anchor="$2"
  awk -v anchor="$anchor" '
    BEGIN { q = sprintf("%c", 39) }
    !past && index($0, anchor) { past = 1; next }
    past && index($0, "jq -e " q) { in_jq = 1; next }
    in_jq && $0 ~ ("^[[:space:]]*" q) { exit }
    in_jq { print }
  ' "$file"
}

state() { printf '%s\n' "$2" >"$tmp/$1.json"; }
hash_a=A330F26A1EA7BD401EEA630A872341DD2FAA4DDEB5A6AA6384919DBB6D0404F4
hash_b=D01B743F07D5F6448B863E15F70A25F9CA2520306D1AB2857EDA7405E94C60EE

# Accepted, the never-signed empty block_id form included.
state never_signed_empty '{"height":"0","round":"0","step":0,"block_id":{"hash":"","part_set_header":{"total":0,"hash":""}}}'
state never_signed_parts '{"height":"0","round":"0","step":0,"block_id":{"hash":"","parts":{"total":0,"hash":""}}}'
state never_signed_null  '{"height":"0","round":"0","step":0,"block_id":null}'
state signed             "{\"height\":\"398186\",\"round\":\"0\",\"step\":2,\"block_id\":{\"hash\":\"$hash_a\",\"part_set_header\":{\"total\":1,\"hash\":\"$hash_b\"}}}"
state signed_parts_alias "{\"height\":\"12\",\"round\":\"1\",\"step\":3,\"block_id\":{\"hash\":\"$hash_a\",\"parts\":{\"total\":1,\"hash\":\"$hash_b\"}}}"
state signed_total_max   "{\"height\":\"12\",\"round\":\"0\",\"step\":2,\"block_id\":{\"hash\":\"$hash_a\",\"part_set_header\":{\"total\":4294967295,\"hash\":\"$hash_b\"}}}"

# Refused. Shapes no signer of this network writes.
state round_is_number      '{"height":"7","round":0,"step":2,"block_id":null}'
state step_out_of_range    '{"height":"7","round":"0","step":300,"block_id":null}'
state extra_key            '{"height":"7","round":"0","step":2,"block_id":null,"signature":"AA=="}'
state missing_block_id     '{"height":"7","round":"0","step":2}'
state short_hash           '{"height":"7","round":"0","step":2,"block_id":{"hash":"AABB","part_set_header":{"total":1,"hash":"AABB"}}}'
state empty_form_at_height '{"height":"9","round":"0","step":2,"block_id":{"hash":"","part_set_header":{"total":0,"hash":""}}}'
state empty_form_extra_key '{"height":"0","round":"0","step":0,"block_id":{"hash":"","part_set_header":{"total":0,"hash":""},"note":"x"}}'
state empty_form_nonzero_total '{"height":"0","round":"0","step":0,"block_id":{"hash":"","part_set_header":{"total":1,"hash":""}}}'
state signed_total_over  "{\"height\":\"12\",\"round\":\"0\",\"step\":2,\"block_id\":{\"hash\":\"$hash_a\",\"part_set_header\":{\"total\":4294967296,\"hash\":\"$hash_b\"}}}"

EXPECTED=(
  never_signed_empty:accept
  never_signed_parts:accept
  never_signed_null:accept
  signed:accept
  signed_parts_alias:accept
  signed_total_max:accept
  round_is_number:refuse
  step_out_of_range:refuse
  extra_key:refuse
  missing_block_id:refuse
  short_hash:refuse
  empty_form_at_height:refuse
  empty_form_extra_key:refuse
  empty_form_nonzero_total:refuse
  signed_total_over:refuse
)

verdict() { # program, fixture
  if jq -e "$1" "$tmp/$2.json" >/dev/null 2>&1; then printf 'accept\n'; else printf 'refuse\n'; fi
}

failures=0
for site in "${GATES[@]}"; do
  file="$ROOT/${site%%|*}"
  program="$(extract_program "$file" "${site##*|}")"
  [[ -n "$program" ]] || { echo "cannot lift the schema out of ${site%%|*}" >&2; exit 1; }
  for pair in "${EXPECTED[@]}"; do
    name="${pair%%:*}"
    want="${pair##*:}"
    got="$(verdict "$program" "$name")"
    [[ "$got" == "$want" ]] || {
      printf 'FAIL %s: %s should %s, got %s\n' "${site%%|*}" "$name" "$want" "$got" >&2
      failures=$((failures + 1))
    }
  done
done

for site in "${LENIENT[@]}"; do
  file="$ROOT/${site%%|*}"
  program="$(extract_program "$file" "${site##*|}")"
  [[ -n "$program" ]] || { echo "cannot lift the schema out of ${site%%|*}" >&2; exit 1; }
  for pair in "${EXPECTED[@]}"; do
    name="${pair%%:*}"
    [[ "${pair##*:}" == accept ]] || continue
    [[ "$(verdict "$program" "$name")" == accept ]] || {
      printf 'FAIL %s refuses %s, which every gating validator accepts\n' "${site%%|*}" "$name" >&2
      failures=$((failures + 1))
    }
  done
done

(( failures == 0 )) || { printf '%d disagreement(s) about the TMKMS signing state schema\n' "$failures" >&2; exit 1; }

# The Host-side refusal names its subject and the failing clause.
restore="$ROOT/scripts/build-validator-identity-restore-command.sh"
# shellcheck source=/dev/null
source <(sed -n '/^validate_tmkms_state()/,/^}/p;/^tmkms_state_defect()/,/^}/p' "$restore")
# shellcheck source=/dev/null
source <(sed -n '/^scan_public_text()/,/^}/p' "$ROOT/scripts/gdc-report-github.sh")
die() { printf 'error: %s\n' "$*" >&2; exit 2; }
refusal_of() { # fixture, subject
  { ( validate_tmkms_state "$tmp/$1.json" "$2" ) >/dev/null; } 2>&1 || true
}
for subject in 'the staged archive copy' 'the stable signer on the Host' 'the running deployment on the Host'; do
  grep -Fq "\"$subject\"" "$restore" || { echo "the restore program no longer names: $subject" >&2; exit 1; }
done
message="$(refusal_of round_is_number 'the staged archive copy')"
[[ "$message" == 'error: validator identity contains malformed TMKMS signing state (the staged archive copy): round' ]] \
  || { printf 'unexpected refusal text: %s\n' "$message" >&2; exit 1; }
[[ "$(refusal_of step_out_of_range 'the stable signer on the Host')" == *'(the stable signer on the Host): step' ]]
[[ "$(refusal_of extra_key x)" == *': unexpected key set' ]]
[[ "$(refusal_of short_hash x)" == *': block_id' ]]
[[ -z "$(refusal_of signed x)" ]]
printf '%s\n' "$message" >"$tmp/refusal.txt"
scan_public_text "$tmp/refusal.txt" \
  || { echo 'the refusal text would be withheld from a published report' >&2; exit 1; }
printf 'PASS one verdict on the TMKMS signing state across %d gating validators and %d lenient reader(s), %d states each\n' \
  "${#GATES[@]}" "${#LENIENT[@]}" "${#EXPECTED[@]}"
