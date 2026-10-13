#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

profile="$tmp/join-profile.json"
printf '%s\n' '{}' >"$profile"
profile_sha256="$(sha256sum "$profile" | awk '{print $1}')"

write_receipt() {
  local receipts="$1" operation="$2" state="$3" signer="$4" generation="${5:-fixture-run}" input="$tmp/input.json"
  jq -cn --arg operation "$operation" --arg state "$state" --argjson signer "$signer" --arg profile "$profile_sha256" --arg generation "$generation" '
    {schema_version:2,kind:"gdc-host-join-receipt",run_id:"fixture-run",operation:$operation,node_name:"fixture",state:$state,
     join_profile_sha256:$profile,network_observation_sha256:("a" * 64),generation_id:$generation,
     identity_fingerprints:{participant_address:"",consensus_pubkey:"",p2p_node_id:"",warm_address:""},
     signer_ever_started:$signer,tmkms_state:{height:0,round:0,step:0,block_id:""},
     evidence:[],outcome:"in_progress",resume_policy:"resume_same_run"}' >"$input"
  "$ROOT/scripts/record-join-receipt.sh" --receipt-dir "$receipts" --input "$input" >/dev/null
}

make_receipts() {
  local destination="$1" operation="$2" generation="${3:-fixture-run}"
  mkdir -p "$destination"
  write_receipt "$destination" "$operation" RUN_CREATED false "$generation"
  write_receipt "$destination" "$operation" CANARY_VERIFIED false "$generation"
  write_receipt "$destination" "$operation" PROMOTED false "$generation"
  write_receipt "$destination" "$operation" CANONICAL_RUNNING false "$generation"
  write_receipt "$destination" "$operation" APPLICATION_ACTIVE false "$generation"
}

mkdir -p "$tmp/bin"
cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == fixture && "$2" == bash && "$3" == -s && "$4" == -- ]] || exit 41
case "${GDC_TEST_REMOTE_CASE:-pass}" in
  pass) cat >/dev/null ;;
  divergent) cat >/dev/null; echo 'current checkpoint differs from trusted origins' >&2; exit 44 ;;
  *) exit 46 ;;
esac
EOF
chmod 0755 "$tmp/bin/ssh"

verify() {
  GDC_RUN_ID=fixture-run PATH="$tmp/bin:$PATH" "$ROOT/scripts/verify-post-sync-join-state.sh" \
    --node fixture --run-dir "$1" --profile "$profile" --remote-dir /tmp/gdc-fixture \
    --expected-chain-id gonka-devnet-community --expected-p2p-node-id 0123456789abcdef0123456789abcdef01234567 \
    --expected-core-version 0.2.15 --expected-core-commit 1111111111111111111111111111111111111111 \
    --expected-dapi-version 0.2.15-post3 --expected-dapi-commit 2222222222222222222222222222222222222222
}

for operation in new restore; do
  run="$tmp/$operation-run"
  make_receipts "$run/receipts" "$operation"
  verify "$run" >/dev/null
done

# This reset-then-JOIN fixture has only the new run. It must not depend on a
# previous local diagnostic directory, while its transition proof is complete.
fresh="$tmp/reset-then-join"
make_receipts "$fresh/receipts" new
verify "$fresh" >/dev/null

membership="$tmp/restore-membership"
make_receipts "$membership/receipts" restore
write_receipt "$membership/receipts" restore CANONICAL_VERIFIED false
write_receipt "$membership/receipts" restore RECOVERY_ARCHIVE_READY false
write_receipt "$membership/receipts" restore MEMBERSHIP_RECONCILED false
verify "$membership" >/dev/null

missing_canonical="$tmp/restore-membership-without-canonical"
make_receipts "$missing_canonical/receipts" restore
write_receipt "$missing_canonical/receipts" restore RECOVERY_ARCHIVE_READY false
write_receipt "$missing_canonical/receipts" restore MEMBERSHIP_RECONCILED false
if verify "$missing_canonical" >/dev/null 2>&1; then
  echo 'membership resume without prior canonical verification unexpectedly verified' >&2
  exit 1
fi

wrong_generation="$tmp/wrong-generation"
make_receipts "$wrong_generation/receipts" new another-generation
if verify "$wrong_generation" >/dev/null 2>&1; then
  echo 'receipt chain bound to another promoted generation unexpectedly verified' >&2
  exit 1
fi

missing="$tmp/missing-proof"
mkdir -p "$missing/receipts"
cp "$fresh/receipts/0001-run_created.json" "$missing/receipts/"
chmod 600 "$missing/receipts/0001-run_created.json"
if verify "$missing" >/dev/null 2>&1; then
  echo 'incomplete lifecycle proof unexpectedly verified' >&2
  exit 1
fi

signer_started="$tmp/signer-started"
cp -a "$fresh" "$signer_started"
write_receipt "$signer_started/receipts" new SIGNER_ACTIVATING true
if verify "$signer_started" >/dev/null 2>&1; then
  echo 'signer-active receipt chain unexpectedly verified as signerless' >&2
  exit 1
fi

if GDC_TEST_REMOTE_CASE=divergent verify "$fresh" >/dev/null 2>&1; then
  echo 'divergent current state unexpectedly verified' >&2
  exit 1
fi

printf 'PASS post-sync JOIN verification accepts only promoted signerless runs and requires a fresh current checkpoint\n'
