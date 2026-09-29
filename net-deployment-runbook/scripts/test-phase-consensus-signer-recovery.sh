#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -x "$ROOT/scripts/prepare-consensus-recovery-inputs.sh" ]] || {
  echo 'FAIL recovery input preparation must be directly executable by GDC' >&2
  exit 1
}
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
mkdir -p "$temporary/kit/scripts" "$temporary/home/state/identities" "$temporary/bin"
cp "$ROOT/scripts/phase-consensus-signer-recovery.sh" "$ROOT/scripts/record-join-result.sh" "$temporary/kit/scripts/"
cat >"$temporary/kit/scripts/lib.sh" <<'SH'
load_project() {
  ROOT="$TEST_ROOT/kit"
  STATE="$TEST_ROOT/home/state"
  SECRETS="$STATE/secrets"
  IDENTITIES="$STATE/identities"
  GDC_DATA_ROOT="$TEST_ROOT/home"
  export ROOT STATE SECRETS IDENTITIES GDC_DATA_ROOT
}
node_name() { printf '%s\n' "$1"; }
record_join_state() { printf 'operator-state\n' >>"$TEST_ROOT/calls"; }
SH
cat >"$temporary/kit/scripts/consensus-signer-recovery.sh" <<'SH'
recovery_execute() { printf 'execute\n' >>"$TEST_ROOT/calls"; }
recovery_continue_installed() { printf 'continue-installed\n' >>"$TEST_ROOT/calls"; }
recovery_resume_fenced() { [[ "${TEST_FAIL_ACTIVATION:-false}" == false ]]; }
recovery_wait_validating() {
  printf 'verify\n' >>"$TEST_ROOT/calls"
  [[ "${TEST_FAIL_VERIFICATION:-false}" == false ]] || return 2
  mkdir "$3"
  printf '{"verdict":"VALIDATING"}\n' >"$3/result.json"
}
recovery_record_transition() { printf '%s\n' "$2" >>"$TEST_ROOT/calls"; }
recovery_update_operator_identity() { printf 'identity\n' >>"$TEST_ROOT/calls"; }
SH
cat >"$temporary/kit/scripts/verify-join-resume-inputs.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$temporary/kit/scripts/verify-join-receipt-chain.sh" <<'SH'
#!/usr/bin/env bash
jq -n --arg state "$TEST_STATE" '{last_state:$state}'
SH
cat >"$temporary/kit/scripts/verify-tmkms-signing-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'signing-advance\n' >>"$TEST_ROOT/calls"
SH
cat >"$temporary/kit/scripts/validator-backup.sh" <<'SH'
#!/usr/bin/env bash
printf 'backup\n' >>"$TEST_ROOT/calls"
touch "$GDC_DATA_ROOT/$2-validator-backup-$GDC_RUN_ID-$3.tar"
SH
cat >"$temporary/bin/ssh" <<'SH'
#!/usr/bin/env bash
case "${*: -1}" in
  'sudo cat /srv/dai/signer/tmkms/state/priv_validator_state.json') printf '{"height":"102","round":"0","step":2}\n' ;;
  *'validation.json.tmp'*) cat >/dev/null ;;
  *' --finalize '*) printf 'restart-policy\n' >>"$TEST_ROOT/calls" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$temporary/kit/scripts/"*.sh "$temporary/bin/ssh"
export TEST_ROOT="$temporary" PATH="$temporary/bin:$PATH"
case_number=0
run_phase_fixture() {
  local mode="$1"
  case_number=$((case_number + 1))
  export GDC_RUN_ID="fixture-$case_number"
  local run="$temporary/$GDC_RUN_ID"
  mkdir -p "$run/preparation-observation"
  jq -n --arg run "$GDC_RUN_ID" '{run_id:$run,operation:"restore",spec:{target:{node_name:"node5",public_host:"node5.example"}}}' >"$run/join-profile.v1.json"
  printf '{"participant_address":"owner"}\n' >"$run/preparation-observation/intent.json"
  export GDC_JOIN_PROFILE="$run/join-profile.v1.json" GDC_JOIN_RESULT_OUTPUT="$run/join-result.v1.json"
  : >"$temporary/calls"
  bash "$temporary/kit/scripts/phase-consensus-signer-recovery.sh" node5 "$run" unused "$mode"
}
export TEST_STATE=RUN_CREATED
run_phase_fixture start >/dev/null
[[ "$(head -n 1 "$temporary/calls")" == execute ]]
[[ "$(tail -n 1 "$temporary/calls")" == COMPLETE ]]
jq -e '.outcome == "succeeded" and .phase == "acceptance" and .resume == "not_applicable"' "$GDC_JOIN_RESULT_OUTPUT" >/dev/null
run_phase_fixture readback >/dev/null
[[ "$(head -n 1 "$temporary/calls")" == continue-installed ]]
if grep -qx execute "$temporary/calls"; then exit 1; fi
export TEST_STATE=SIGNER_ACTIVATING
run_phase_fixture readback >/dev/null
if grep -q execute "$temporary/calls"; then exit 1; fi
[[ "$(cat "$temporary/calls")" == $'verify\nsigning-advance\nSIGNER_ACTIVE_VERIFIED\nidentity\noperator-state\nbackup\nRECOVERY_ARCHIVE_VERIFIED\nrestart-policy\nCOMPLETE' ]]
export TEST_STATE=RECOVERY_ARCHIVE_VERIFIED
run_phase_fixture readback >/dev/null
if grep -Eq 'execute|SIGNER_ACTIVE_VERIFIED|RECOVERY_ARCHIVE_VERIFIED' "$temporary/calls"; then exit 1; fi
export TEST_STATE=SIGNER_ACTIVATING TEST_FAIL_VERIFICATION=true
if run_phase_fixture readback >/dev/null 2>&1; then
  echo 'FAIL phase completed without VALIDATING evidence' >&2; exit 1
fi
[[ "$(cat "$temporary/calls")" == verify ]]
[[ ! -e "$GDC_JOIN_RESULT_OUTPUT" ]]
unset TEST_FAIL_VERIFICATION
export TEST_STATE=SIGNER_FENCE_VERIFIED TEST_FAIL_ACTIVATION=true
if run_phase_fixture readback >/dev/null 2>&1; then
  echo 'FAIL readback restarted an incomplete activation' >&2; exit 1
fi
[[ ! -s "$temporary/calls" ]]
unset TEST_FAIL_ACTIVATION
printf 'PASS recovery phase requires VALIDATING and readback never repeats installation or activation\n'

# Invalid CLI combinations fail before any role loading or network operation.
touch "$temporary/archive.tar"
for variant in missing-inputs missing-authority authority-alone plan; do
  args=(host join --public-host node5.example node5)
  case "$variant" in
    missing-inputs) args+=(--recover-consensus-signer) ;;
    missing-authority) args+=(--recover-consensus-signer --resume parent --restore "$temporary/archive.tar") ;;
    authority-alone) args+=(--exclusive-signer) ;;
    plan) args+=(--recover-consensus-signer --exclusive-signer --resume parent --restore "$temporary/archive.tar" --plan) ;;
  esac
  status=0
  GDC_HOME="$temporary/cli-$variant" bash "$ROOT/gdc.sh" "${args[@]}" >"$temporary/cli-$variant.log" 2>&1 || status=$?
  [[ "$status" -eq 2 ]] || { echo "FAIL unsafe CLI combination: $variant ($status)" >&2; exit 1; }
  grep -Eq 'consensus recovery requires|exclusive-signer requires|consensus recovery preserves' "$temporary/cli-$variant.log"
done
printf 'PASS CLI requires explicit recovery archive, parent run and single-signer authority\n'
