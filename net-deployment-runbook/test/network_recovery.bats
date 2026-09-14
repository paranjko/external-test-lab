#!/usr/bin/env bats

setup() {
  RUNBOOK="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$BATS_TEST_TMPDIR/recovery"
  mkdir -p "$TMP/bin" "$TMP/out"
  chmod 700 "$TMP" "$TMP/bin" "$TMP/out"
  cat >"$TMP/bin/realpath" <<'EOF'
#!/usr/bin/env python3
import os,sys
a=sys.argv[1:]
if a and a[0] in ('-e','-m'): a.pop(0)
if a and a[0] == '--': a.pop(0)
print(os.path.realpath(a[0]))
EOF
  chmod 700 "$TMP/bin/realpath"
  export PATH="$TMP/bin:$PATH"
  LIB="$RUNBOOK/scripts/lib-recovery.sh"
}

@test "CLI rejects missing, duplicate, unknown, and relative options" {
  run bash -c 'source "$1"; recovery_parse_args inspect --incident GNK-LAB-2026-0001 --incident x' _ "$LIB"
  [ "$status" -eq 2 ]
  run bash -c 'source "$1"; recovery_parse_args inspect --incident' _ "$LIB"
  [ "$status" -eq 2 ]
  run bash -c 'source "$1"; recovery_parse_args inspect --wat x' _ "$LIB"
  [ "$status" -eq 2 ]
  run bash -c 'source "$1"; recovery_canonical_input_file relative.json' _ "$LIB"
  [ "$status" -eq 1 ]
}

@test "symlink and traversal paths are refused" {
  printf '{}' >"$TMP/input.json"; chmod 600 "$TMP/input.json"
  ln -s "$TMP/input.json" "$TMP/link.json"
  run bash -c 'source "$1"; recovery_canonical_input_file "$2"' _ "$LIB" "$TMP/link.json"
  [ "$status" -eq 1 ]
  run bash -c 'source "$1"; recovery_canonical_output_path "$2"' _ "$LIB" "$TMP/out/../escape.json"
  [ "$status" -eq 1 ]
}

@test "receipt schema is strict and unknown fields are refused" {
  printf '{}' >"$TMP/bad.json"; chmod 600 "$TMP/bad.json"
  run bash -c 'source "$1"; recovery_validate_json_schema "$2" "$3"' _ "$LIB" "$RUNBOOK/schemas/recovery-receipt-v1.schema.json" "$TMP/bad.json"
  [ "$status" -ne 0 ]
}

@test "approval, predecessor, and unregistered activation fail closed without valid evidence" {
  run bash -c 'source "$1"; recovery_validate_approval "$2"' _ "$LIB" "$TMP/missing-approval.json"
  [ "$status" -ne 0 ]
  run bash -c 'source "$1"; RECOVERY_RUN_ID=run; RECOVERY_HOST=node1; recovery_require_predecessor activate' _ "$LIB"
  [ "$status" -ne 0 ]
  run bash -c 'source "$1"; recovery_register_handler activate recovery_activate' _ "$LIB"
  [ "$status" -ne 0 ]
}

@test "attempts are append-only and incomplete retries are refused" {
  run bash -c 'source "$1"; RECOVERY_RUN_ID=run; RECOVERY_HOST=node1; RECOVERY_PHASE=activate; recovery_next_attempt "$2"; printf x >"$RECOVERY_ATTEMPT_DIR/command.json"; chmod 600 "$RECOVERY_ATTEMPT_DIR/command.json"; recovery_next_attempt "$2"; [[ "$RECOVERY_PRIOR_ATTEMPT_INCOMPLETE" == true ]] && recovery_is_mutating_phase activate' _ "$LIB" "$TMP/attempts"
  [ "$status" -eq 0 ]
  [ -d "$TMP/attempts/attempt-1" ]
  [ -d "$TMP/attempts/attempt-2" ]
}

@test "manifest role binding and malformed or foreign approvals are refused" {
  printf '{}' >"$TMP/manifest.json"; chmod 600 "$TMP/manifest.json"
  printf '{}' >"$TMP/approval.json"; chmod 600 "$TMP/approval.json"
  run bash -c 'source "$1"; RECOVERY_RUN_ID=run; RECOVERY_HOST=node1; RECOVERY_PHASE=activate; RECOVERY_MANIFEST_SHA256=deadbeef; recovery_validate_approval "$2"' _ "$LIB" "$TMP/approval.json"
  [ "$status" -ne 0 ]
  run bash -c 'source "$1"; recovery_validate_manifest "$2" node2 activate' _ "$LIB" "$TMP/manifest.json"
  [ "$status" -ne 0 ]
}

@test "recovery sources contain no remote or container side effects outside the reviewed catalog" {
  [ "$(grep -c 'RECOVERY REMOTE COMMAND CATALOG BEGIN' "$RUNBOOK/scripts/lib-recovery.sh")" -eq 1 ]
  [ "$(grep -c 'RECOVERY REMOTE COMMAND CATALOG END' "$RUNBOOK/scripts/lib-recovery.sh")" -eq 1 ]
  ! sed '/RECOVERY REMOTE COMMAND CATALOG BEGIN/,/RECOVERY REMOTE COMMAND CATALOG END/d' \
      "$RUNBOOK/scripts/lib-recovery.sh" "$RUNBOOK/scripts/phase-network-recover.sh" \
    | grep -Eq '(^|[[:space:]])(ssh|scp|rsync|docker|podman|curl|nc|inferenced)([[:space:]]|$)'
}
