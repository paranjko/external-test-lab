#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR/..
set -Eeuo pipefail

# Offline contract tests: no real ssh/docker/curl/inferenced/signer access;
# ssh is faked (see $BIN/ssh below). Also runs on macOS, whose realpath
# lacks GNU -e/-m.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "$HERE/.recovery-contract.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -m 700 "$BIN"
cat >"$BIN/realpath" <<'EOF'
#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
if args and args[0] in ('-e', '-m'): args.pop(0)
if args and args[0] == '--': args.pop(0)
if len(args) != 1: raise SystemExit(2)
print(os.path.realpath(args[0]))
EOF
chmod 700 "$BIN/realpath"
# Fake ssh: no route to any host by default (fast, matches real ssh's
# unreachable-host exit code), unless a test points RECOVERY_TEST_SSH_FIXTURE
# at its own executable fixture that inspects "$@" and answers instead.
cat >"$BIN/ssh" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${RECOVERY_TEST_SSH_FIXTURE:-}" && -x "${RECOVERY_TEST_SSH_FIXTURE:-}" ]]; then
  exec "$RECOVERY_TEST_SSH_FIXTURE" "$@"
fi
exit 255
EOF
chmod 700 "$BIN/ssh"
export PATH="$BIN:$PATH"
# Bounded-observation timeouts: keep the default (unstubbed) fake-ssh path
# instant, and cap real timing tests to a few seconds instead of the
# production defaults.
export RECOVERY_SSH_CONNECT_TIMEOUT_SECONDS=2 RECOVERY_SSH_COMMAND_TIMEOUT_SECONDS=2 \
  RECOVERY_INSPECT_REOBSERVE_DELAY_SECONDS=0

fail=0
ok() { printf 'ok - %s\n' "$1"; }
bad() { printf 'not ok - %s\n' "$1"; fail=1; }
assert_rc() {
  local name="$1" want="$2" got
  shift 2
  set +e
  "$@" >/dev/null 2>&1
  got=$?
  set -e
  if (( got == want )); then
    ok "$name"
  else
    bad "$name (expected $want, got $got)"
  fi
}

# E4: one fixed coordinator identity reused by every isolated test home, so
# a manifest fixture's coordinator_sha256 can be pinned once and reused.
CONTROLLER_ID_CONTENT='recovery-contract-test-controller'
CONTROLLER_SHA256="$(printf '%s' "$CONTROLLER_ID_CONTENT" | sha256sum | awk '{print $1}')"
seed_controller() {
  mkdir -p "$1"
  printf '%s' "$CONTROLLER_ID_CONTENT" >"$1/recovery-controller-id"
  chmod 600 "$1/recovery-controller-id"
}

# E3: a test-local qualification store (never the repository's own
# recovery/qualification.json), so real verification runs against test data.
RECOVERY_QUALIFICATION_FILE="$TMP/qualification.json"; printf '[]\n' >"$RECOVERY_QUALIFICATION_FILE"
RECOVERY_QUALIFICATION_SIGNERS_FILE="$TMP/qualification-signers.json"
printf '[{"key_id":"test-qual-key","public_key":"ssh-ed25519 AAAATESTQUALKEY0000000000000000000000000"}]\n' \
  >"$RECOVERY_QUALIFICATION_SIGNERS_FILE"
export RECOVERY_QUALIFICATION_FILE RECOVERY_QUALIFICATION_SIGNERS_FILE
qual_helper="$TMP/qualify-helper.sh"
cat >"$qual_helper" <<'EOF'
# E3: appends a stub-signed qualification record for one test handler (the
# fake ssh-keygen installed later in this suite accepts any signature).
qualify_test_handler() {
  local selector="$1" handler="$2" code_sha tmp
  code_sha="$(declare -f "$handler" | sha256sum | awk '{print tolower($1)}')"
  tmp="$(mktemp)"
  jq --arg s "$selector" --arg h "$handler" --arg sha "$code_sha" '
    . + [{selector:$s,handler:$h,handler_code_sha256:$sha,evidence_sha256:("0"*64),mode:"rehearsal",
      key_id:"test-qual-key",signature:"-----BEGIN SSH SIGNATURE-----\nAAAA\n-----END SSH SIGNATURE-----\n"}]
  ' "$RECOVERY_QUALIFICATION_FILE" >"$tmp"
  mv "$tmp" "$RECOVERY_QUALIFICATION_FILE"
}
EOF

# Source only the offline library; no phase handler is registered by design.
source "$HERE/scripts/lib-recovery.sh"
assert_rc 'unknown phase rejected' 1 recovery_is_phase nonsense
assert_rc 'duplicate option rejected by parser' 2 recovery_parse_args inspect --incident GNK-LAB-2026-0001 --incident GNK-LAB-2026-0001
assert_rc 'option without value rejected' 2 recovery_parse_args inspect --incident
assert_rc 'relative input rejected' 1 recovery_canonical_input_file relative.json

fixture="$TMP/input.json"; printf '{}\n' >"$fixture"; chmod 600 "$fixture"
assert_rc 'canonical private file accepted' 0 recovery_require_private_file "$fixture"
ln -s "$fixture" "$TMP/symlink.json"
assert_rc 'symlink input rejected' 1 recovery_canonical_input_file "$TMP/symlink.json"
assert_rc 'path escape rejected' 1 recovery_canonical_output_path "$TMP/out/../escape.json"
mkdir -m 700 "$TMP/out"
assert_rc 'new persistent output accepted' 0 recovery_canonical_output_path "$TMP/out/receipt.json"

schema="$HERE/schemas/recovery-receipt-v1.schema.json"
assert_rc 'strict schema rejects unknown field' 1 recovery_validate_json_schema "$schema" "$fixture"
printf '{"schema_version":1,"kind":"gdc-network-recovery-receipt","receipt_type":"phase","receipt_id":"r","run_id":"run","attempt_id":"a","attempt_number":1,"sequence":1,"manifest_binding_kind":"none","manifest_sha256":null,"host":"node1","phase":"inspect","started_at":"2026-09-13T00:00:00Z","finished_at":"2026-09-13T00:00:01Z","command":{"selector":"inspect","redacted":true,"argv_sha256":"%064d"},"exit_status":0,"verdict":"OBSERVED","mutation_state":"none","observed_hashes":[],"evidence":[],"next_permitted_steps":[],"predecessor_receipts":[],"append_only":{"immutable":true,"attempt_directory":"/var/lib/gdc/runs/run/recovery/node1/inspect/attempt-1","prior_attempt_state":"none","raw_evidence_separate":true,"sanitized_receipt":true},"details":{"state":"INSPECTED","reason_code":"offline_test","message":"offline contract fixture"}}\n' 0 >"$TMP/receipt.json"
assert_rc 'strict schema accepts complete receipt' 0 recovery_validate_json_schema "$schema" "$TMP/receipt.json"

# Real local inspect; a first observation has no predecessor receipt.
export GDC_HOME="$TMP/gdc-home"
mkdir -m 700 "$GDC_HOME"
seed_controller "$GDC_HOME"
inspect_output="$TMP/out/inspect-receipt.json"
assert_rc 'local inspect emits a schema-valid receipt' 0 recovery_main inspect \
  --incident GNK-LAB-2026-0001 --host x --run-id inspect-run --output "$inspect_output"
if jq -e '
  .receipt_type == "verdict" and .phase == "inspect" and .verdict == "OBSERVED"
  and .manifest_binding_kind == "none" and .manifest_sha256 == null
  and .terminal.required_receipts == []
' "$inspect_output" >/dev/null; then
  ok 'inspect receipt has no invented predecessor'
else
  bad 'inspect receipt has no invented predecessor'
fi
if [[ "$(recovery_file_mode "$inspect_output")" == 400 ]]; then
  ok 'exported receipt is read-only'
else
  bad 'exported receipt is read-only'
fi

# An inspect generated by the offline controller is intentionally incomplete:
# OBSERVED evidence must never be enough to enter prepare.  A separately
# qualified OBSERVED receipt requires complete schema-valid inspection evidence
# and terminal evidence completeness before it can open the prepare gate.
assert_rc 'local incomplete inspect cannot unlock prepare' 0 bash -c '
  source "$1"
  export GDC_HOME="$2" RECOVERY_RUN_ID=inspect-run RECOVERY_HOST=x
  ! recovery_require_predecessor inspect x "" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$GDC_HOME"
qualified_inspect_home="$TMP/qualified-inspect-home"
qualified_first_root="$qualified_inspect_home/runs/inspect-run/recovery/x/inspect/attempt-1"
qualified_inspect_root="$qualified_inspect_home/runs/inspect-run/recovery/x/inspect/attempt-2"
mkdir -p "$qualified_first_root"
cp "$inspect_output" "$qualified_first_root/receipt.json"; chmod 400 "$qualified_first_root/receipt.json"
mkdir -p "$qualified_inspect_root"
first_inspect_sha="$(recovery_sha256 "$qualified_first_root/receipt.json")"
jq --arg previous "$first_inspect_sha" '
  .receipt_type = "verdict" | .receipt_id = "qualified-inspect"
  | .attempt_id = "qualified-inspect" | .attempt_number = 2 | .sequence = 1
  | .previous_attempt_receipt_sha256 = $previous | .append_only.prior_attempt_state = "terminal"
  | .verdict = "OBSERVED" | .exit_status = 0 | .terminal.evidence_complete = true
  | .details = {state:"INSPECTED",reason_code:"qualified_host_evidence",message:"bounded host evidence complete",
      inspection:{chain_id:"qualified-chain",observed_height:1,source_application_hash:("0" * 64),
        complete_validator_set_sha256:("0" * 64),runtime_sha256:("0" * 64),
        public_bindings:[{binding_kind:"participant",binding_id:"qualified-participant",public_value_sha256:("0" * 64)}],
        archive_coverage_verified:true,controller_sha256:("0" * 64)}}
' "$inspect_output" >"$qualified_inspect_root/receipt.json"
chmod 400 "$qualified_inspect_root/receipt.json"
assert_rc 'qualified complete OBSERVED inspect unlocks prepare' 0 bash -c '
  source "$1"
  export GDC_HOME="$2" RECOVERY_RUN_ID=inspect-run RECOVERY_HOST=x
  recovery_validate_json_schema "$(recovery_receipt_schema)" "$GDC_HOME/runs/inspect-run/recovery/x/inspect/attempt-2/receipt.json"
  recovery_require_predecessor inspect x "" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$qualified_inspect_home"
for qualified_defect in archive_coverage public_bindings; do
  qualified_defect_receipt="$TMP/qualified-inspect-$qualified_defect.json"
  if [[ "$qualified_defect" == archive_coverage ]]; then
    jq '.details.inspection.archive_coverage_verified = false' "$qualified_inspect_root/receipt.json" >"$qualified_defect_receipt"
  else
    jq '.details.inspection.public_bindings = []' "$qualified_inspect_root/receipt.json" >"$qualified_defect_receipt"
  fi
  chmod 400 "$qualified_defect_receipt"
  assert_rc "qualified inspect with $qualified_defect defect cannot unlock prepare" 0 bash -c '
    source "$1"
    export RECOVERY_RUN_ID=inspect-run RECOVERY_HOST=x
    recovery_validate_json_schema "$(recovery_receipt_schema)" "$2"
    ! recovery_validate_phase_receipt_binding "$2" x inspect ""
  ' _ "$HERE/scripts/lib-recovery.sh" "$qualified_defect_receipt"
done

# GDC_HOME is host-local runtime state.  Cross-host predecessor receipts and
# approval replay markers must instead resolve through the controller/run root.
shared_recovery_root="$TMP/shared-recovery-root"
host_one_home="$TMP/host-one-home"; host_two_home="$TMP/host-two-home"
mkdir -p "$shared_recovery_root/runs/shared-run/recovery/h1/stage/attempt-1" "$host_one_home" "$host_two_home"
shared_manifest_sha="$(printf '%064d' 0)"
jq --arg manifest "$shared_manifest_sha" '
  .receipt_type = "phase" | del(.terminal) | .receipt_id = "h1-stage"
  | .run_id = "shared-run" | .attempt_id = "h1-stage" | .attempt_number = 1 | .sequence = 1
  | .host = "h1" | .phase = "stage" | .manifest_binding_kind = "final_manifest" | .manifest_sha256 = $manifest
  | .command.selector = "stage" | .verdict = "PASS" | .exit_status = 0
  | .details = {state:"STAGED",reason_code:"qualified_stage",message:"stage evidence complete"}
' "$inspect_output" >"$shared_recovery_root/runs/shared-run/recovery/h1/stage/attempt-1/receipt.json"
chmod 400 "$shared_recovery_root/runs/shared-run/recovery/h1/stage/attempt-1/receipt.json"
assert_rc 'cross-host predecessor lookup uses the shared recovery root' 0 bash -c '
  source "$1"
  export GDC_HOME="$2" GDC_RECOVERY_ROOT="$3" RECOVERY_RUN_ID=shared-run RECOVERY_HOST=h2
  recovery_require_predecessor stage h1 "$4" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$host_two_home" "$shared_recovery_root" "$shared_manifest_sha"
assert_rc 'approval id replay is refused across host-local GDC_HOME values' 0 bash -c '
  source "$1"
  export GDC_RECOVERY_ROOT="$2" RECOVERY_RUN_ID=shared-run RECOVERY_PENDING_APPROVAL_ID=shared-approval RECOVERY_PENDING_APPROVAL_NONCE=shared-nonce-0001
  export GDC_HOME="$3" RECOVERY_HOST=h1 RECOVERY_ATTEMPT_ID=host-one-attempt
  recovery_consume_approval
  export GDC_HOME="$4" RECOVERY_HOST=h2 RECOVERY_ATTEMPT_ID=host-two-attempt
  ! recovery_consume_approval
' _ "$HERE/scripts/lib-recovery.sh" "$shared_recovery_root" "$host_one_home" "$host_two_home"
shared_symlink_root="$TMP/shared-symlink-root"; shared_outside_root="$TMP/shared-outside-root"
mkdir -p "$shared_symlink_root" "$shared_outside_root"
ln -s "$shared_outside_root" "$shared_symlink_root/runs"
assert_rc 'symlinked shared-root component is rejected without an outside write' 0 bash -c '
  source "$1"
  export GDC_HOME="$2" GDC_RECOVERY_ROOT="$3" RECOVERY_RUN_ID=symlink-run RECOVERY_HOST=x
  RECOVERY_PENDING_APPROVAL_ID=symlink-approval RECOVERY_PENDING_APPROVAL_NONCE=symlink-nonce-0001 RECOVERY_ATTEMPT_ID=symlink-attempt
  ! recovery_consume_approval
  [[ ! -e "$4/symlink-run/recovery/approval-consumption/approval-id.symlink-approval" ]]
' _ "$HERE/scripts/lib-recovery.sh" "$host_one_home" "$shared_symlink_root" "$shared_outside_root"
root_symlink="$TMP/root-link"; root_target="$TMP/root-link-target"; root_noncanonical_parent="$TMP/root-noncanonical"
mkdir -p "$root_target" "$root_noncanonical_parent"; ln -s "$root_target" "$root_symlink"
assert_rc 'symlinked GDC_RECOVERY_ROOT is rejected before recovery writes' 0 bash -c '
  source "$1"
  export GDC_HOME="$2" GDC_RECOVERY_ROOT="$3"
  ! recovery_main inspect --incident GNK-LAB-2026-0001 --host x --run-id symlink-root --output "$4"
  [[ ! -e "$5/runs/symlink-root" ]]
' _ "$HERE/scripts/lib-recovery.sh" "$host_one_home" "$root_symlink" "$TMP/out/root-link.json" "$root_target"
assert_rc 'noncanonical GDC_RECOVERY_ROOT is rejected before recovery writes' 0 bash -c '
  source "$1"
  export GDC_HOME="$2" GDC_RECOVERY_ROOT="$3/../root-noncanonical"
  ! recovery_main inspect --incident GNK-LAB-2026-0001 --host x --run-id noncanonical-root --output "$4"
  [[ ! -e "$3/runs/noncanonical-root" ]]
' _ "$HERE/scripts/lib-recovery.sh" "$host_one_home" "$root_noncanonical_parent" "$TMP/out/noncanonical-root.json"

# recovery_write_once never replaces an existing target.
write_once_dir="$TMP/write-once"; mkdir -m 700 "$write_once_dir"
first_source="$write_once_dir/first-source.txt"; printf 'first-content\n' >"$first_source"
second_source="$write_once_dir/second-source.txt"; printf 'second-content\n' >"$second_source"
write_once_target="$write_once_dir/target.txt"
assert_rc 'first write-once call creates the target' 0 recovery_write_once "$write_once_target" "$first_source"
assert_rc 'second write-once call on the same target fails' 1 recovery_write_once "$write_once_target" "$second_source"
if [[ "$(cat "$write_once_target")" == 'first-content' ]]; then
  ok 'write-once target keeps its first content after a rejected overwrite'
else
  bad 'write-once target keeps its first content after a rejected overwrite'
fi
if [[ "$(recovery_file_mode "$write_once_target")" == 400 ]]; then
  ok 'write-once target is read-only'
else
  bad 'write-once target is read-only'
fi

status_manifest="$TMP/status-manifest.json"
python3 "$HERE/scripts/test-network-recovery-schemas.py" --emit-final "$status_manifest" >/dev/null
# E4: pin this shared base manifest to the fixed test controller identity so
# every isolated home seeded via seed_controller() passes the machine check.
jq --arg c "$CONTROLLER_SHA256" '.coordinator_sha256 = $c' "$status_manifest" >"$status_manifest.tmp"
mv "$status_manifest.tmp" "$status_manifest"
chmod 600 "$status_manifest"
assert_rc 'local status emits a schema-valid retained-state receipt' 0 recovery_main status \
  --host x --run-id inspect-run --manifest "$status_manifest"
status_receipt="$GDC_HOME/runs/inspect-run/recovery/x/status/attempt-1/receipt.json"
if jq -e '.verdict == "OBSERVED" and .details.state == "INCONCLUSIVE" and .details.status.operator_state == "INCONCLUSIVE"' \
  "$status_receipt" >/dev/null; then
  ok 'status reports the retained operator state without runtime mutation'
else
  bad 'status reports the retained operator state without runtime mutation'
fi

# INV-002: old and new transition keys must differ.
colliding_manifest="$TMP/colliding-manifest.json"
jq '.transition.new_transition_consensus.public_key = .transition.old_participant_consensus.public_key
    | .transition.new_transition_consensus.consensus_address = .transition.old_participant_consensus.consensus_address' \
  "$status_manifest" >"$colliding_manifest"
chmod 600 "$colliding_manifest"
assert_rc 'admission refuses when old and new transition consensus keys coincide' 1 \
  recovery_validate_manifest "$colliding_manifest" x status

# FR-005: resume poc needs signers receipts from every returning host.
resume_poc_manifest="$TMP/resume-poc-manifest.json"
jq '.hosts.return_order = ["h1", "h2"]' "$status_manifest" >"$resume_poc_manifest"
chmod 600 "$resume_poc_manifest"
resume_poc_hosts_seen="$TMP/resume-poc-hosts-seen.txt"
assert_rc 'resume poc collects a signers predecessor for every cohort host' 0 bash -c '
  source "$1"
  LOG="$3"
  : >"$LOG"
  recovery_latest_receipt() { printf "%s %s %s\n" "$1" "$2" "$3" >>"$LOG"; printf "dummy-receipt-path\n"; }
  recovery_validate_phase_receipt_binding() { return 0; }
  recovery_append_predecessor() { return 0; }
  RECOVERY_MANIFEST="$2" RECOVERY_HOST=h2 RECOVERY_PHASE=resume RECOVERY_STEP=poc RECOVERY_SCOPE=""
  RECOVERY_MANIFEST_SHA256=deadbeef
  recovery_collect_predecessors >/dev/null 2>&1
  grep -q "^h1 resume signers$" "$LOG" && grep -q "^h2 resume signers$" "$LOG"
' _ "$HERE/scripts/lib-recovery.sh" "$resume_poc_manifest" "$resume_poc_hosts_seen"

export GDC_HOME="$TMP/refusal-home"
assert_rc 'invalid manifest produces a terminal refusal receipt' 3 recovery_main status \
  --host node1 --run-id refused-run --manifest "$fixture"
refusal_receipt="$GDC_HOME/runs/refused-run/recovery/node1/status/attempt-1/receipt.json"
if jq -e '.verdict == "REFUSED" and .exit_status == 3 and .details.reason_code == "admission_failed"' \
  "$refusal_receipt" >/dev/null \
  && [[ "$(recovery_file_mode "$refusal_receipt")" == 400 ]]; then
  ok 'admission failure remains schema-valid append-only evidence'
else
  bad 'admission failure remains schema-valid append-only evidence'
fi

export GDC_HOME="$TMP/mutating-retry-home"
mkdir -p "$GDC_HOME/runs/retry-run/recovery/x/activate/attempt-1"
assert_rc 'mutating retry after an incomplete attempt emits refusal evidence' 3 recovery_main activate \
  --host x --run-id retry-run --manifest "$status_manifest" --approval "$fixture"
retry_receipt="$GDC_HOME/runs/retry-run/recovery/x/activate/attempt-2/receipt.json"
if jq -e '.verdict == "REFUSED" and .append_only.prior_attempt_state == "incomplete"
  and (has("previous_attempt_receipt_sha256") | not)' "$retry_receipt" >/dev/null; then
  ok 'mutating retry refusal records the incomplete predecessor honestly'
else
  bad 'mutating retry refusal records the incomplete predecessor honestly'
fi

# Attempt allocation is append-only: a retry gets a new directory and an
# incomplete prior attempt blocks mutating admission until state is inspected.
export RECOVERY_RUN_ID=run RECOVERY_HOST=node1 RECOVERY_PHASE=inspect RECOVERY_STEP='' RECOVERY_SCOPE=''
export RECOVERY_MANIFEST_SHA256='' RECOVERY_PREDECESSOR_RECEIPTS='[]'
attempt_root="$TMP/attempts"
recovery_next_attempt "$attempt_root"
first_attempt="$RECOVERY_ATTEMPT_DIR"
printf '%s\n' '{}' >"$first_attempt/command.json"; chmod 600 "$first_attempt/command.json"
recovery_next_attempt "$attempt_root"
if [[ "$RECOVERY_PRIOR_ATTEMPT_INCOMPLETE" == true ]] && recovery_is_mutating_phase activate; then
  ok 'mutating retry is marked unsafe after incomplete prior attempt'
else
  bad 'mutating retry is marked unsafe after incomplete prior attempt'
fi
export RECOVERY_STARTED_AT='2026-09-13T00:00:00Z'
recovery_record_command --incident GNK-LAB-2026-0001 --host node1 --run-id run
assert_rc 'incomplete prior attempt still permits a terminal refusal receipt' 0 \
  recovery_terminal_receipt INCONCLUSIVE 3 none prior_attempt_requires_readback '{}'
if jq -e '.append_only.prior_attempt_state == "incomplete" and (has("previous_attempt_receipt_sha256") | not)' \
  "$RECOVERY_ATTEMPT_DIR/receipt.json" >/dev/null; then
  ok 'incomplete prior attempt is represented without a fabricated receipt hash'
else
  bad 'incomplete prior attempt is represented without a fabricated receipt hash'
fi

RECOVERY_RUN_ID=run RECOVERY_HOST=node1 RECOVERY_PHASE=resume RECOVERY_STEP=signers RECOVERY_SCOPE=''
signers_path="$(recovery_phase_storage_path "$RECOVERY_PHASE" "$RECOVERY_STEP")"
recovery_next_attempt "$TMP/namespaces/$signers_path"
signers_id="$RECOVERY_ATTEMPT_ID"
RECOVERY_STEP=poc
poc_path="$(recovery_phase_storage_path "$RECOVERY_PHASE" "$RECOVERY_STEP")"
recovery_next_attempt "$TMP/namespaces/$poc_path"
poc_id="$RECOVERY_ATTEMPT_ID"
if [[ "$signers_path" != "$poc_path" && "$signers_id" != "$poc_id" ]]; then
  ok 'resume steps use distinct attempt namespaces and identifiers'
else
  bad 'resume steps use distinct attempt namespaces and identifiers'
fi
RECOVERY_PHASE=verify RECOVERY_STEP='' RECOVERY_SCOPE=consensus
consensus_path="$(recovery_phase_storage_path "$RECOVERY_PHASE" "$RECOVERY_SCOPE")"
RECOVERY_SCOPE=epochs
epochs_path="$(recovery_phase_storage_path "$RECOVERY_PHASE" "$RECOVERY_SCOPE")"
if [[ "$consensus_path" != "$epochs_path" ]]; then
  ok 'verification scopes use distinct attempt namespaces'
else
  bad 'verification scopes use distinct attempt namespaces'
fi

launcher_data="$TMP/launcher-data"; launcher_export="$TMP/launcher-export"
mkdir -m 700 "$launcher_data" "$launcher_export"
assert_rc 'launcher inspect succeeds through the public CLI' 0 env GDC_HOME="$launcher_data" \
  "$HERE/gdc.sh" network recover inspect --incident GNK-LAB-2026-0001 --host node1 \
  --run-id launcher-inspect --output "$launcher_export/receipt.json"
if [[ -s "$launcher_data/node1/state/active-recovery-run-id" \
      && ! -e "$launcher_data/node1/state/active-run-id" ]] \
    && grep -qx 'profile_kind=network_recovery' "$launcher_data/node1/runs/launcher-inspect/manifest.env"; then
  ok 'recovery run tracking does not overwrite the ordinary lifecycle run'
else
  bad 'recovery run tracking does not overwrite the ordinary lifecycle run'
fi
ln -s "$status_manifest" "$TMP/status-manifest-link.json"
invalid_launcher_data="$TMP/invalid-launcher-data"
assert_rc 'launcher rejects a symlinked security input before phase dispatch' 2 env GDC_HOME="$invalid_launcher_data" \
  "$HERE/gdc.sh" network recover prepare --host x --run-id invalid-input \
  --manifest "$TMP/status-manifest-link.json" --approval "$fixture"
if [[ ! -e "$invalid_launcher_data/x/runs/invalid-input" ]]; then
  ok 'invalid security input creates no recovery run state'
else
  bad 'invalid security input creates no recovery run state'
fi

# gdc.sh rejects malformed recovery arguments before touching run state.
assert_rc 'launcher rejects an uppercase host alias' 2 env GDC_HOME="$TMP/uppercase-host-data" \
  "$HERE/gdc.sh" network recover inspect --incident GNK-LAB-2026-0001 --host NODE1 \
  --run-id run-1 --output "$TMP/out/uppercase-host.json"
assert_rc 'launcher rejects an invalid run-id' 2 env GDC_HOME="$TMP/bad-runid-data" \
  "$HERE/gdc.sh" network recover inspect --incident GNK-LAB-2026-0001 --host node1 \
  --run-id 'bad run id' --output "$TMP/out/bad-runid.json"
assert_rc 'launcher rejects a phase missing its required option' 2 env GDC_HOME="$TMP/missing-option-data" \
  "$HERE/gdc.sh" network recover inspect --incident GNK-LAB-2026-0001 --host node1 --run-id run-1
assert_rc 'launcher rejects --release for network recover' 2 env GDC_HOME="$TMP/release-data" \
  "$HERE/gdc.sh" --release v2026.07.23 network recover inspect --incident GNK-LAB-2026-0001 \
  --host node1 --run-id run-1 --output "$TMP/out/release.json"
assert_rc 'launcher rejects --composition for network recover' 2 env GDC_HOME="$TMP/composition-data" \
  "$HERE/gdc.sh" --composition foo network recover inspect --incident GNK-LAB-2026-0001 \
  --host node1 --run-id run-1 --output "$TMP/out/composition.json"
assert_rc 'launcher rejects --model for network recover' 2 env GDC_HOME="$TMP/model-data" \
  "$HERE/gdc.sh" --model foo network recover inspect --incident GNK-LAB-2026-0001 \
  --host node1 --run-id run-1 --output "$TMP/out/model.json"

# Exercise approval policy enforcement with a verifier stub.  No real key is
# generated and no signing operation is performed by this offline test.
printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/ssh-keygen"
chmod 700 "$BIN/ssh-keygen"
operator_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOPERATORTESTKEY000000000000000000000'
reviewer_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIREVIEWERTESTKEY000000000000000000000'
operator_key_sha="$(printf '%s' "$operator_key" | sha256sum | awk '{print $1}')"
reviewer_key_sha="$(printf '%s' "$reviewer_key" | sha256sum | awk '{print $1}')"
policy_manifest="$TMP/policy-manifest.json"
jq -n --arg operator_key "$operator_key" --arg operator_sha "$operator_key_sha" \
  --arg reviewer_key "$reviewer_key" --arg reviewer_sha "$reviewer_key_sha" '
  {approvals:{trusted_approvers:[
    {key_id:"operator-key",role:"operator",public_key:$operator_key,public_key_sha256:$operator_sha},
    {key_id:"reviewer-key",role:"technical_reviewer",public_key:$reviewer_key,public_key_sha256:$reviewer_sha}],
    phase_policies:[{action:"activate",subject_kind:"final_manifest",allowed_hosts:["node1"],
      required_roles:["operator","technical_reviewer"],minimum_signatures:2,maximum_age_seconds:900}]}}
' >"$policy_manifest"
chmod 600 "$policy_manifest"
trusted_set_sha="$(jq -cS '.approvals.trusted_approvers' "$policy_manifest" | sha256sum | awk '{print $1}')"
payload="$TMP/payload.json"
jq -n '{canonicalization:"jq-cS-utf8-v1",namespace:"gdc-network-recovery-v1",approval_id:"approval-1",
  run_id:"run",subject_kind:"final_manifest",subject_sha256:("0"*64),action:"activate",host:"node1",
  not_before:"2026-09-13T00:00:00Z",expires_at:"2026-09-13T00:15:00Z",nonce:"0123456789abcdef"}' >"$payload"
payload_sha="$(jq -cS . "$payload" | sha256sum | awk '{print $1}')"
one_signature="$TMP/one-signature.json"
jq -n --slurpfile payload "$payload" --arg payload_sha "$payload_sha" --arg trusted_sha "$trusted_set_sha" '
  {approval:{signed_payload:$payload[0],canonical_payload_sha256:$payload_sha,
    signatures:[{key_id:"operator-key",armored_signature:"stub",signed_payload_sha256:$payload_sha}],
    verification:{trusted_approver_set_sha256:$trusted_sha,required_signatures:2,verified_key_ids:["operator-key"]}}}
' >"$one_signature"
chmod 600 "$one_signature"
assert_rc 'approval policy rejects an unmet signature and role threshold' 1 \
  recovery_verify_approval_signature "$one_signature" "$policy_manifest"
two_signatures="$TMP/two-signatures.json"
jq -n --slurpfile payload "$payload" --arg payload_sha "$payload_sha" --arg trusted_sha "$trusted_set_sha" '
  {approval:{signed_payload:$payload[0],canonical_payload_sha256:$payload_sha,
    signatures:[
      {key_id:"operator-key",armored_signature:"stub",signed_payload_sha256:$payload_sha},
      {key_id:"reviewer-key",armored_signature:"stub",signed_payload_sha256:$payload_sha}],
    verification:{trusted_approver_set_sha256:$trusted_sha,required_signatures:2,
      verified_key_ids:["operator-key","reviewer-key"]}}}
' >"$two_signatures"
chmod 600 "$two_signatures"
assert_rc 'approval policy accepts the exact threshold and required roles' 0 \
  recovery_verify_approval_signature "$two_signatures" "$policy_manifest"

# A multi-line public_key is refused before ssh-keygen runs.
smuggled_public_key="$(printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGENUINEKEY0000000000000000000000\nsmuggled-key ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIATTACKERKEY000000000000000000')"
smuggled_key_sha="$(printf '%s' "$smuggled_public_key" | sha256sum | awk '{print $1}')"
smuggling_manifest="$TMP/smuggling-manifest.json"
jq -n --arg public_key "$smuggled_public_key" --arg sha "$smuggled_key_sha" '
  {approvals:{trusted_approvers:[
    {key_id:"smuggled-key",role:"operator",public_key:$public_key,public_key_sha256:$sha}],
    phase_policies:[{action:"activate",subject_kind:"final_manifest",allowed_hosts:["node1"],
      required_roles:["operator"],minimum_signatures:1,maximum_age_seconds:900}]}}
' >"$smuggling_manifest"
chmod 600 "$smuggling_manifest"
smuggling_trusted_sha="$(jq -cS '.approvals.trusted_approvers' "$smuggling_manifest" | sha256sum | awk '{print $1}')"
smuggling_payload="$TMP/smuggling-payload.json"
jq -n '{canonicalization:"jq-cS-utf8-v1",namespace:"gdc-network-recovery-v1",approval_id:"approval-smuggle",
  run_id:"run",subject_kind:"final_manifest",subject_sha256:("0"*64),action:"activate",host:"node1",
  not_before:"2026-09-13T00:00:00Z",expires_at:"2026-09-13T00:15:00Z",nonce:"smuggle-nonce-0001"}' >"$smuggling_payload"
smuggling_payload_sha="$(jq -cS . "$smuggling_payload" | sha256sum | awk '{print $1}')"
smuggling_approval="$TMP/smuggling-approval.json"
jq -n --slurpfile payload "$smuggling_payload" --arg payload_sha "$smuggling_payload_sha" --arg trusted_sha "$smuggling_trusted_sha" '
  {approval:{signed_payload:$payload[0],canonical_payload_sha256:$payload_sha,
    signatures:[{key_id:"smuggled-key",armored_signature:"stub",signed_payload_sha256:$payload_sha}],
    verification:{trusted_approver_set_sha256:$trusted_sha,required_signatures:1,verified_key_ids:["smuggled-key"]}}}
' >"$smuggling_approval"
chmod 600 "$smuggling_approval"
assert_rc 'a public key smuggling a second signer line is refused before signing' 1 \
  recovery_verify_approval_signature "$smuggling_approval" "$smuggling_manifest"

# Approvals are single-use per run.
approval_once_home="$TMP/approval-once-home"; mkdir -m 700 "$approval_once_home"
export GDC_HOME="$approval_once_home"
RECOVERY_RUN_ID=once-run RECOVERY_HOST=x
RECOVERY_PENDING_APPROVAL_ID=approval-once RECOVERY_PENDING_APPROVAL_NONCE=nonce-0123456789
assert_rc 'first approval consumption succeeds' 0 recovery_consume_approval
assert_rc 'replaying the same approval id is rejected' 1 recovery_consume_approval
RECOVERY_PENDING_APPROVAL_ID=approval-two RECOVERY_PENDING_APPROVAL_NONCE=nonce-0123456789
assert_rc 'reusing the same nonce under a different approval id is rejected' 1 recovery_consume_approval
RECOVERY_PENDING_APPROVAL_ID=approval-three RECOVERY_PENDING_APPROVAL_NONCE=nonce-fresh-000000
assert_rc 'a genuinely new approval id and nonce can still be consumed' 0 recovery_consume_approval

# verify service is the only verification scope requiring an approval.  Its
# action must stay scoped: accepting verify_service and then comparing it to
# the unscoped verify action makes every valid service approval impossible.
verify_service_approval="$TMP/verify-service-approval.json"
jq -n --arg manifest "$shared_manifest_sha" '
  {receipt_type:"approval",run_id:"verify-run",host:"x",phase:"verify",manifest_sha256:$manifest,
   approval:{signed_payload:{approval_id:"verify-service-approval",run_id:"verify-run",host:"x",
     action:"verify_service",subject_kind:"final_manifest",subject_sha256:$manifest,
     not_before:"2000-01-01T00:00:00Z",expires_at:"2999-01-01T00:00:00Z",nonce:"verify-service-nonce-0001"},
     canonical_payload_sha256:""}}
' >"$verify_service_approval"
verify_service_payload_sha="$(jq -cS '.approval.signed_payload' "$verify_service_approval" | sha256sum | awk '{print tolower($1)}')"
jq --arg sha "$verify_service_payload_sha" '.approval.canonical_payload_sha256 = $sha' \
  "$verify_service_approval" >"$verify_service_approval.tmp"
mv "$verify_service_approval.tmp" "$verify_service_approval"; chmod 600 "$verify_service_approval"
assert_rc 'verify service accepts an approval bound to verify_service' 0 bash -c '
  source "$1"
  recovery_require_private_file() { return 0; }
  recovery_validate_json_schema() { return 0; }
  recovery_verify_approval_signature() { RECOVERY_APPROVAL_MAXIMUM_AGE_SECONDS=99999999999; return 0; }
  export GDC_HOME="$2" RECOVERY_RUN_ID=verify-run RECOVERY_HOST=x RECOVERY_PHASE=verify RECOVERY_SCOPE=service
  RECOVERY_STEP="" RECOVERY_MANIFEST_SHA256="$3" RECOVERY_MANIFEST="$4"
  recovery_validate_approval "$5"
' _ "$HERE/scripts/lib-recovery.sh" "$TMP/verify-service-home" "$shared_manifest_sha" "$status_manifest" "$verify_service_approval"

# The artifact exported from checkpoint is the input to rejoin, so it cannot
# merely be the checkpoint phase terminal verdict.  It must be a separate,
# schema-valid checkpoint receipt containing the checkpoint object.
checkpoint_export="$TMP/out/checkpoint-artifact.json"
checkpoint_missing_export="$TMP/out/checkpoint-artifact-missing.json"
checkpoint_fixture="$TMP/checkpoint.json"
checkpoint_attempt_dir="$TMP/checkpoint-export-home/runs/checkpoint-export-run/recovery/x/checkpoint/attempt-1"
checkpoint_attempt_id="attempt-1-$(printf '%s' 'checkpoint-export-run:x:checkpoint' | sha256sum | awk '{print substr($1,1,16)}')"
checkpoint_runtime_sha="$(jq -er '.runtime.binary_sha256' "$status_manifest")"
checkpoint_manifest_sha="$(recovery_sha256 "$status_manifest")"
jq --arg manifest "$checkpoint_manifest_sha" --arg attempt "$checkpoint_attempt_id" --arg attempt_dir "$checkpoint_attempt_dir" --arg runtime "$checkpoint_runtime_sha" '
  .receipt_type = "checkpoint" | del(.terminal) | .receipt_id = "checkpoint-artifact"
  | .run_id = "checkpoint-export-run" | .host = "x" | .attempt_id = $attempt | .attempt_number = 1
  | .append_only.attempt_directory = $attempt_dir | .append_only.prior_attempt_state = "none"
  | .verdict = "PASS" | .exit_status = 0
  | .phase = "checkpoint" | .manifest_binding_kind = "final_manifest" | .manifest_sha256 = $manifest
  | .command.selector = "checkpoint"
  | .details = {state:"CHECKPOINT_READY",reason_code:"checkpoint_export_contract",message:"checkpoint evidence complete"}
  | .checkpoint = {snapshot_height:10,snapshot_format:1,snapshot_hash:("1" * 64),snapshot_metadata_sha256:("2" * 64),
      chunks_verified:true,trust_height:10,trust_block_hash:("3" * 64),trust_height_equals_snapshot_height:true,
      supporting_light_blocks:[
        {height:10,block_hash:("4" * 64),commit_sha256:("5" * 64),validator_set_sha256:("6" * 64),consensus_params_sha256:("7" * 64),available_until:"2999-01-01T00:00:00Z"},
        {height:11,block_hash:("8" * 64),commit_sha256:("9" * 64),validator_set_sha256:("a" * 64),consensus_params_sha256:("b" * 64),available_until:"2999-01-01T00:00:00Z"},
        {height:12,block_hash:("c" * 64),commit_sha256:("d" * 64),validator_set_sha256:("e" * 64),consensus_params_sha256:("f" * 64),available_until:"2999-01-01T00:00:00Z"}],
      observed_at:"2026-09-13T00:00:00Z",expires_at:"2999-01-01T00:00:00Z",source_node_ids:[("0" * 40)],
      rpc_endpoints:["http://node1:26657"],runtime_sha256:$runtime,manifest_sha256:$manifest,single_source_risk_acceptance_required:false,
      host_snapshot_interval:100,host_snapshot_keep_recent:2,host_min_retain_blocks:0,snapshot_available_until:"2999-01-01T00:00:00Z"}
' "$inspect_output" >"$checkpoint_fixture"
chmod 400 "$checkpoint_fixture"
seed_controller "$TMP/checkpoint-export-home"
assert_rc 'checkpoint export requires a separate schema-valid checkpoint artifact' 0 bash -c '
  source "$1"; source "$7"
  export GDC_HOME="$2" RECOVERY_RUN_ID=checkpoint-export-run RECOVERY_HOST=x RECOVERY_PHASE=checkpoint RECOVERY_STEP="" RECOVERY_SCOPE=""
  RECOVERY_MANIFEST="$3" RECOVERY_MANIFEST_SHA256="$(recovery_sha256 "$3")" RECOVERY_PREDECESSOR_RECEIPTS="[]"
  recovery_next_attempt "$GDC_HOME/runs/$RECOVERY_RUN_ID/recovery/$RECOVERY_HOST/checkpoint"
  RECOVERY_STARTED_AT="2026-09-13T00:00:00Z"
  recovery_record_command --host x --run-id "$RECOVERY_RUN_ID"
  RECOVERY_OUTPUT="$6"
  ! recovery_export_receipt
  checkpoint_fixture_source="$4"
  recovery_test_checkpoint_handler() {
    cp "$checkpoint_fixture_source" "$1/checkpoint.json"
    chmod 400 "$1/checkpoint.json"
    jq -n "{verdict:\"PASS\",mutation_state:\"none\",reason:\"checkpoint_export_contract\",details:{}}" >"$1/phase-result.json"
  }
  qualify_test_handler checkpoint recovery_test_checkpoint_handler
  recovery_register_handler checkpoint recovery_test_checkpoint_handler
  recovery_run_registered_handler
  RECOVERY_OUTPUT="$5"
  recovery_export_receipt
  recovery_validate_json_schema "$(recovery_receipt_schema)" "$5"
  jq -e ".receipt_type == \"checkpoint\" and .phase == \"checkpoint\" and (.checkpoint | type == \"object\")" "$5" >/dev/null
  artifact_sha="$(recovery_sha256 "$5")"
  jq -e --arg sha "$artifact_sha" "[.observed_hashes[] | select(.sha256 == \$sha)] | length == 1" "$RECOVERY_ATTEMPT_DIR/receipt.json" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$TMP/checkpoint-export-home" "$status_manifest" "$checkpoint_fixture" "$checkpoint_export" "$checkpoint_missing_export" "$qual_helper"

for checkpoint_defect in attempt_id attempt_number attempt_directory nested_manifest nested_runtime \
    snapshot_height_not_above_source trust_height_mismatch hash_collision missing_light_block expired_window \
    snapshot_pruned_before_expiry light_block_pruned_before_expiry; do
  checkpoint_defect_fixture="$TMP/checkpoint-$checkpoint_defect.json"
  case "$checkpoint_defect" in
    attempt_id) jq '.attempt_id = "foreign-attempt"' "$checkpoint_fixture" >"$checkpoint_defect_fixture" ;;
    attempt_number) jq '.attempt_number = 2' "$checkpoint_fixture" >"$checkpoint_defect_fixture" ;;
    attempt_directory) jq '.append_only.attempt_directory = "/var/lib/gdc/foreign-attempt"' "$checkpoint_fixture" >"$checkpoint_defect_fixture" ;;
    nested_manifest) jq '.checkpoint.manifest_sha256 = ("f" * 64)' "$checkpoint_fixture" >"$checkpoint_defect_fixture" ;;
    nested_runtime) jq '.checkpoint.runtime_sha256 = ("f" * 64)' "$checkpoint_fixture" >"$checkpoint_defect_fixture" ;;
    # A3: recovery_validate_checkpoint_artifact only checked binding; these
    # mutate an otherwise binding-valid fixture to fail only the semantic S/T
    # and S+1/S+2 policy, proving it is now enforced at export too.
    snapshot_height_not_above_source) jq '.checkpoint.snapshot_height = 1' "$checkpoint_fixture" >"$checkpoint_defect_fixture" ;;
    trust_height_mismatch) jq '.checkpoint.trust_height = (.checkpoint.snapshot_height + 1)' "$checkpoint_fixture" >"$checkpoint_defect_fixture" ;;
    hash_collision) jq '.checkpoint.trust_block_hash = .checkpoint.snapshot_hash' "$checkpoint_fixture" >"$checkpoint_defect_fixture" ;;
    missing_light_block) jq '.checkpoint.supporting_light_blocks = [.checkpoint.supporting_light_blocks[0], .checkpoint.supporting_light_blocks[1]]' "$checkpoint_fixture" >"$checkpoint_defect_fixture" ;;
    expired_window) jq '.checkpoint.expires_at = "2000-01-01T00:00:00Z"' "$checkpoint_fixture" >"$checkpoint_defect_fixture" ;;
    # E1: the host's own retention settings must not let the snapshot or a
    # trust-window light block be pruned before the checkpoint itself expires.
    snapshot_pruned_before_expiry) jq '.checkpoint.snapshot_available_until = "2000-01-01T00:00:00Z"' "$checkpoint_fixture" >"$checkpoint_defect_fixture" ;;
    light_block_pruned_before_expiry) jq '.checkpoint.supporting_light_blocks[0].available_until = "2000-01-01T00:00:00Z"' "$checkpoint_fixture" >"$checkpoint_defect_fixture" ;;
  esac
  chmod 400 "$checkpoint_defect_fixture"
  assert_rc "checkpoint artifact with foreign $checkpoint_defect is refused" 0 bash -c '
    source "$1"
    export GDC_HOME="$2" RECOVERY_RUN_ID=checkpoint-export-run RECOVERY_HOST=x RECOVERY_PHASE=checkpoint RECOVERY_STEP="" RECOVERY_SCOPE=""
    RECOVERY_MANIFEST="$3" RECOVERY_MANIFEST_SHA256="$(recovery_sha256 "$3")"
    RECOVERY_ATTEMPT_ID="$4" RECOVERY_ATTEMPT_NUMBER=1 RECOVERY_ATTEMPT_DIR="$5"
    ! recovery_validate_checkpoint_artifact "$6"
  ' _ "$HERE/scripts/lib-recovery.sh" "$TMP/checkpoint-export-home" "$status_manifest" "$checkpoint_attempt_id" "$checkpoint_attempt_dir" "$checkpoint_defect_fixture"
done

# If the manifest changes while a handler runs, failure evidence itself must
# remain schema-valid.  In particular FAIL is an internal handler spelling;
# the persisted receipt must use the schema's FAILED verdict.
manifest_change_file="$TMP/manifest-change-during-phase.json"
printf '{"execution":{"scope":"working_network","lab_hosts":[],"supervised_live_allowed_selectors":[]}}\n' \
  >"$manifest_change_file"
chmod 600 "$manifest_change_file"
seed_controller "$TMP/manifest-change-home"
assert_rc 'manifest-change failure persists a schema-valid FAILED receipt' 0 bash -c '
  source "$1"; source "$4"
  recovery_test_mutate_manifest() {
    jq -n "{verdict:\"PASS\",mutation_state:\"none\",reason:\"handler_completed\",details:{}}" >"$1/phase-result.json"
    printf "changed-by-handler\\n" >"$RECOVERY_MANIFEST"
  }
  qualify_test_handler activate recovery_test_mutate_manifest
  recovery_register_handler activate recovery_test_mutate_manifest
  export GDC_HOME="$2" RECOVERY_RUN_ID=manifest-change-run RECOVERY_HOST=x RECOVERY_PHASE=activate RECOVERY_STEP="" RECOVERY_SCOPE=""
  RECOVERY_MANIFEST="$3" RECOVERY_MANIFEST_SHA256="$(recovery_sha256 "$3")" RECOVERY_PREDECESSOR_RECEIPTS="[]"
  recovery_next_attempt "$GDC_HOME/runs/$RECOVERY_RUN_ID/recovery/$RECOVERY_HOST/activate"
  RECOVERY_STARTED_AT="2026-09-13T00:00:00Z"
  recovery_record_command --host x --run-id "$RECOVERY_RUN_ID"
  set +e; recovery_run_registered_handler; rc=$?; set -e
  [[ "$rc" -eq 70 ]]
  recovery_validate_json_schema "$(recovery_receipt_schema)" "$RECOVERY_ATTEMPT_DIR/receipt.json"
  jq -e ".verdict == \"FAILED\" and .details.reason_code == \"manifest_changed_during_phase\"" "$RECOVERY_ATTEMPT_DIR/receipt.json" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$TMP/manifest-change-home" "$manifest_change_file" "$qual_helper"

# A1: a handler is allowed to report the internal "FAIL" spelling (not a
# schema verdict); recovery_terminal_receipt is the only place that
# normalizes it to the schema's FAILED before writing the receipt.
fail_handler_home="$TMP/fail-handler-home"; mkdir -m 700 "$fail_handler_home"
seed_controller "$fail_handler_home"
assert_rc 'a handler verdict of FAIL persists a schema-valid FAILED receipt' 0 bash -c '
  source "$1"; source "$4"
  recovery_test_fail_handler() {
    jq -n "{verdict:\"FAIL\",mutation_state:\"stopped_preserved\",reason:\"handler_reported_fail\",details:{}}" >"$1/phase-result.json"
  }
  qualify_test_handler retire recovery_test_fail_handler
  recovery_register_handler retire recovery_test_fail_handler
  export GDC_HOME="$2" RECOVERY_RUN_ID=fail-handler-run RECOVERY_HOST=x RECOVERY_PHASE=retire RECOVERY_STEP="" RECOVERY_SCOPE=""
  RECOVERY_MANIFEST="$3" RECOVERY_MANIFEST_SHA256="$(recovery_sha256 "$3")" RECOVERY_PREDECESSOR_RECEIPTS="[]"
  recovery_next_attempt "$GDC_HOME/runs/$RECOVERY_RUN_ID/recovery/x/retire"
  RECOVERY_STARTED_AT="2026-09-13T00:00:00Z"
  recovery_record_command --host x --run-id "$RECOVERY_RUN_ID"
  set +e; recovery_run_registered_handler; rc=$?; set -e
  [[ "$rc" -eq 3 ]]
  recovery_validate_json_schema "$(recovery_receipt_schema)" "$RECOVERY_ATTEMPT_DIR/receipt.json"
  jq -e ".verdict == \"FAILED\" and .details.reason_code == \"handler_reported_fail\"" "$RECOVERY_ATTEMPT_DIR/receipt.json" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$fail_handler_home" "$status_manifest" "$qual_helper"

# A refusal before the handler leaves the approval unconsumed.
approval_order_home="$TMP/approval-order-home"; mkdir -m 700 "$approval_order_home"
export GDC_HOME="$approval_order_home"
RECOVERY_RUN_ID=order-run RECOVERY_HOST=x RECOVERY_PHASE=freeze RECOVERY_STEP='' RECOVERY_SCOPE=''
RECOVERY_MANIFEST_SHA256='' RECOVERY_PREDECESSOR_RECEIPTS='[]'
recovery_next_attempt "$GDC_HOME/runs/order-run/recovery/x/freeze"
export RECOVERY_STARTED_AT='2026-09-13T00:00:00Z'
recovery_record_command --host x --run-id order-run
RECOVERY_PENDING_APPROVAL_ID=approval-order RECOVERY_PENDING_APPROVAL_NONCE=nonce-order-0000001
assert_rc 'refusal before any handler exists still returns the REFUSED code' 3 recovery_run_registered_handler
if [[ ! -e "$GDC_HOME/runs/order-run/recovery/approval-consumption" ]]; then
  ok 'no consumption marker is created when the phase has no registered handler'
else
  bad 'no consumption marker is created when the phase has no registered handler'
fi

# A handler that exits 0 without a result is not a PASS.
no_result_home="$TMP/no-result-home"; mkdir -m 700 "$no_result_home"
no_result_manifest="$TMP/no-result-manifest.json"
printf '{"execution":{"scope":"working_network","lab_hosts":[],"supervised_live_allowed_selectors":[]}}\n' \
  >"$no_result_manifest"
assert_rc 'a handler that exits 0 without a phase-result.json still returns 70' 70 bash -c '
  source "$1"; source "$3"
  recovery_test_handler_rc0_no_result() { return 0; }
  qualify_test_handler freeze recovery_test_handler_rc0_no_result
  recovery_register_handler freeze recovery_test_handler_rc0_no_result
  export GDC_HOME="$2"
  RECOVERY_RUN_ID=no-result-run RECOVERY_HOST=x RECOVERY_PHASE=freeze RECOVERY_STEP="" RECOVERY_SCOPE=""
  RECOVERY_MANIFEST="$4" RECOVERY_MANIFEST_SHA256="$(printf "%064d" 0)" RECOVERY_PREDECESSOR_RECEIPTS="[]"
  recovery_next_attempt "$GDC_HOME/runs/no-result-run/recovery/x/freeze"
  RECOVERY_STARTED_AT="2026-09-13T00:00:00Z"
  recovery_record_command --host x --run-id no-result-run
  recovery_run_registered_handler
' _ "$HERE/scripts/lib-recovery.sh" "$no_result_home" "$qual_helper" "$no_result_manifest"

# An approval consumed earlier in the run is refused at validation.
reuse_home="$TMP/approval-reuse-home"; mkdir -m 700 "$reuse_home"
reuse_marker_dir="$reuse_home/runs/reuse-run/recovery/approval-consumption"
mkdir -p "$reuse_marker_dir"
printf 'already-consumed\n' >"$reuse_marker_dir/approval-id.approval-reuse-1"
chmod 400 "$reuse_marker_dir/approval-id.approval-reuse-1"
reuse_manifest_sha="$(recovery_sha256 "$status_manifest")"
reuse_payload="$TMP/reuse-payload.json"
jq -n --arg manifest_sha "$reuse_manifest_sha" '
  {canonicalization:"jq-cS-utf8-v1",namespace:"gdc-network-recovery-v1",approval_id:"approval-reuse-1",
   run_id:"reuse-run",subject_kind:"final_manifest",subject_sha256:$manifest_sha,action:"activate",host:"x",
   not_before:"2026-09-13T00:00:00Z",expires_at:"2026-09-13T00:15:00Z",nonce:"reuse-nonce-0000001"}
' >"$reuse_payload"
reuse_payload_sha="$(jq -cS . "$reuse_payload" | sha256sum | awk '{print $1}')"
reuse_approval="$TMP/reuse-approval.json"
jq -n --slurpfile payload "$reuse_payload" --arg payload_sha "$reuse_payload_sha" --arg manifest_sha "$reuse_manifest_sha" '
  {receipt_type:"approval",run_id:"reuse-run",host:"x",phase:"activate",manifest_sha256:$manifest_sha,
   approval:{signed_payload:$payload[0],canonical_payload_sha256:$payload_sha}}
' >"$reuse_approval"
chmod 600 "$reuse_approval"
assert_rc 'an approval already marked consumed in this run is refused' 1 bash -c '
  source "$1"
  recovery_require_private_file() { return 0; }
  recovery_validate_json_schema() { return 0; }
  recovery_verify_approval_signature() { RECOVERY_APPROVAL_MAXIMUM_AGE_SECONDS=900; return 0; }
  export GDC_HOME="$2"
  RECOVERY_RUN_ID=reuse-run RECOVERY_HOST=x RECOVERY_PHASE=activate RECOVERY_STEP="" RECOVERY_SCOPE=""
  RECOVERY_MANIFEST_SHA256="$3" RECOVERY_MANIFEST="$4"
  recovery_validate_approval "$5"
' _ "$HERE/scripts/lib-recovery.sh" "$reuse_home" "$reuse_manifest_sha" "$status_manifest" "$reuse_approval"
unset GDC_HOME

expired_payload="$TMP/expired-payload.json"
manifest_sha="$(recovery_sha256 "$status_manifest")"
jq -n --arg manifest_sha "$manifest_sha" '
  {canonicalization:"jq-cS-utf8-v1",namespace:"gdc-network-recovery-v1",approval_id:"expired-approval",
   run_id:"expired-run",subject_kind:"final_manifest",subject_sha256:$manifest_sha,action:"activate",host:"x",
   not_before:"2000-01-01T00:00:00Z",expires_at:"2000-01-01T00:01:00Z",nonce:"0123456789abcdef"}
' >"$expired_payload"
expired_payload_sha="$(jq -cS . "$expired_payload" | sha256sum | awk '{print $1}')"
expired_approval="$TMP/expired-approval.json"
jq -n --slurpfile payload "$expired_payload" --arg payload_sha "$expired_payload_sha" --arg manifest_sha "$manifest_sha" '
  {receipt_type:"approval",run_id:"expired-run",host:"x",phase:"activate",manifest_sha256:$manifest_sha,
   approval:{signed_payload:$payload[0],canonical_payload_sha256:$payload_sha}}
' >"$expired_approval"
chmod 600 "$expired_approval"
# The single-quoted script deliberately expands only inside the child shell.
# shellcheck disable=SC2016
assert_rc 'expired approval is rejected independently of its claimed verification' 1 bash -c '
  source "$1"
  recovery_require_private_file() { return 0; }
  recovery_validate_json_schema() { return 0; }
  recovery_verify_approval_signature() { RECOVERY_APPROVAL_MAXIMUM_AGE_SECONDS=900; return 0; }
  RECOVERY_RUN_ID=expired-run RECOVERY_HOST=x RECOVERY_PHASE=activate
  RECOVERY_STEP="" RECOVERY_SCOPE="" RECOVERY_MANIFEST_SHA256="$2" RECOVERY_MANIFEST="$3"
  recovery_validate_approval "$4"
' _ "$HERE/scripts/lib-recovery.sh" "$manifest_sha" "$status_manifest" "$expired_approval"

# Schema-valid approval: the refusal must come from signature verification.
policy_manifest_sha="$(recovery_sha256 "$policy_manifest")"
untrusted_payload="$TMP/untrusted-payload.json"
jq -n --arg manifest_sha "$policy_manifest_sha" '
  {canonicalization:"jq-cS-utf8-v1",namespace:"gdc-network-recovery-v1",approval_id:"approval-untrusted",
   run_id:"run",subject_kind:"final_manifest",subject_sha256:$manifest_sha,action:"activate",host:"node1",
   not_before:"2000-01-01T00:00:00Z",expires_at:"2999-01-01T00:00:00Z",nonce:"untrusted-nonce-000001"}
' >"$untrusted_payload"
untrusted_payload_sha="$(jq -cS . "$untrusted_payload" | sha256sum | awk '{print $1}')"
untrusted_approval="$TMP/untrusted-approval.json"
jq -n --slurpfile payload "$untrusted_payload" --arg payload_sha "$untrusted_payload_sha" --arg manifest_sha "$policy_manifest_sha" '
  {receipt_type:"approval",run_id:"run",host:"node1",phase:"activate",manifest_sha256:$manifest_sha,
   approval:{signed_payload:$payload[0],canonical_payload_sha256:$payload_sha,
     signatures:[{key_id:"intruder-key",armored_signature:"stub",signed_payload_sha256:$payload_sha}]}}
' >"$untrusted_approval"
chmod 600 "$untrusted_approval"
assert_rc 'unsigned approval is refused' 1 bash -c '
  source "$1"
  recovery_require_private_file() { return 0; }
  recovery_validate_json_schema() { return 0; }
  RECOVERY_RUN_ID=run RECOVERY_HOST=node1 RECOVERY_PHASE=activate RECOVERY_STEP="" RECOVERY_SCOPE=""
  RECOVERY_MANIFEST_SHA256="$2" RECOVERY_MANIFEST="$3"
  recovery_validate_approval "$4"
' _ "$HERE/scripts/lib-recovery.sh" "$policy_manifest_sha" "$policy_manifest" "$untrusted_approval"

# Schema-valid manifest: the refusal must come from the host binding.
assert_rc 'foreign host manifest is refused' 1 recovery_validate_manifest "$status_manifest" node2 activate

# Tripwire: fails once any of these phases gets a registered handler.
no_handler_home="$TMP/no-handler-home"; mkdir -m 700 "$no_handler_home"
export GDC_HOME="$no_handler_home"
for entry in freeze: stage: checkpoint: retire: rejoin: resume:signers resume:poc resume:handoff abort:; do
  phase="${entry%%:*}"
  step="${entry#*:}"
  RECOVERY_RUN_ID="no-handler-$phase${step:+-$step}" RECOVERY_HOST=x RECOVERY_PHASE="$phase"
  RECOVERY_STEP="$step" RECOVERY_SCOPE='' RECOVERY_PREDECESSOR_RECEIPTS='[]'
  RECOVERY_MANIFEST_SHA256="$(printf '%064d' 0)"
  phase_path="$(recovery_phase_storage_path "$phase" "$step")"
  recovery_next_attempt "$GDC_HOME/runs/$RECOVERY_RUN_ID/recovery/x/$phase_path"
  RECOVERY_STARTED_AT="$(date -u +%FT%TZ)"
  recovery_record_command --host x --run-id "$RECOVERY_RUN_ID"
  set +e
  recovery_run_registered_handler >/dev/null 2>&1
  rc=$?
  set -e
  label="$phase"; [[ -z "$step" ]] || label="$phase --step $step"
  if (( rc == 3 )); then
    ok "no-handler $label refuses with the REFUSED code and never 0"
  else
    bad "no-handler $label refuses with the REFUSED code and never 0 (got $rc)"
  fi
done
unset GDC_HOME

# Static side-effect guard: recovery code may not grow remote/runtime actions
# beyond the one reviewed, read-only bounded-observation catalog (HF-05
# block 1, `inspect` only). ssh/docker/curl are confined to the sentinel-
# marked catalog in lib-recovery.sh; scp/rsync/podman/nc/inferenced stay
# forbidden everywhere, including inside that catalog, except the one
# reviewed `command -v inferenced` path lookup (E5): it only resolves a
# path for hashing and never invokes the binary.
guard_scan() {
  # $1=pattern, remaining args=files/text to scan (files, or "-" for stdin)
  if command -v rg >/dev/null 2>&1; then rg -n "$1" "${@:2}"; else grep -En "$1" "${@:2}"; fi
}
catalog_outside="$TMP/guard-outside.sh"
catalog_inside="$TMP/guard-inside.sh"
sed '/RECOVERY REMOTE COMMAND CATALOG BEGIN/,/RECOVERY REMOTE COMMAND CATALOG END/d' \
  "$HERE/scripts/lib-recovery.sh" >"$catalog_outside"
sed -n '/RECOVERY REMOTE COMMAND CATALOG BEGIN/,/RECOVERY REMOTE COMMAND CATALOG END/p' \
  "$HERE/scripts/lib-recovery.sh" >"$catalog_inside"

set +e
guard_scan '(^|[[:space:]])(ssh|scp|rsync|docker|podman|curl|nc|inferenced)([[:space:]]|$)' \
  "$catalog_outside" "$HERE/scripts/phase-network-recover.sh" >/dev/null
search_rc=$?
set -e
case "$search_rc" in
  0) bad 'recovery implementation contains a remote/runtime command outside the reviewed catalog' ;;
  1) ok 'recovery implementation has no SSH/Docker/network side effects outside the reviewed catalog' ;;
  *) bad 'recovery side-effect scan could not run' ;;
esac

catalog_inside_filtered="$TMP/guard-inside-filtered.sh"
sed 's/command -v inferenced/COMMAND_V_INFERENCED_PATH_LOOKUP_ONLY/g' "$catalog_inside" >"$catalog_inside_filtered"
set +e
guard_scan '(^|[[:space:]])(scp|rsync|podman|nc|inferenced)([[:space:]]|$)' "$catalog_inside_filtered" >/dev/null
search_rc=$?
set -e
case "$search_rc" in
  0) bad 'the reviewed remote command catalog contains a forbidden command' ;;
  1) ok 'the reviewed remote command catalog never uses scp/rsync/podman/nc/inferenced beyond the reviewed command -v lookup' ;;
  *) bad 'recovery side-effect catalog scan could not run' ;;
esac

# HF-05 block 1: full bounded SSH host inspect. The fixture answers each
# fixed catalog command by matching on its text; scenario knobs are env
# vars so one fixture script covers every case below. Real ssh/docker/curl
# never run: $BIN/ssh always execs this fixture instead.
ssh_fixture="$TMP/ssh-fixture.py"
cat >"$ssh_fixture" <<'PYEOF'
#!/usr/bin/env python3
import hashlib
import json
import os
import re
import sys
import time

remote_cmd = sys.argv[-1] if len(sys.argv) > 1 else ""

def env(name, default=""):
    return os.environ.get(name, default)

def hexhash(seed):
    return hashlib.sha256(seed.encode()).hexdigest()

log_file = env("RECOVERY_FIXTURE_LOG_FILE")
if log_file:
    with open(log_file, "a", encoding="utf-8") as fh:
        fh.write(remote_cmd + "\n")

# Simulates what WOULD leak if the catalog ever read key material directly;
# the real catalog never sends a command matching this, so it never fires.
if re.search(r"priv_validator_key|cat .*signer.*key", remote_cmd):
    print(env("RECOVERY_FIXTURE_LEAK_MARKER", "LEAKED-PRIVATE-KEY-MATERIAL"))
    sys.exit(0)

height1 = int(env("RECOVERY_FIXTURE_HEIGHT1", "100"))
height2 = int(env("RECOVERY_FIXTURE_HEIGHT2", str(height1)))
chain_id = env("RECOVERY_FIXTURE_CHAIN_ID", "gonka-devnet-community")
archive_ok = env("RECOVERY_FIXTURE_ARCHIVE_OK", "1") == "1"
validators_h1 = env("RECOVERY_FIXTURE_VALIDATORS_H1", "aaaa1:34,aaaa2:34,aaaa3:34,aaaa4:33")
signer_addrs = [a for a in env("RECOVERY_FIXTURE_SIGNER_ADDRS", "aaaa1").split(",") if a]
fail_label = env("RECOVERY_FIXTURE_FAIL_LABEL")
sleep_label = env("RECOVERY_FIXTURE_SLEEP_LABEL")
sleep_seconds = float(env("RECOVERY_FIXTURE_SLEEP_SECONDS", "0"))
state_file = env("RECOVERY_FIXTURE_STATE_FILE")

if "http://127.0.0.1:26657/status" in remote_cmd:
    label = "status"
elif "/genesis" in remote_cmd:
    label = "genesis"
elif "/commit?height=" in remote_cmd:
    label = "commit"
elif "/validators?height=" in remote_cmd:
    label = "validators"
elif "/block?height=" in remote_cmd:
    label = "block"
elif "docker compose images" in remote_cmd:
    label = "image"
elif "Mounts" in remote_cmd:
    label = "mounts"
elif "RestartPolicy" in remote_cmd:
    label = "restart"
elif "sha256sum" in remote_cmd and "command -v inferenced" in remote_cmd:
    label = "binary"
elif "priv_validator_laddr" in remote_cmd:
    label = "signer_config"
elif "tmkms" in remote_cmd:
    label = "tmkms"
else:
    label = "unknown"

if label == sleep_label:
    time.sleep(sleep_seconds)
if label == fail_label:
    sys.exit(1)

if label == "status":
    n = 0
    if state_file and os.path.exists(state_file):
        n = int(open(state_file, encoding="utf-8").read().strip() or "0")
    n += 1
    if state_file:
        open(state_file, "w", encoding="utf-8").write(str(n))
    h = height1 if n == 1 else height2
    print(json.dumps({"result": {"node_info": {"network": chain_id}, "sync_info": {
        "latest_block_height": str(h), "latest_block_hash": hexhash("block-%d" % h),
        "earliest_block_height": "1" if archive_ok else "500", "catching_up": False}}}))
elif label == "genesis":
    print(json.dumps({"result": {"genesis": {"chain_id": chain_id}}}))
elif label == "block":
    print(json.dumps({"result": {"block": {"header": {"height": "1"}}}}))
elif label == "commit":
    m = re.search(r"height=(\d+)", remote_cmd)
    h = int(m.group(1)) if m else height1
    sigs = [{"block_id_flag": 2, "validator_address": a, "signature": "c2ln"} for a in signer_addrs]
    print(json.dumps({"result": {"signed_header": {"header": {"height": str(h), "app_hash": hexhash("app-%d" % h)},
        "commit": {"height": str(h), "signatures": sigs}}}}))
elif label == "validators":
    hm = re.search(r"height=(\d+)", remote_cmd)
    pm = re.search(r"page=(\d+)", remote_cmd)
    page = int(pm.group(1)) if pm else 1
    entries = []
    for pair in validators_h1.split(","):
        if not pair:
            continue
        addr, power = pair.split(":")
        entries.append({"address": addr, "voting_power": power})
    if page == 1:
        print(json.dumps({"result": {"validators": entries, "total": str(len(entries))}}))
    else:
        print(json.dumps({"result": {"validators": [], "total": str(len(entries))}}))
elif label == "image":
    print(json.dumps([{"ID": hexhash("image")[:12]}]))
elif label == "mounts":
    print(json.dumps([{"Source": "/srv/dai/data/x/inference", "Destination": "/root/.inference"}]))
elif label == "restart":
    print("unless-stopped")
elif label == "binary":
    print("%s  /usr/bin/inferenced" % hexhash("binary"))
elif label == "signer_config":
    print('priv_validator_laddr = "tcp://127.0.0.1:26658"')
elif label == "tmkms":
    print("absent")
else:
    sys.exit(1)
PYEOF
chmod 700 "$ssh_fixture"

# Full, fresh, complete host inspect: evidence_complete and it genuinely
# unlocks prepare through the real predecessor gate (not a hand-built fixture).
fresh_inspect_home="$TMP/fresh-inspect-home"; mkdir -m 700 "$fresh_inspect_home"
fresh_inspect_out="$TMP/out/fresh-inspect.json"
assert_rc 'full fresh host inspect is schema-valid and evidence_complete' 0 bash -c '
  source "$1"
  export GDC_HOME="$2" RECOVERY_TEST_SSH_FIXTURE="$3"
  export RECOVERY_FIXTURE_HEIGHT1=100 RECOVERY_FIXTURE_HEIGHT2=100 RECOVERY_FIXTURE_ARCHIVE_OK=1
  export RECOVERY_FIXTURE_VALIDATORS_H1="aaaa1:34,aaaa2:34,aaaa3:34,aaaa4:33" RECOVERY_FIXTURE_SIGNER_ADDRS=aaaa1
  export RECOVERY_FIXTURE_STATE_FILE="$4"
  recovery_main inspect --incident GNK-LAB-2026-0001 --host x --run-id fresh-run --output "$5"
  recovery_validate_json_schema "$(recovery_receipt_schema)" "$5"
  jq -e ".verdict == \"OBSERVED\" and .details.inspection.evidence_complete == true
    and .details.inspection.quorum_recoverable == false and .details.inspection.higher_commit_found == false
    and .terminal.evidence_complete == true" "$5" >/dev/null
  RECOVERY_RUN_ID=fresh-run RECOVERY_HOST=x
  recovery_require_predecessor inspect x "" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$fresh_inspect_home" "$ssh_fixture" "$TMP/fresh-status-count" "$fresh_inspect_out"

# A stale evidence window refuses to unlock prepare even though every probe
# succeeded. Pin observation timestamps and advance the age-check clock by
# one second: a fast runner can otherwise finish all probes in the same second.
stale_inspect_home="$TMP/stale-inspect-home"; mkdir -m 700 "$stale_inspect_home"
stale_inspect_out="$TMP/out/stale-inspect.json"
assert_rc 'stale evidence cannot unlock prepare' 0 bash -c '
  source "$1"
  export GDC_HOME="$2" RECOVERY_TEST_SSH_FIXTURE="$3" RECOVERY_INSPECT_MAX_EVIDENCE_AGE_SECONDS=0
  fixture_observed_at="$(command date -u +%FT%TZ)"
  fixture_observed_epoch="$(recovery_epoch "$fixture_observed_at")"
  date() {
    case "$*" in
      "-u +%FT%TZ") printf "%s\n" "$fixture_observed_at" ;;
      "-u +%s") printf "%s\n" "$((fixture_observed_epoch + 1))" ;;
      *) command date "$@" ;;
    esac
  }
  export RECOVERY_FIXTURE_HEIGHT1=100 RECOVERY_FIXTURE_HEIGHT2=100 RECOVERY_FIXTURE_ARCHIVE_OK=1
  export RECOVERY_FIXTURE_VALIDATORS_H1="aaaa1:34,aaaa2:34,aaaa3:34,aaaa4:33" RECOVERY_FIXTURE_SIGNER_ADDRS=aaaa1
  export RECOVERY_FIXTURE_STATE_FILE="$4"
  recovery_main inspect --incident GNK-LAB-2026-0001 --host x --run-id stale-run --output "$5"
  recovery_validate_json_schema "$(recovery_receipt_schema)" "$5"
  jq -e ".details.inspection.evidence_fresh == false and .details.inspection.evidence_complete == false
    and .details.reason_code == \"inspect_evidence_stale\"" "$5" >/dev/null
  RECOVERY_RUN_ID=stale-run RECOVERY_HOST=x
  ! recovery_require_predecessor inspect x "" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$stale_inspect_home" "$ssh_fixture" "$TMP/stale-status-count" "$stale_inspect_out"

# A malformed/incomplete response from one required probe (not a timeout)
# falls back to the stage-1 controller-only shape: a schema-valid but
# non-unlocking receipt, never a fabricated partial inspection.
incomplete_inspect_home="$TMP/incomplete-inspect-home"; mkdir -m 700 "$incomplete_inspect_home"
incomplete_inspect_out="$TMP/out/incomplete-inspect.json"
assert_rc 'an incomplete observation set yields an incomplete receipt, not success' 0 bash -c '
  source "$1"
  export GDC_HOME="$2" RECOVERY_TEST_SSH_FIXTURE="$3" RECOVERY_FIXTURE_FAIL_LABEL=mounts
  export RECOVERY_FIXTURE_HEIGHT1=100 RECOVERY_FIXTURE_HEIGHT2=100 RECOVERY_FIXTURE_ARCHIVE_OK=1
  export RECOVERY_FIXTURE_VALIDATORS_H1="aaaa1:34,aaaa2:34,aaaa3:34,aaaa4:33" RECOVERY_FIXTURE_SIGNER_ADDRS=aaaa1
  export RECOVERY_FIXTURE_STATE_FILE="$4"
  recovery_main inspect --incident GNK-LAB-2026-0001 --host x --run-id incomplete-run --output "$5"
  recovery_validate_json_schema "$(recovery_receipt_schema)" "$5"
  jq -e "(.details.inspection // null) == null and .details.reason_code == \"local_inspection_requires_bounded_host_evidence\"" "$5" >/dev/null
  RECOVERY_RUN_ID=incomplete-run RECOVERY_HOST=x
  ! recovery_require_predecessor inspect x "" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$incomplete_inspect_home" "$ssh_fixture" "$TMP/incomplete-status-count" "$incomplete_inspect_out"

# An ssh command that times out (rather than answering wrong) hits the same
# fallback: schema-valid, non-terminal, never a hang.
timeout_inspect_home="$TMP/timeout-inspect-home"; mkdir -m 700 "$timeout_inspect_home"
timeout_inspect_out="$TMP/out/timeout-inspect.json"
assert_rc 'an ssh command timeout yields a schema-valid non-terminal receipt' 0 bash -c '
  source "$1"
  export GDC_HOME="$2" RECOVERY_TEST_SSH_FIXTURE="$3" RECOVERY_FIXTURE_SLEEP_LABEL=genesis RECOVERY_FIXTURE_SLEEP_SECONDS=5
  export RECOVERY_SSH_COMMAND_TIMEOUT_SECONDS=1 RECOVERY_SSH_CONNECT_TIMEOUT_SECONDS=1
  export RECOVERY_FIXTURE_HEIGHT1=100 RECOVERY_FIXTURE_HEIGHT2=100 RECOVERY_FIXTURE_ARCHIVE_OK=1
  export RECOVERY_FIXTURE_VALIDATORS_H1="aaaa1:34,aaaa2:34,aaaa3:34,aaaa4:33" RECOVERY_FIXTURE_SIGNER_ADDRS=aaaa1
  export RECOVERY_FIXTURE_STATE_FILE="$4"
  recovery_main inspect --incident GNK-LAB-2026-0001 --host x --run-id timeout-run --output "$5"
  recovery_validate_json_schema "$(recovery_receipt_schema)" "$5"
  jq -e ".verdict == \"OBSERVED\" and .terminal.evidence_complete == false" "$5" >/dev/null
  RECOVERY_RUN_ID=timeout-run RECOVERY_HOST=x
  ! recovery_require_predecessor inspect x "" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$timeout_inspect_home" "$ssh_fixture" "$TMP/timeout-status-count" "$timeout_inspect_out"

# A confirmed commit above H (the second bounded sample advances and its
# commit verifies) is a hard stop: evidence is complete but not unlocking.
higher_commit_home="$TMP/higher-commit-home"; mkdir -m 700 "$higher_commit_home"
higher_commit_out="$TMP/out/higher-commit.json"
assert_rc 'a confirmed commit above H refuses to unlock prepare' 0 bash -c '
  source "$1"
  export GDC_HOME="$2" RECOVERY_TEST_SSH_FIXTURE="$3"
  export RECOVERY_FIXTURE_HEIGHT1=100 RECOVERY_FIXTURE_HEIGHT2=101 RECOVERY_FIXTURE_ARCHIVE_OK=1
  export RECOVERY_FIXTURE_VALIDATORS_H1="aaaa1:34,aaaa2:34,aaaa3:34,aaaa4:33" RECOVERY_FIXTURE_SIGNER_ADDRS=aaaa1
  export RECOVERY_FIXTURE_STATE_FILE="$4"
  recovery_main inspect --incident GNK-LAB-2026-0001 --host x --run-id higher-commit-run --output "$5"
  recovery_validate_json_schema "$(recovery_receipt_schema)" "$5"
  jq -e ".details.inspection.higher_commit_found == true and .details.inspection.evidence_complete == false
    and .details.reason_code == \"higher_commit_confirmed_above_source_height\"" "$5" >/dev/null
  RECOVERY_RUN_ID=higher-commit-run RECOVERY_HOST=x
  ! recovery_require_predecessor inspect x "" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$higher_commit_home" "$ssh_fixture" "$TMP/higher-commit-status-count" "$higher_commit_out"

# A recoverable original quorum (signers holding >2/3 of the H+1 set's
# power, matching the incident's own 135/91 arithmetic) is also a hard stop.
quorum_home="$TMP/quorum-recoverable-home"; mkdir -m 700 "$quorum_home"
quorum_out="$TMP/out/quorum-recoverable.json"
assert_rc 'a recoverable original quorum refuses to unlock prepare' 0 bash -c '
  source "$1"
  export GDC_HOME="$2" RECOVERY_TEST_SSH_FIXTURE="$3"
  export RECOVERY_FIXTURE_HEIGHT1=100 RECOVERY_FIXTURE_HEIGHT2=100 RECOVERY_FIXTURE_ARCHIVE_OK=1
  export RECOVERY_FIXTURE_VALIDATORS_H1="aaaa1:34,aaaa2:34,aaaa3:34,aaaa4:33" RECOVERY_FIXTURE_SIGNER_ADDRS="aaaa1,aaaa2,aaaa3"
  export RECOVERY_FIXTURE_STATE_FILE="$4"
  recovery_main inspect --incident GNK-LAB-2026-0001 --host x --run-id quorum-run --output "$5"
  recovery_validate_json_schema "$(recovery_receipt_schema)" "$5"
  jq -e ".details.inspection.quorum_recoverable == true and .details.inspection.quorum_power.available_power == \"102\"
    and .details.inspection.quorum_power.strict_required_power == \"91\"
    and .details.inspection.evidence_complete == false
    and .details.reason_code == \"original_quorum_recoverable\"" "$5" >/dev/null
  RECOVERY_RUN_ID=quorum-run RECOVERY_HOST=x
  ! recovery_require_predecessor inspect x "" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$quorum_home" "$ssh_fixture" "$TMP/quorum-status-count" "$quorum_out"

# Hex casing from independent RPC endpoints must not change quorum weight.
for address_case in upper_commit upper_validators mixed; do
  case_home="$TMP/quorum-$address_case"; mkdir -m 700 "$case_home"
  assert_rc "quorum detection normalizes addresses ($address_case)" 0 bash -c '
    source "$1"
    export GDC_HOME="$2" RECOVERY_TEST_SSH_FIXTURE="$3"
    export RECOVERY_FIXTURE_HEIGHT1=100 RECOVERY_FIXTURE_HEIGHT2=100 RECOVERY_FIXTURE_ARCHIVE_OK=1
    case "$6" in
      upper_commit) export RECOVERY_FIXTURE_VALIDATORS_H1="aaaa1:34,aaaa2:34,aaaa3:34,aaaa4:33" RECOVERY_FIXTURE_SIGNER_ADDRS="AAAA1,AAAA2,AAAA3" ;;
      upper_validators) export RECOVERY_FIXTURE_VALIDATORS_H1="AAAA1:34,AAAA2:34,AAAA3:34,AAAA4:33" RECOVERY_FIXTURE_SIGNER_ADDRS="aaaa1,aaaa2,aaaa3" ;;
      mixed) export RECOVERY_FIXTURE_VALIDATORS_H1="AaAa1:34,aAaA2:34,AAaa3:34,aaaa4:33" RECOVERY_FIXTURE_SIGNER_ADDRS="aAaA1,AaAa2,aaAA3" ;;
    esac
    export RECOVERY_FIXTURE_STATE_FILE="$4"
    recovery_main inspect --incident GNK-LAB-2026-0001 --host x --run-id quorum-case --output "$5"
    jq -e ".details.inspection.quorum_recoverable == true and .details.inspection.quorum_power.available_power == \"102\"
      and .details.inspection.evidence_complete == false" "$5" >/dev/null
    ! recovery_require_predecessor inspect x ""
  ' _ "$HERE/scripts/lib-recovery.sh" "$case_home" "$ssh_fixture" "$case_home/count" "$TMP/out/$address_case.json" "$address_case"
done

# A host that would leak key material through an unexpected channel never
# gets asked: the fixed catalog never sends a command matching that leak
# path, so the marker never reaches evidence, the receipt, or command.json.
leak_home="$TMP/leak-home"; mkdir -m 700 "$leak_home"
leak_out="$TMP/out/leak.json"
leak_log="$TMP/leak-remote-commands.log"; : >"$leak_log"
assert_rc 'a host that would leak key material is never asked for it' 0 bash -c '
  source "$1"
  export GDC_HOME="$2" RECOVERY_TEST_SSH_FIXTURE="$3" RECOVERY_FIXTURE_LEAK_MARKER="LEAKED-PRIVATE-KEY-MATERIAL"
  export RECOVERY_FIXTURE_LOG_FILE="$4"
  export RECOVERY_FIXTURE_HEIGHT1=100 RECOVERY_FIXTURE_HEIGHT2=100 RECOVERY_FIXTURE_ARCHIVE_OK=1
  export RECOVERY_FIXTURE_VALIDATORS_H1="aaaa1:34,aaaa2:34,aaaa3:34,aaaa4:33" RECOVERY_FIXTURE_SIGNER_ADDRS=aaaa1
  export RECOVERY_FIXTURE_STATE_FILE="$5"
  recovery_main inspect --incident GNK-LAB-2026-0001 --host x --run-id leak-run --output "$6"
' _ "$HERE/scripts/lib-recovery.sh" "$leak_home" "$ssh_fixture" "$leak_log" "$TMP/leak-status-count" "$leak_out"
if ! grep -q 'priv_validator_key\|cat .*signer.*key' "$leak_log" \
    && ! grep -qr 'LEAKED-PRIVATE-KEY-MATERIAL' "$leak_home" "$leak_out" 2>/dev/null; then
  ok 'no remote command requests key material, and no evidence carries the leak marker'
else
  bad 'no remote command requests key material, and no evidence carries the leak marker'
fi

# status: local only, but reports the next gate and the singleton budget
# computed from the manifest and the best height any local receipt has seen.
status_budget_manifest="$TMP/status-budget-manifest.json"
jq --arg deadline "2099-01-01T00:00:00Z" '
  .singleton.singleton_deadline_utc = $deadline | .singleton.singleton_max_blocks = 1000 | .singleton.first_counted_height = 100
' "$status_manifest" >"$status_budget_manifest"
chmod 600 "$status_budget_manifest"
status_budget_home="$TMP/status-budget-home"; mkdir -m 700 "$status_budget_home"
seed_controller "$status_budget_home"
assert_rc 'status reports the next gate and the singleton budget' 0 bash -c '
  source "$1"
  export GDC_HOME="$2"
  recovery_main status --host x --run-id status-budget-run --manifest "$3"
  receipt="$GDC_HOME/runs/status-budget-run/recovery/x/status/attempt-1/receipt.json"
  recovery_validate_json_schema "$(recovery_receipt_schema)" "$receipt"
  jq -e ".details.status.missing_gate == \"inspect\"
    and .details.singleton_budget.first_counted_height == 100
    and .details.singleton_budget.remaining_blocks == 1000
    and .details.status.remaining_blocks == 1000
    and .details.singleton_budget.expired == false" "$receipt" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$status_budget_home" "$status_budget_manifest"

# C1: a retired identity can never be the transition key/valoper.
transition_key_in_retired="$TMP/transition-key-in-retired.json"
jq '.retirement.retired_identities[0].consensus_keys[0].public_key = .transition.new_transition_consensus.public_key' \
  "$status_manifest" >"$transition_key_in_retired"
chmod 600 "$transition_key_in_retired"
assert_rc 'admission refuses a retired identity carrying the transition key' 1 \
  recovery_validate_manifest "$transition_key_in_retired" x status

transition_valoper_in_retired="$TMP/transition-valoper-in-retired.json"
jq '.retirement.retired_identities[0].valoper_address = .transition.valoper_address' \
  "$status_manifest" >"$transition_valoper_in_retired"
chmod 600 "$transition_valoper_in_retired"
assert_rc 'admission refuses a retired identity carrying the transition valoper' 1 \
  recovery_validate_manifest "$transition_valoper_in_retired" x status

# C1: a retired identity can never be a host already bound to the return cohort.
cohort_conflict_manifest="$TMP/cohort-conflict.json"
jq '
  .hosts.bindings += [{
    host: "y", roles: ["returning"], return_position: 1,
    source_signer_mode: "local_file_pv", recovery_signer_mode: "none",
    participant: {participant_address: "gonka1yyyyyyyyyyyy", account_address: "gonka1yyyyyyyyyyyy",
      valoper_address: "gonka1yyyyyyyyyyyy",
      consensus: {key_id: "y", algorithm: "cometbft/PubKeyEd25519", public_key: "AA==",
        public_key_sha256: ("0" * 64), consensus_address: ("1" * 40)}},
    signer_handoff_predicates: {native_state_present: true, binding_verified: true,
      duplicate_absent: true, conflicting_lab_history_absent: true},
    approved_services: []
  }]
  | .retirement.retired_identities[0].account_address = "gonka1yyyyyyyyyyyy"
' "$status_manifest" >"$cohort_conflict_manifest"
chmod 600 "$cohort_conflict_manifest"
assert_rc 'admission refuses a retired identity that is a return-cohort host' 1 \
  recovery_validate_manifest "$cohort_conflict_manifest" x status

# C2: the transition host can never be a returning host or approved for API/ML.
transition_in_cohort_manifest="$TMP/transition-in-cohort.json"
jq '.hosts.return_order += [.transition.host]' "$status_manifest" >"$transition_in_cohort_manifest"
chmod 600 "$transition_in_cohort_manifest"
assert_rc 'admission refuses when the transition host is also a returning host' 1 \
  recovery_validate_manifest "$transition_in_cohort_manifest" x status

transition_ml_manifest="$TMP/transition-ml-approved.json"
jq '(.transition.host) as $th | (.hosts.bindings[] | select(.host == $th) | .approved_services) |= (. + ["ml"])' \
  "$status_manifest" >"$transition_ml_manifest"
chmod 600 "$transition_ml_manifest"
assert_rc 'admission refuses when the transition host is approved for ML' 1 \
  recovery_validate_manifest "$transition_ml_manifest" x status

# A qualified RETIRED receipt (case A, transition key retained, full
# exclusion coverage) genuinely unlocks rejoin/resume poc.
retire_manifest_sha="$(recovery_sha256 "$status_manifest")"
retire_good_root="$TMP/retire-gate-good"
mkdir -p "$retire_good_root/runs/retire-gate-run/recovery/x/retire/attempt-1"
retire_good_receipt="$retire_good_root/runs/retire-gate-run/recovery/x/retire/attempt-1/receipt.json"
jq --arg manifest "$retire_manifest_sha" '
  .receipt_type = "phase" | del(.terminal) | .receipt_id = "retire-good"
  | .run_id = "retire-gate-run" | .attempt_id = "retire-good" | .attempt_number = 1 | .sequence = 1
  | .host = "x" | .phase = "retire" | .manifest_binding_kind = "final_manifest" | .manifest_sha256 = $manifest
  | .command.selector = "retire" | .verdict = "PASS" | .exit_status = 0
  | .details = {state: "RETIRED", reason_code: "retirement_complete", message: "retirement complete",
      retirement: {boundary_case: "A", boundary_evidence_sha256: ("0" * 64), proposal_id: 1,
        submit_tx_hash: ("a" * 64), vote_tx_hashes: [("b" * 64)], execution_height: 2,
        proposal_status: "PROPOSAL_STATUS_PASSED", complete_parameter_readback_sha256: ("c" * 64),
        only_approved_parameter_changed: true,
        excluded_paths: ["poc_submission", "preserved", "fallback", "delegated"],
        future_exclusion_verified: true,
        retired_addresses_in_blocklist: true, transition_key_retained: true}}
' "$inspect_output" >"$retire_good_receipt"
chmod 400 "$retire_good_receipt"
assert_rc 'a qualified RETIRED receipt (case A) unlocks rejoin/resume poc' 0 bash -c '
  source "$1"
  export GDC_HOME="$2" RECOVERY_RUN_ID=retire-gate-run RECOVERY_HOST=x RECOVERY_MANIFEST="$3"
  recovery_require_predecessor retire x "$4" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$retire_good_root" "$status_manifest" "$retire_manifest_sha"

# Case B is admitted only when the manifest's own policy allows it.
case_b_manifest="$TMP/case-b-admitted-manifest.json"
jq '.first_boundary_policy.admitted_cases = ["A", "B"]' "$status_manifest" >"$case_b_manifest"
chmod 600 "$case_b_manifest"
retire_case_b_root="$TMP/retire-gate-case-b"
mkdir -p "$retire_case_b_root/runs/retire-gate-run/recovery/x/retire/attempt-1"
jq '.details.retirement.boundary_case = "B"' "$retire_good_receipt" \
  >"$retire_case_b_root/runs/retire-gate-run/recovery/x/retire/attempt-1/receipt.json"
chmod 400 "$retire_case_b_root/runs/retire-gate-run/recovery/x/retire/attempt-1/receipt.json"
assert_rc 'case B unlocks rejoin/poc when the manifest admits it' 0 bash -c '
  source "$1"
  export GDC_HOME="$2" RECOVERY_RUN_ID=retire-gate-run RECOVERY_HOST=x RECOVERY_MANIFEST="$3"
  recovery_require_predecessor retire x "$4" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$retire_case_b_root" "$case_b_manifest" "$retire_manifest_sha"

# Each retirement gate defect independently blocks rejoin/resume poc.
for retire_defect in boundary_unexpected boundary_b_forbidden no_transition_key \
    no_preserved no_fallback no_retired_addresses; do
  defect_root="$TMP/retire-defect-$retire_defect"
  mkdir -p "$defect_root/runs/retire-gate-run/recovery/x/retire/attempt-1"
  defect_receipt="$defect_root/runs/retire-gate-run/recovery/x/retire/attempt-1/receipt.json"
  case "$retire_defect" in
    boundary_unexpected) jq '.details.retirement.boundary_case = "unexpected"' "$retire_good_receipt" >"$defect_receipt" ;;
    boundary_b_forbidden) jq '.details.retirement.boundary_case = "B"' "$retire_good_receipt" >"$defect_receipt" ;;
    no_transition_key) jq '.details.retirement.transition_key_retained = false' "$retire_good_receipt" >"$defect_receipt" ;;
    no_preserved) jq '.details.retirement.excluded_paths -= ["preserved"]' "$retire_good_receipt" >"$defect_receipt" ;;
    no_fallback) jq '.details.retirement.excluded_paths -= ["fallback"]' "$retire_good_receipt" >"$defect_receipt" ;;
    no_retired_addresses) jq '.details.retirement.retired_addresses_in_blocklist = false' "$retire_good_receipt" >"$defect_receipt" ;;
  esac
  chmod 400 "$defect_receipt"
  assert_rc "a RETIRED receipt with $retire_defect defect does not unlock rejoin/resume poc" 0 bash -c '
    source "$1"
    export GDC_HOME="$2" RECOVERY_RUN_ID=retire-gate-run RECOVERY_HOST=x RECOVERY_MANIFEST="$3"
    ! recovery_require_predecessor retire x "$4" >/dev/null
  ' _ "$HERE/scripts/lib-recovery.sh" "$defect_root" "$status_manifest" "$retire_manifest_sha"
done

# C2: resume handoff unlocks only once poc evidence shows the temporary key
# excluded and the remaining signers strictly above two-thirds power.
poc_good_root="$TMP/poc-gate-good"
mkdir -p "$poc_good_root/runs/poc-gate-run/recovery/y/resume/poc/attempt-1"
poc_good_receipt="$poc_good_root/runs/poc-gate-run/recovery/y/resume/poc/attempt-1/receipt.json"
jq --arg manifest "$retire_manifest_sha" '
  .receipt_type = "phase" | del(.terminal) | .receipt_id = "poc-good"
  | .run_id = "poc-gate-run" | .attempt_id = "poc-good" | .attempt_number = 1 | .sequence = 1
  | .host = "y" | .phase = "resume" | .step = "poc" | .manifest_binding_kind = "final_manifest" | .manifest_sha256 = $manifest
  | .command.selector = "resume_poc" | .verdict = "PASS" | .exit_status = 0
  | .details = {state: "POC_ACTIVE", reason_code: "poc_active", message: "poc active",
      resume: {step: "poc", resources_changed: [], signer_binding_sha256: ("0" * 64),
        duplicate_signer_absent: true, effective_height: 5, temporary_key_excluded: true,
        power: {height: 5, total_power: "135", available_power: "102",
          strict_required_power: "91", strictly_over_two_thirds: true}}}
' "$inspect_output" >"$poc_good_receipt"
chmod 400 "$poc_good_receipt"
assert_rc 'qualified poc evidence unlocks resume handoff' 0 bash -c '
  source "$1"
  export GDC_HOME="$2" RECOVERY_RUN_ID=poc-gate-run RECOVERY_HOST=y RECOVERY_MANIFEST="$3"
  recovery_require_predecessor resume y "$4" poc >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$poc_good_root" "$status_manifest" "$retire_manifest_sha"

for poc_defect in key_not_excluded not_over_two_thirds; do
  poc_defect_root="$TMP/poc-defect-$poc_defect"
  mkdir -p "$poc_defect_root/runs/poc-gate-run/recovery/y/resume/poc/attempt-1"
  poc_defect_receipt="$poc_defect_root/runs/poc-gate-run/recovery/y/resume/poc/attempt-1/receipt.json"
  case "$poc_defect" in
    key_not_excluded) jq '.details.resume.temporary_key_excluded = false' "$poc_good_receipt" >"$poc_defect_receipt" ;;
    not_over_two_thirds) jq '.details.resume.power.strictly_over_two_thirds = false' "$poc_good_receipt" >"$poc_defect_receipt" ;;
  esac
  chmod 400 "$poc_defect_receipt"
  assert_rc "poc evidence with $poc_defect defect does not unlock resume handoff" 0 bash -c '
    source "$1"
    export GDC_HOME="$2" RECOVERY_RUN_ID=poc-gate-run RECOVERY_HOST=y RECOVERY_MANIFEST="$3"
    ! recovery_require_predecessor resume y "$4" poc >/dev/null
  ' _ "$HERE/scripts/lib-recovery.sh" "$poc_defect_root" "$status_manifest" "$retire_manifest_sha"
done

# D: an expired singleton deadline blocks singleton-dependent phases
# (checkpoint needs no approval, so it isolates the gate cleanly).
expired_deadline_manifest="$TMP/expired-deadline-manifest.json"
jq '.singleton.singleton_deadline_utc = "2000-01-01T00:00:00Z"' "$status_manifest" >"$expired_deadline_manifest"
chmod 600 "$expired_deadline_manifest"
expired_deadline_home="$TMP/expired-deadline-home"; mkdir -m 700 "$expired_deadline_home"
seed_controller "$expired_deadline_home"
assert_rc 'an expired singleton deadline refuses checkpoint with singleton_expired' 0 bash -c '
  source "$1"
  export GDC_HOME="$2"
  ! recovery_main checkpoint --host x --run-id expired-deadline-run --manifest "$3" --output "$4"
  receipt="$GDC_HOME/runs/expired-deadline-run/recovery/x/checkpoint/attempt-1/receipt.json"
  recovery_validate_json_schema "$(recovery_receipt_schema)" "$receipt"
  jq -e ".verdict == \"REFUSED\" and .details.reason_code == \"singleton_expired\"" "$receipt" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$expired_deadline_home" "$expired_deadline_manifest" "$TMP/out/expired-deadline.json"

assert_rc 'status shows EXPIRED with a zero remaining deadline once it is spent' 0 bash -c '
  source "$1"
  export GDC_HOME="$2"
  recovery_main status --host x --run-id expired-deadline-run --manifest "$3"
  receipt="$GDC_HOME/runs/expired-deadline-run/recovery/x/status/attempt-1/receipt.json"
  recovery_validate_json_schema "$(recovery_receipt_schema)" "$receipt"
  jq -e ".details.status.operator_state == \"EXPIRED\" and .details.status.remaining_seconds == 0
    and .details.state == \"EXPIRED\"" "$receipt" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$expired_deadline_home" "$expired_deadline_manifest"

# An exceeded block budget refuses independently of the (still open) deadline.
block_budget_manifest="$TMP/block-budget-manifest.json"
jq '.singleton.singleton_deadline_utc = "2099-01-01T00:00:00Z"
    | .singleton.singleton_max_blocks = 5 | .singleton.first_counted_height = 100
    | .hosts.bindings += [(.hosts.bindings[0] | .host = "y" | .roles = ["returning"]
      | .return_position = 1 | .participant = null | .approved_services = [])]' \
  "$status_manifest" >"$block_budget_manifest"
chmod 600 "$block_budget_manifest"
block_budget_manifest_sha="$(recovery_sha256 "$block_budget_manifest")"
block_budget_home="$TMP/block-budget-home"
mkdir -p "$block_budget_home/runs/block-budget-run/recovery/x/activate/attempt-1"
seed_controller "$block_budget_home"
jq --arg manifest "$block_budget_manifest_sha" '
  .receipt_type = "phase" | del(.terminal) | .receipt_id = "activate-high"
  | .run_id = "block-budget-run" | .attempt_id = "activate-high" | .attempt_number = 1 | .sequence = 1
  | .host = "x" | .phase = "activate" | .manifest_binding_kind = "final_manifest" | .manifest_sha256 = $manifest
  | .command.selector = "activate" | .verdict = "PASS" | .exit_status = 0
  | .details = {state: "SINGLETON_ACTIVE", reason_code: "activated", message: "activated",
      activation: {initialization_attempted: true, initialization_count: 1, container_id: ("0" * 12),
        ownership_labels_sha256: ("0" * 64),
        first_commit: {height: 101, block_hash: ("1" * 64), application_hash: ("2" * 64), commit_sha256: ("3" * 64), verified: true},
        subsequent_commits: [{height: 200, block_hash: ("4" * 64), application_hash: ("5" * 64), commit_sha256: ("6" * 64), verified: true}],
        ordinary_restart_verified: true,
        native_signer_state: {mode: "transition_local_file_pv", height: 200, round: 0, step: 0,
          block_id: ("7" * 64), state_sha256: ("8" * 64), duplicate_absent: true}}}
' "$inspect_output" >"$block_budget_home/runs/block-budget-run/recovery/x/activate/attempt-1/receipt.json"
chmod 400 "$block_budget_home/runs/block-budget-run/recovery/x/activate/attempt-1/receipt.json"
assert_rc 'an exceeded block budget refuses checkpoint with singleton_expired' 0 bash -c '
  source "$1"
  export GDC_HOME="$2"
  ! recovery_main checkpoint --host x --run-id block-budget-run --manifest "$3" --output "$4"
  receipt="$GDC_HOME/runs/block-budget-run/recovery/x/checkpoint/attempt-1/receipt.json"
  recovery_validate_json_schema "$(recovery_receipt_schema)" "$receipt"
  jq -e ".verdict == \"REFUSED\" and .details.reason_code == \"singleton_expired\"" "$receipt" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$block_budget_home" "$block_budget_manifest" "$TMP/out/block-budget.json"

assert_rc 'status shows EXPIRED with a zero remaining block budget once it is spent' 0 bash -c '
  source "$1"
  export GDC_HOME="$2"
  recovery_main status --host x --run-id block-budget-run --manifest "$3"
  receipt="$GDC_HOME/runs/block-budget-run/recovery/x/status/attempt-1/receipt.json"
  recovery_validate_json_schema "$(recovery_receipt_schema)" "$receipt"
  jq -e ".details.status.operator_state == \"EXPIRED\" and .details.status.remaining_blocks == 0
    and .details.state == \"EXPIRED\"" "$receipt" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$block_budget_home" "$block_budget_manifest"

# The same run-wide budget must gate a returning host and its status.
assert_rc 'returning host cannot bypass transition block budget' 0 bash -c '
  source "$1"
  export GDC_HOME="$2" RECOVERY_RUN_ID=block-budget-run
  budget="$(recovery_singleton_budget "$3" y)"
  jq -e ".expired == true and .remaining_blocks == 0 and .current_height == 200" <<<"$budget" >/dev/null
  ! recovery_validate_singleton_budget "$3" y
  recovery_main status --host y --run-id block-budget-run --manifest "$3"
  jq -e ".details.status.operator_state == \"EXPIRED\"" "$GDC_HOME/runs/block-budget-run/recovery/y/status/attempt-1/receipt.json" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$block_budget_home" "$block_budget_manifest"

# An incomplete later attempt must not erase historical activation height.
mkdir -p "$block_budget_home/runs/block-budget-run/recovery/x/activate/attempt-2"
assert_rc 'incomplete activation retry cannot reset observed block budget' 0 bash -c '
  source "$1"; export GDC_HOME="$2" RECOVERY_RUN_ID=block-budget-run
  recovery_singleton_budget "$3" y | jq -e ".expired == true and .current_height == 200" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$block_budget_home" "$block_budget_manifest"

# Checkpoint artifacts contain the snapshot and supporting-header heights.
checkpoint_budget_home="$TMP/checkpoint-budget-home"
mkdir -p "$checkpoint_budget_home/runs/checkpoint-budget/recovery/x/checkpoint/attempt-1"
jq --arg manifest "$block_budget_manifest_sha" '
  .run_id = "checkpoint-budget" | .host = "x" | .manifest_sha256 = $manifest
  | .checkpoint.manifest_sha256 = $manifest | .checkpoint.snapshot_height = 110 | .checkpoint.trust_height = 110
  | .checkpoint.supporting_light_blocks |= map(.height += 100)
' "$checkpoint_fixture" >"$checkpoint_budget_home/runs/checkpoint-budget/recovery/x/checkpoint/attempt-1/checkpoint.json"
chmod 400 "$checkpoint_budget_home/runs/checkpoint-budget/recovery/x/checkpoint/attempt-1/checkpoint.json"
assert_rc 'checkpoint artifact advances budget for returning hosts' 0 bash -c '
  source "$1"; export GDC_HOME="$2" RECOVERY_RUN_ID=checkpoint-budget
  recovery_singleton_budget "$3" y | jq -e ".expired == true and .current_height == 112" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$checkpoint_budget_home" "$block_budget_manifest"

# Governance execution also consumes blocks, even without activation evidence.
retire_budget_home="$TMP/retire-budget-home"
mkdir -p "$retire_budget_home/runs/retire-budget/recovery/x/retire/attempt-1"
jq --arg manifest "$block_budget_manifest_sha" '
  .run_id = "retire-budget" | .manifest_sha256 = $manifest
  | .details.retirement.execution_height = 105
' "$retire_good_receipt" >"$retire_budget_home/runs/retire-budget/recovery/x/retire/attempt-1/receipt.json"
chmod 400 "$retire_budget_home/runs/retire-budget/recovery/x/retire/attempt-1/receipt.json"
assert_rc 'retirement execution advances budget for returning hosts' 0 bash -c '
  source "$1"; export GDC_HOME="$2" RECOVERY_RUN_ID=retire-budget
  recovery_singleton_budget "$3" y | jq -e ".expired == true and .current_height == 105" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$retire_budget_home" "$block_budget_manifest"

# Count the first block itself and expire exactly on the final allowed block.
for boundary in 99:5:false 100:4:false 103:1:false 104:0:true; do
  IFS=: read -r observed_height expected_remaining expected_expired <<<"$boundary"
  boundary_home="$TMP/boundary-$observed_height"
  mkdir -p "$boundary_home/runs/boundary/recovery/x/retire/attempt-1"
  jq --arg manifest "$block_budget_manifest_sha" --argjson height "$observed_height" '
    .run_id = "boundary" | .manifest_sha256 = $manifest | .details.retirement.execution_height = $height
  ' "$retire_good_receipt" >"$boundary_home/runs/boundary/recovery/x/retire/attempt-1/receipt.json"
  chmod 400 "$boundary_home/runs/boundary/recovery/x/retire/attempt-1/receipt.json"
  assert_rc "singleton first-counted boundary at $observed_height" 0 bash -c '
    source "$1"; export GDC_HOME="$2" RECOVERY_RUN_ID=boundary
    recovery_singleton_budget "$3" y | jq -e --argjson remaining "$4" --argjson expired "$5" \
      ".remaining_blocks == \$remaining and .expired == \$expired" >/dev/null
  ' _ "$HERE/scripts/lib-recovery.sh" "$boundary_home" "$block_budget_manifest" "$expected_remaining" "$expected_expired"
done

# A file at the expected path is not evidence for a different manifest/run/host.
for foreign in run_id host manifest_sha256; do
  foreign_home="$TMP/foreign-budget-$foreign"
  mkdir -p "$foreign_home/runs/foreign-budget/recovery/x/retire/attempt-1"
  jq --arg manifest "$block_budget_manifest_sha" --arg field "$foreign" '
    .run_id = "foreign-budget" | .manifest_sha256 = $manifest | .details.retirement.execution_height = 105
    | .[$field] = (if $field == "manifest_sha256" then ("f" * 64) else "foreign" end)
  ' "$retire_good_receipt" >"$foreign_home/runs/foreign-budget/recovery/x/retire/attempt-1/receipt.json"
  chmod 400 "$foreign_home/runs/foreign-budget/recovery/x/retire/attempt-1/receipt.json"
  assert_rc "foreign $foreign cannot change the singleton budget" 0 bash -c '
    source "$1"; export GDC_HOME="$2" RECOVERY_RUN_ID=foreign-budget
    recovery_singleton_budget "$3" y | jq -e ".expired == false and .remaining_blocks == 5" >/dev/null
  ' _ "$HERE/scripts/lib-recovery.sh" "$foreign_home" "$block_budget_manifest"
done

# Corrupt evidence cannot silently restore the full allowance or a ready state.
invalid_budget_home="$TMP/invalid-budget-home"
mkdir -p "$invalid_budget_home/runs/invalid-budget/recovery/x/retire/attempt-1"
seed_controller "$invalid_budget_home"
printf '{}\n' >"$invalid_budget_home/runs/invalid-budget/recovery/x/retire/attempt-1/receipt.json"
chmod 400 "$invalid_budget_home/runs/invalid-budget/recovery/x/retire/attempt-1/receipt.json"
assert_rc 'invalid budget evidence blocks mutation and makes status inconclusive' 0 bash -c '
  source "$1"; export GDC_HOME="$2" RECOVERY_RUN_ID=invalid-budget
  ! recovery_validate_singleton_budget "$3" y
  recovery_main status --host y --run-id invalid-budget --manifest "$3"
  jq -e ".details.status.operator_state == \"INCONCLUSIVE\" and .details.status.remaining_blocks == null" \
    "$GDC_HOME/runs/invalid-budget/recovery/y/status/attempt-1/receipt.json" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$invalid_budget_home" "$block_budget_manifest"

# D: activate refuses before the window opens unless a pre-rendered
# expiry-stop artifact is armed and matches this exact manifest deadline.
activate_no_stop_home="$TMP/activate-no-stop-home"; mkdir -m 700 "$activate_no_stop_home"
seed_controller "$activate_no_stop_home"
assert_rc 'activate refuses without an armed expiry-stop artifact' 0 bash -c '
  source "$1"
  export GDC_HOME="$2"
  ! recovery_main activate --host x --run-id activate-gate-run --manifest "$3" --approval "$4"
  receipt="$GDC_HOME/runs/activate-gate-run/recovery/x/activate/attempt-1/receipt.json"
  recovery_validate_json_schema "$(recovery_receipt_schema)" "$receipt"
  jq -e ".verdict == \"REFUSED\" and .details.reason_code == \"expiry_stop_not_armed\"" "$receipt" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$activate_no_stop_home" "$status_manifest" "$fixture"

assert_rc 'a rendered expiry-stop artifact is armed and matches the manifest deadline' 0 bash -c '
  source "$1"
  export GDC_HOME="$2" RECOVERY_RUN_ID=expiry-stop-run RECOVERY_HOST=x
  recovery_render_expiry_stop_artifact "$3"
  recovery_validate_expiry_stop_artifact "$3"
' _ "$HERE/scripts/lib-recovery.sh" "$TMP/expiry-stop-good-home" "$status_manifest"

# Extending the window is only possible through a new manifest (a new
# hash); the previously rendered artifact never matches it automatically.
extended_deadline_manifest="$TMP/extended-deadline-manifest.json"
jq '.singleton.singleton_deadline_utc = "2100-01-01T00:00:00Z"' "$status_manifest" >"$extended_deadline_manifest"
chmod 600 "$extended_deadline_manifest"
assert_rc 'extending the singleton deadline changes the manifest hash' 0 bash -c '
  [[ "$(sha256sum "$1" | awk "{print \$1}")" != "$(sha256sum "$2" | awk "{print \$1}")" ]]
' _ "$status_manifest" "$extended_deadline_manifest"
assert_rc 'a changed deadline after rendering is refused, never silently extended' 0 bash -c '
  source "$1"
  export GDC_HOME="$2" RECOVERY_RUN_ID=expiry-stop-run RECOVERY_HOST=x
  recovery_render_expiry_stop_artifact "$3"
  ! recovery_validate_expiry_stop_artifact "$4"
' _ "$HERE/scripts/lib-recovery.sh" "$TMP/expiry-stop-mismatch-home" "$status_manifest" "$extended_deadline_manifest"

## ---------------------------------------------------------------------
## E1: checkpoint single-source risk acceptance (retention mutation cases
## already added to the checkpoint_defect loop above).
## ---------------------------------------------------------------------
single_source_no_flag="$TMP/single-source-no-flag.json"
jq -n '{approval:{signed_payload:{}}}' >"$single_source_no_flag"
single_source_flag="$TMP/single-source-flag.json"
jq -n '{approval:{signed_payload:{single_source_risk_accepted:true}}}' >"$single_source_flag"
assert_rc 'single-source risk is refused for the first return host without acceptance' 1 \
  recovery_validate_single_source_acceptance "$status_manifest" "$single_source_no_flag" y
assert_rc 'single-source risk is accepted via an explicit approval flag' 0 \
  recovery_validate_single_source_acceptance "$status_manifest" "$single_source_flag" y
manifest_with_lab_trail="$TMP/manifest-with-lab-trail.json"
jq '.trust.lab_qualification_receipts = [{artifact_id:"lab-1",kind:"qualification_receipt",sha256:("0"*64),location:"/e/lab-1.json"}]
  | .trust.review_receipts = [{artifact_id:"review-1",kind:"review_receipt",sha256:("0"*64),location:"/e/review-1.json"}]' \
  "$status_manifest" >"$manifest_with_lab_trail"
assert_rc 'single-source risk is accepted via the manifest lab/review trail' 0 \
  recovery_validate_single_source_acceptance "$manifest_with_lab_trail" "$single_source_no_flag" y
assert_rc 'single-source acceptance is only checked for the first return host' 0 \
  recovery_validate_single_source_acceptance "$status_manifest" "$single_source_no_flag" not-the-first-host

## ---------------------------------------------------------------------
## E2: rejoin state-sync evidence and the resume --step signers gate.
## ---------------------------------------------------------------------
export RECOVERY_CHECKPOINT="$checkpoint_fixture"
e2_checkpoint_sha="$(recovery_sha256 "$checkpoint_fixture")"
e2_trust_height="$(jq -r '.checkpoint.trust_height' "$checkpoint_fixture")"
e2_light_block_hash="$(jq -r --argjson h "$e2_trust_height" '.checkpoint.supporting_light_blocks[] | select(.height == $h) | .block_hash' "$checkpoint_fixture")"
good_state_sync_details="$(jq -cn --arg csha "$e2_checkpoint_sha" --argjson th "$e2_trust_height" --arg hash "$e2_light_block_hash" '
  {state_sync:{checkpoint_receipt_sha256:$csha,source_mode:"single-transition-source",source_node_ids:[("0"*40)],
    restored_snapshot_height:$th,caught_up:true,common_height:$th,common_block_hash:$hash,
    common_application_hash:("1"*64),retirement_readback_sha256:("2"*64),fork_replacement_marker_found:false}}')"
assert_rc 'rejoin state-sync evidence matching the checkpoint is accepted' 0 \
  recovery_validate_rejoin_state_sync_evidence "$good_state_sync_details"
for rejoin_defect in restored_height_below_trust common_hash_mismatch fork_marker_found foreign_checkpoint; do
  case "$rejoin_defect" in
    restored_height_below_trust) bad_details="$(jq -c '.state_sync.restored_snapshot_height -= 1' <<<"$good_state_sync_details")" ;;
    common_hash_mismatch) bad_details="$(jq -c '.state_sync.common_block_hash = ("9" * 64)' <<<"$good_state_sync_details")" ;;
    fork_marker_found) bad_details="$(jq -c '.state_sync.fork_replacement_marker_found = true' <<<"$good_state_sync_details")" ;;
    foreign_checkpoint) bad_details="$(jq -c '.state_sync.checkpoint_receipt_sha256 = ("9" * 64)' <<<"$good_state_sync_details")" ;;
  esac
  assert_rc "rejoin state-sync evidence with $rejoin_defect is refused" 1 \
    recovery_validate_rejoin_state_sync_evidence "$bad_details"
done
unset RECOVERY_CHECKPOINT

resume_signers_home="$TMP/resume-signers-home"; mkdir -m 700 "$resume_signers_home"
resume_signers_transition_host="$(jq -r '.transition.host' "$status_manifest")"
resume_signers_retire_dir="$resume_signers_home/runs/resume-signers-run/recovery/$resume_signers_transition_host/retire/attempt-1"
mkdir -p "$resume_signers_retire_dir"
resume_signers_manifest_sha="$(recovery_sha256 "$status_manifest")"
jq --arg manifest "$resume_signers_manifest_sha" --arg host "$resume_signers_transition_host" '
  .receipt_type = "phase" | del(.terminal) | .receipt_id = "retire-1" | .run_id = "resume-signers-run"
  | .attempt_id = "retire-1" | .attempt_number = 1 | .sequence = 1 | .host = $host | .phase = "retire"
  | .manifest_binding_kind = "final_manifest" | .manifest_sha256 = $manifest | .command.selector = "retire"
  | .verdict = "PASS" | .exit_status = 0
  | .details = {state:"RETIRED",reason_code:"retired",message:"retired",
      retirement:{boundary_case:"A",boundary_evidence_sha256:("0" * 64),proposal_id:1,submit_tx_hash:("0" * 64),
        vote_tx_hashes:[("0" * 64)],execution_height:500,proposal_status:"PROPOSAL_STATUS_PASSED",
        complete_parameter_readback_sha256:("0" * 64),only_approved_parameter_changed:true,
        excluded_paths:["current","upcoming","preserved","fallback","delegated","warm","poc_submission"],
        future_exclusion_verified:true,retired_addresses_in_blocklist:true,transition_key_retained:true}}
' "$inspect_output" >"$resume_signers_retire_dir/receipt.json"
chmod 400 "$resume_signers_retire_dir/receipt.json"
resume_signers_addrs="$(jq -c '.retirement.retired_identities[0] | [.participant_address, .account_address, .valoper_address]' "$status_manifest")"
good_resume_signers_details="$(jq -cn --argjson addrs "$resume_signers_addrs" '
  {resume:{step:"signers",resources_changed:["tmkms"],signer_binding_sha256:("0" * 64),duplicate_signer_absent:true,
    power:{height:1,total_power:"1",available_power:"1",strict_required_power:"1",strictly_over_two_thirds:true},
    local_state_height:600,blocked_participant_addresses:$addrs}}')"
for resume_signers_case in good local_state_too_low missing_retired_address; do
  case "$resume_signers_case" in
    good) resume_signers_details="$good_resume_signers_details"; resume_signers_want=0 ;;
    local_state_too_low) resume_signers_details="$(jq -c '.resume.local_state_height = 100' <<<"$good_resume_signers_details")"; resume_signers_want=1 ;;
    missing_retired_address) resume_signers_details="$(jq -c '.resume.blocked_participant_addresses = ["gonka1" + ("q" * 12)]' <<<"$good_resume_signers_details")"; resume_signers_want=1 ;;
  esac
  assert_rc "resume signers evidence ($resume_signers_case) matches the expected verdict" "$resume_signers_want" bash -c '
    source "$1"
    export GDC_HOME="$2" RECOVERY_RUN_ID=resume-signers-run RECOVERY_HOST=y RECOVERY_PHASE=resume RECOVERY_STEP=signers
    RECOVERY_MANIFEST="$3" RECOVERY_MANIFEST_SHA256="$4"
    recovery_validate_resume_signers_evidence "$5"
  ' _ "$HERE/scripts/lib-recovery.sh" "$resume_signers_home" "$status_manifest" "$resume_signers_manifest_sha" "$resume_signers_details"
done

## ---------------------------------------------------------------------
## E3: handler registry qualification and isolated-lab execution.
## ---------------------------------------------------------------------
lab_manifest="$TMP/lab-manifest.json"
jq '.execution.scope = "isolated_lab" | .execution.lab_hosts = ["x"]' "$status_manifest" >"$lab_manifest"
chmod 600 "$lab_manifest"
lab_home="$TMP/lab-handler-home"; mkdir -m 700 "$lab_home"
seed_controller "$lab_home"
lab_manifest_sha="$(recovery_sha256 "$lab_manifest")"
lab_approval="$TMP/lab-approval.json"
jq -n --arg manifest "$lab_manifest_sha" '{receipt_type:"approval",run_id:"lab-run",host:"x",
  approval:{signed_payload:{namespace:"gdc-network-recovery-v1",action:"lab_execution",subject_kind:"final_manifest",
    subject_sha256:$manifest,run_id:"lab-run",host:"x",
    not_before:"2000-01-01T00:00:00Z",expires_at:"2999-01-01T00:00:00Z"}}}' >"$lab_approval"
chmod 600 "$lab_approval"
assert_rc 'lab runs a fake registered handler when unqualified' 0 bash -c '
  source "$1"
  recovery_require_private_file() { return 0; }
  recovery_validate_json_schema() { return 0; }
  recovery_verify_approval_signature() { return 0; }
  recovery_test_lab_handler() { jq -n "{verdict:\"PASS\",mutation_state:\"none\",reason:\"lab_ok\",details:{}}" >"$1/phase-result.json"; }
  recovery_register_handler freeze recovery_test_lab_handler
  export GDC_HOME="$2" RECOVERY_RUN_ID=lab-run RECOVERY_HOST=x RECOVERY_PHASE=freeze RECOVERY_STEP="" RECOVERY_SCOPE=""
  export GDC_RECOVERY_REHEARSAL_AUTHORIZED=true GDC_RECOVERY_REHEARSAL_SCOPE=isolated-lab GDC_RECOVERY_LAB_APPROVAL="$4"
  RECOVERY_MANIFEST="$3" RECOVERY_MANIFEST_SHA256="$(recovery_sha256 "$3")" RECOVERY_PREDECESSOR_RECEIPTS="[]"
  recovery_next_attempt "$GDC_HOME/runs/lab-run/recovery/x/freeze"
  RECOVERY_STARTED_AT="2026-09-13T00:00:00Z"
  recovery_record_command --host x --run-id lab-run
  recovery_run_registered_handler
  jq -e ".verdict == \"PASS\"" "$RECOVERY_ATTEMPT_DIR/receipt.json" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$lab_home" "$lab_manifest" "$lab_approval"

combat_home="$TMP/combat-no-record-home"; mkdir -m 700 "$combat_home"
seed_controller "$combat_home"
assert_rc 'combat without a qualification record is refused handler_not_qualified' 0 bash -c '
  source "$1"
  recovery_test_combat_handler() { jq -n "{verdict:\"PASS\",mutation_state:\"none\",reason:\"ok\",details:{}}" >"$1/phase-result.json"; }
  recovery_register_handler freeze recovery_test_combat_handler
  export GDC_HOME="$2" RECOVERY_RUN_ID=combat-run RECOVERY_HOST=x RECOVERY_PHASE=freeze RECOVERY_STEP="" RECOVERY_SCOPE=""
  RECOVERY_MANIFEST="$3" RECOVERY_MANIFEST_SHA256="$(recovery_sha256 "$3")" RECOVERY_PREDECESSOR_RECEIPTS="[]"
  recovery_next_attempt "$GDC_HOME/runs/combat-run/recovery/x/freeze"
  RECOVERY_STARTED_AT="2026-09-13T00:00:00Z"
  recovery_record_command --host x --run-id combat-run
  set +e; recovery_run_registered_handler; rc=$?; set -e
  [[ "$rc" -eq 3 ]]
  jq -e ".verdict == \"REFUSED\" and .details.reason_code == \"handler_not_qualified\"" "$RECOVERY_ATTEMPT_DIR/receipt.json" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$combat_home" "$status_manifest"

tamper_home="$TMP/combat-tampered-home"; mkdir -m 700 "$tamper_home"
seed_controller "$tamper_home"
assert_rc 'combat with a tampered handler hash is refused handler_not_qualified' 0 bash -c '
  source "$1"; source "$4"
  recovery_test_tampered_handler() { jq -n "{verdict:\"PASS\",mutation_state:\"none\",reason:\"ok\",details:{}}" >"$1/phase-result.json"; }
  qualify_test_handler freeze recovery_test_tampered_handler
  jq "(.[] | select(.selector == \"freeze\" and .handler == \"recovery_test_tampered_handler\") | .handler_code_sha256) |= (\"f\" * 64)" \
    "$RECOVERY_QUALIFICATION_FILE" >"$RECOVERY_QUALIFICATION_FILE.tmp"
  mv "$RECOVERY_QUALIFICATION_FILE.tmp" "$RECOVERY_QUALIFICATION_FILE"
  recovery_register_handler freeze recovery_test_tampered_handler
  export GDC_HOME="$2" RECOVERY_RUN_ID=tamper-run RECOVERY_HOST=x RECOVERY_PHASE=freeze RECOVERY_STEP="" RECOVERY_SCOPE=""
  RECOVERY_MANIFEST="$3" RECOVERY_MANIFEST_SHA256="$(recovery_sha256 "$3")" RECOVERY_PREDECESSOR_RECEIPTS="[]"
  recovery_next_attempt "$GDC_HOME/runs/tamper-run/recovery/x/freeze"
  RECOVERY_STARTED_AT="2026-09-13T00:00:00Z"
  recovery_record_command --host x --run-id tamper-run
  set +e; recovery_run_registered_handler; rc=$?; set -e
  [[ "$rc" -eq 3 ]]
  jq -e ".verdict == \"REFUSED\" and .details.reason_code == \"handler_not_qualified\"" "$RECOVERY_ATTEMPT_DIR/receipt.json" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$tamper_home" "$status_manifest" "$qual_helper"

qualified_combat_home="$TMP/combat-qualified-home"; mkdir -m 700 "$qualified_combat_home"
seed_controller "$qualified_combat_home"
assert_rc 'combat with a valid signed qualification record is allowed' 0 bash -c '
  source "$1"; source "$4"
  recovery_test_qualified_handler() { jq -n "{verdict:\"PASS\",mutation_state:\"none\",reason:\"ok\",details:{}}" >"$1/phase-result.json"; }
  qualify_test_handler freeze recovery_test_qualified_handler
  recovery_register_handler freeze recovery_test_qualified_handler
  export GDC_HOME="$2" RECOVERY_RUN_ID=qualified-run RECOVERY_HOST=x RECOVERY_PHASE=freeze RECOVERY_STEP="" RECOVERY_SCOPE=""
  RECOVERY_MANIFEST="$3" RECOVERY_MANIFEST_SHA256="$(recovery_sha256 "$3")" RECOVERY_PREDECESSOR_RECEIPTS="[]"
  recovery_next_attempt "$GDC_HOME/runs/qualified-run/recovery/x/freeze"
  RECOVERY_STARTED_AT="2026-09-13T00:00:00Z"
  recovery_record_command --host x --run-id qualified-run
  recovery_run_registered_handler
  jq -e ".verdict == \"PASS\"" "$RECOVERY_ATTEMPT_DIR/receipt.json" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$qualified_combat_home" "$status_manifest" "$qual_helper"

supervised_home="$TMP/supervised-wrong-phase-home"; mkdir -m 700 "$supervised_home"
seed_controller "$supervised_home"
assert_rc 'supervised_live qualification for another phase is refused' 0 bash -c '
  source "$1"
  recovery_test_supervised_handler() { jq -n "{verdict:\"PASS\",mutation_state:\"none\",reason:\"ok\",details:{}}" >"$1/phase-result.json"; }
  code_sha="$(declare -f recovery_test_supervised_handler | sha256sum | awk "{print tolower(\$1)}")"
  jq --arg sha "$code_sha" ". + [{selector:\"freeze\",handler:\"recovery_test_supervised_handler\",handler_code_sha256:\$sha,
    evidence_sha256:(\"0\" * 64),mode:\"supervised_live\",key_id:\"test-qual-key\",
    signature:\"-----BEGIN SSH SIGNATURE-----\nAAAA\n-----END SSH SIGNATURE-----\n\"}]" \
    "$RECOVERY_QUALIFICATION_FILE" >"$RECOVERY_QUALIFICATION_FILE.tmp"
  mv "$RECOVERY_QUALIFICATION_FILE.tmp" "$RECOVERY_QUALIFICATION_FILE"
  recovery_register_handler freeze recovery_test_supervised_handler
  export GDC_HOME="$2" RECOVERY_RUN_ID=supervised-run RECOVERY_HOST=x RECOVERY_PHASE=freeze RECOVERY_STEP="" RECOVERY_SCOPE=""
  RECOVERY_MANIFEST="$3" RECOVERY_MANIFEST_SHA256="$(recovery_sha256 "$3")" RECOVERY_PREDECESSOR_RECEIPTS="[]"
  recovery_next_attempt "$GDC_HOME/runs/supervised-run/recovery/x/freeze"
  RECOVERY_STARTED_AT="2026-09-13T00:00:00Z"
  recovery_record_command --host x --run-id supervised-run
  set +e; recovery_run_registered_handler; rc=$?; set -e
  [[ "$rc" -eq 3 ]]
  jq -e ".verdict == \"REFUSED\" and .details.reason_code == \"handler_not_qualified\"" "$RECOVERY_ATTEMPT_DIR/receipt.json" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$supervised_home" "$status_manifest"

## ---------------------------------------------------------------------
## E4: coordinator identity.
## ---------------------------------------------------------------------
controller_id_home="$TMP/controller-id-home"; mkdir -m 700 "$controller_id_home"
controller_inspect_out="$TMP/out/controller-inspect.json"
assert_rc 'inspect creates a mode-0600 coordinator identity and records its hash' 0 bash -c '
  source "$1"
  export GDC_HOME="$2" RECOVERY_TEST_SSH_FIXTURE="$3"
  export RECOVERY_FIXTURE_HEIGHT1=100 RECOVERY_FIXTURE_HEIGHT2=100 RECOVERY_FIXTURE_ARCHIVE_OK=1
  export RECOVERY_FIXTURE_VALIDATORS_H1="aaaa1:34,aaaa2:34,aaaa3:34,aaaa4:33" RECOVERY_FIXTURE_SIGNER_ADDRS=aaaa1
  export RECOVERY_FIXTURE_STATE_FILE="$4"
  recovery_main inspect --incident GNK-LAB-2026-0001 --host x --run-id controller-run --output "$5"
  [[ "$(recovery_file_mode "$2/recovery-controller-id")" == 600 ]]
  local_sha="$(recovery_sha256 "$2/recovery-controller-id")"
  jq -e --arg sha "$local_sha" ".details.inspection.controller_sha256 == \$sha" "$5" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$controller_id_home" "$ssh_fixture" "$TMP/controller-status-count" "$controller_inspect_out"

mismatched_controller_home="$TMP/mismatched-controller-home"; mkdir -m 700 "$mismatched_controller_home"
printf 'a-different-machine' >"$mismatched_controller_home/recovery-controller-id"
chmod 600 "$mismatched_controller_home/recovery-controller-id"
assert_rc 'a phase after prepare refuses controller_mismatch on a different machine' 0 bash -c '
  source "$1"
  export GDC_HOME="$2"
  ! recovery_main status --host x --run-id controller-mismatch-run --manifest "$3"
  receipt="$GDC_HOME/runs/controller-mismatch-run/recovery/x/status/attempt-1/receipt.json"
  jq -e ".verdict == \"REFUSED\" and .details.reason_code == \"controller_mismatch\"" "$receipt" >/dev/null
' _ "$HERE/scripts/lib-recovery.sh" "$mismatched_controller_home" "$status_manifest"

## ---------------------------------------------------------------------
## E5: binary_sha256 targets inferenced, and the HF-01 signer-control matrix.
## ---------------------------------------------------------------------
assert_rc 'binary_sha256 catalog command resolves inferenced, not PID 1' 0 bash -c '
  source "$1"
  cmd="$(recovery_remote_catalog_command binary_sha256 x)"
  [[ "$cmd" == *"command -v inferenced"* && "$cmd" != *"/proc/1/exe"* && "$cmd" != *readlink* ]]
' _ "$HERE/scripts/lib-recovery.sh"

unclassified_matrix_manifest="$TMP/unclassified-matrix-manifest.json"
jq '.validator_sets.next.validators += [(.validator_sets.next.validators[0]
    | .valoper_address = "gonka1val900001qqqqq" | .participant_address = "gonka1val900001qqqqq"
    | .consensus.consensus_address = "gonkavalcons1cns900001qqqqq")]' \
  "$status_manifest" >"$unclassified_matrix_manifest"
assert_rc 'an unclassified H+1 validator blocks admission (incomplete evidence)' 1 \
  recovery_validate_manifest "$unclassified_matrix_manifest" x status

controlled_recoverable_manifest="$TMP/controlled-recoverable-manifest.json"
jq '.validator_sets.signer_control_matrix[0] = {valoper_address: .validator_sets.next.validators[0].valoper_address,
    classification: "controlled", host: "x"}' \
  "$status_manifest" >"$controlled_recoverable_manifest"
assert_rc 'a controlled validator that did not sign H makes the quorum recoverable, refusing admission' 1 \
  recovery_validate_manifest "$controlled_recoverable_manifest" x status

incident_matrix_manifest="$TMP/incident-matrix-manifest.json"
python3 - "$status_manifest" "$incident_matrix_manifest" <<'PYEOF'
import json, sys

# Base-9 digits only (bech32 excludes 1/b/i/o); a fixed-width positional
# encoding, unlike a naive decimal-then-replace scheme, cannot collide.
DIGITS = "023456789"
def encode(i, width=6):
    s = ""
    for _ in range(width):
        i, r = divmod(i, 9)
        s = DIGITS[r] + s
    return s

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
groups = [(54, "lost"), (54, "controlled"), (27, "controlled")]
validators = []
matrix = []
idx = 0
for count, classification in groups:
    for _ in range(count):
        suffix = encode(idx)
        valoper = f"gonka1val{suffix}qqqqq"
        consensus_addr = f"gonkavalcons1cns{suffix}qqqqq"
        validators.append({
            "valoper_address": valoper, "participant_address": valoper,
            "consensus": {"key_id": f"key-{idx}", "algorithm": "ed25519", "public_key": "AA==",
                          "public_key_sha256": "0" * 64, "consensus_address": consensus_addr},
            "voting_power": "1", "available_signer": True,
        })
        entry = {"valoper_address": valoper, "classification": classification}
        if classification == "controlled":
            entry["host"] = "x"
        else:
            entry["evidence_ref"] = {"artifact_id": f"lost-{idx}", "kind": "qualification_receipt",
                                      "sha256": "0" * 64, "location": "/e/lost.json"}
        matrix.append(entry)
        idx += 1
manifest["validator_sets"]["next"]["validators"] = validators
manifest["validator_sets"]["signer_control_matrix"] = matrix
# No commit-H signer overlaps any H+1 validator: available power is exactly
# the 81 controlled, below the 91-of-135 strict threshold.
manifest["chain"]["commit_h"]["signatures"] = [{
    "block_id_flag": 1, "validator_address": "9" * 40,
    "timestamp": "2026-09-13T00:00:00Z", "signature": "AA==",
}]
json.dump(manifest, open(sys.argv[2], "w", encoding="utf-8"))
PYEOF
chmod 600 "$incident_matrix_manifest"
assert_rc 'the incident scenario (54 lost, 54+27 controlled, threshold 91) is not recoverable' 0 \
  recovery_validate_manifest "$incident_matrix_manifest" x status

exit "$fail"
