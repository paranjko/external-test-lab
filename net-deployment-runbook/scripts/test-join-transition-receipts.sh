#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
receipts="$tmp/receipts"
profile="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
observation="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
evidence="cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

jq -e '.additionalProperties == false and .properties.schema_version.const == 2 and .properties.kind.const == "gdc-host-join-receipt" and (.required | index("previous_receipt_sha256") | not)' "$ROOT/lineage/join-receipt.v2.schema.json" >/dev/null
jq -e '.additionalProperties == false and .properties.schema_version.const == 1 and .properties.kind.const == "gdc-signer-fence-receipt" and .properties.old_signer_process_absent.const == true' "$ROOT/lineage/signer-fence-receipt.v1.schema.json" >/dev/null
jq -e '.additionalProperties == false and .properties.schema_version.const == 1 and .properties.kind.const == "gdc-host-join-result"' "$ROOT/lineage/join-result.v1.schema.json" >/dev/null

input() {
  local state="$1" signer="$2"
  jq -cn --arg state "$state" --arg profile "$profile" --arg observation "$observation" --arg evidence "$evidence" --argjson signer "$signer" '
    {schema_version:2,kind:"gdc-host-join-receipt",run_id:"fixture-run",operation:"restore",node_name:"node9",state:$state,join_profile_sha256:$profile,network_observation_sha256:$observation,generation_id:"fixture-generation",identity_fingerprints:{participant_address:"gonka1fixture",consensus_pubkey:"gonvalconspub1fixture",p2p_node_id:"0123456789abcdef0123456789abcdef01234567",warm_address:"gonka1warm"},signer_ever_started:$signer,tmkms_state:{height:1,round:0,step:0,block_id:""},evidence:[{kind:"fixture",sha256:$evidence}],outcome:"in_progress",resume_policy:"resume_same_run"}'
}

input RUN_CREATED false >"$tmp/first.json"
first="$($ROOT/scripts/record-join-receipt.sh --receipt-dir "$receipts" --input "$tmp/first.json")"
[[ "$first" == "$receipts/0001-run_created.json" && "$(stat -c %a "$first")" == 600 ]]
jq -e '.sequence == 1 and (has("previous_receipt_sha256") | not) and .signer_ever_started == false' "$first" >/dev/null

input SIGNER_ACTIVATING true >"$tmp/second.json"
second="$($ROOT/scripts/record-join-receipt.sh --receipt-dir "$receipts" --input "$tmp/second.json")"
first_sha="$(sha256sum "$first" | awk '{print $1}')"
jq -e --arg first_sha "$first_sha" '.sequence == 2 and .previous_receipt_sha256 == $first_sha and .signer_ever_started == true' "$second" >/dev/null
chain="$($ROOT/scripts/verify-join-receipt-chain.sh --receipt-dir "$receipts")"
jq -e --arg second_sha "$(sha256sum "$second" | awk '{print $1}')" '.receipt_count == 2 and .head_sha256 == $second_sha and .signer_ever_started == true' <<<"$chain" >/dev/null
cp "$second" "$tmp/second.saved"
jq '.identity_fingerprints.p2p_node_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$second" >"$tmp/identity-tampered.json"
chmod 600 "$tmp/identity-tampered.json"
mv "$tmp/identity-tampered.json" "$second"
if "$ROOT/scripts/verify-join-receipt-chain.sh" --receipt-dir "$receipts" >"$tmp/identity-verify.out" 2>"$tmp/identity-verify.err"; then
  echo 'receipt chain with changed established identity unexpectedly verified' >&2; exit 1
fi
grep -Fq 'established identity changed' "$tmp/identity-verify.err"
mv "$tmp/second.saved" "$second"

input COMPLETE false >"$tmp/regression.json"
if "$ROOT/scripts/record-join-receipt.sh" --receipt-dir "$receipts" --input "$tmp/regression.json" >"$tmp/regression.out" 2>"$tmp/regression.err"; then
  echo 'signer state regression unexpectedly wrote a receipt' >&2; exit 1
fi
grep -Fq 'would regress signer_ever_started' "$tmp/regression.err"
input SIGNER_ACTIVATING true >"$tmp/repeated-state.json"
if "$ROOT/scripts/record-join-receipt.sh" --receipt-dir "$receipts" --input "$tmp/repeated-state.json" >"$tmp/repeated-state.out" 2>"$tmp/repeated-state.err"; then
  echo 'repeated receipt state unexpectedly wrote a receipt' >&2; exit 1
fi
grep -Fq 'would regress or repeat lifecycle state' "$tmp/repeated-state.err"
input COMPLETE true | jq '.join_profile_sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"' >"$tmp/rebound.json"
if "$ROOT/scripts/record-join-receipt.sh" --receipt-dir "$receipts" --input "$tmp/rebound.json" >"$tmp/rebound.out" 2>"$tmp/rebound.err"; then
  echo 'changed immutable binding unexpectedly wrote a receipt' >&2; exit 1
fi
grep -Fq 'would change the immutable run binding' "$tmp/rebound.err"
input COMPLETE true | jq '.identity_fingerprints.p2p_node_id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' >"$tmp/identity-changed.json"
if "$ROOT/scripts/record-join-receipt.sh" --receipt-dir "$receipts" --input "$tmp/identity-changed.json" >"$tmp/identity-changed.out" 2>"$tmp/identity-changed.err"; then
  echo 'changed established identity fingerprint unexpectedly wrote a receipt' >&2; exit 1
fi
grep -Fq 'would change an established identity fingerprint' "$tmp/identity-changed.err"
printf 'tampered\n' >>"$second"
input COMPLETE true >"$tmp/tampered.json"
if "$ROOT/scripts/record-join-receipt.sh" --receipt-dir "$receipts" --input "$tmp/tampered.json" >"$tmp/tampered.out" 2>"$tmp/tampered.err"; then
  echo 'tampered receipt chain unexpectedly continued' >&2; exit 1
fi
grep -Fq 'invalid or tampered JOIN receipt' "$tmp/tampered.err"

# A syntactically valid receipt that changes any input binding must never be
# accepted as the same resumable JOIN.
cp "$first" "$tmp/first.saved"
rm -rf "$receipts"; mkdir -m 700 "$receipts"
cp "$tmp/first.saved" "$receipts/0001-run_created.json"; chmod 600 "$receipts/0001-run_created.json"
jq --arg first_sha "$(sha256sum "$receipts/0001-run_created.json" | awk '{print $1}')" '.join_profile_sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" | .sequence = 2 | .previous_receipt_sha256 = $first_sha' "$tmp/first.saved" >"$receipts/0002-profile_changed.json"
chmod 600 "$receipts/0002-profile_changed.json"
if "$ROOT/scripts/verify-join-receipt-chain.sh" --receipt-dir "$receipts" >"$tmp/binding.out" 2>"$tmp/binding.err"; then
  echo 'changed receipt binding unexpectedly verified' >&2; exit 1
fi
grep -Fq 'immutable binding changed' "$tmp/binding.err"

jq -cn --arg profile "$profile" --arg evidence "$evidence" '
  {schema_version:1,kind:"gdc-host-join-result",outcome:"refused",phase:"profile",category:"profile",reason:"join_profile_invalid",exit_code:10,mutation:"none",signer_state:"absent",resume:"new_profile",join_profile_sha256:$profile,evidence:[{kind:"fixture",sha256:$evidence}]}' >"$tmp/result.json"
result="$($ROOT/scripts/record-join-result.sh --output "$tmp/result/join-result.v1.json" --input "$tmp/result.json")"
[[ "$result" == "$tmp/result/join-result.v1.json" && "$(stat -c %a "$result")" == 600 ]]
jq -e '.outcome == "refused" and .mutation == "none"' "$result" >/dev/null
jq '.reason = "bad reason"' "$tmp/result.json" >"$tmp/invalid-result.json"
if "$ROOT/scripts/record-join-result.sh" --output "$tmp/result/invalid.json" --input "$tmp/invalid-result.json" >"$tmp/invalid.out" 2>"$tmp/invalid.err"; then
  echo 'malformed terminal result unexpectedly persisted' >&2; exit 1
fi
grep -Fq 'invalid JOIN terminal result input' "$tmp/invalid.err"
printf 'PASS JOIN transition and terminal receipts are immutable, bounded and signer-monotonic\n'
