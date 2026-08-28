#!/usr/bin/env bats

setup() {
  RUNBOOK="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "canonical CLI exposes public Gate B and independent Host upgrade paths" {
  run grep -F './gdc.sh --release v2026.07.23 network gate-b verify' "$RUNBOOK/gdc.sh"
  [ "$status" -eq 0 ]
  run grep -F './gdc.sh --release v2026.08.06 host upgrade prepare <ssh-alias> <proposal-id>' "$RUNBOOK/gdc.sh"
  [ "$status" -eq 0 ]
  run grep -F './gdc.sh --release v2026.08.06 host upgrade watch <ssh-alias> <proposal-id>' "$RUNBOOK/gdc.sh"
  [ "$status" -eq 0 ]
  run grep -F './gdc.sh --release v2026.08.06 network upgrade verify <proposal-id>' "$RUNBOOK/gdc.sh"
  [ "$status" -eq 0 ]
}

@test "Gate B is public, current-lineage bound, and cannot bypass external Gate A" {
  verifier="$RUNBOOK/scripts/phase-public-network-verify.sh"

  [ -x "$verifier" ]
  run grep -F 'Require authentic external Gate A evidence before evaluating Gate B' "$verifier"
  [ "$status" -eq 0 ]
  run grep -F 'Gate A evidence does not declare an independent JOIN_PASS' "$verifier"
  [ "$status" -eq 0 ]
  run grep -F '# JOIN acceptance: PASS' "$verifier"
  [ "$status" -eq 0 ]
  run grep -F 'issue #28 external JOIN receipt' "$verifier"
  [ "$status" -eq 0 ]
  run grep -F 'ACTIVE but not an effective consensus validator' "$verifier"
  [ "$status" -eq 0 ]
  run grep -F 'common-height block hash' "$verifier"
  [ "$status" -eq 0 ]
  run grep -F 'write_phase_lineage' "$verifier"
  [ "$status" -eq 0 ]
  run grep -F 'credential from the public bootstrap' "$verifier"
  [ "$status" -ne 0 ]
}

@test "CPoC refuses ordinary PoC, stale lineage, missing phases, and fleet-wide zero" {
  observer="$RUNBOOK/scripts/phase-confirmation-poc.sh"

  [ -x "$observer" ]
  run grep -F 'CONFIRMATION_POC_GRACE_PERIOD' "$observer"
  [ "$status" -eq 0 ]
  run grep -F 'CONFIRMATION_POC_GENERATION' "$observer"
  [ "$status" -eq 0 ]
  run grep -F 'CONFIRMATION_POC_VALIDATION' "$observer"
  [ "$status" -eq 0 ]
  run grep -F 'CONFIRMATION_POC_COMPLETED' "$observer"
  [ "$status" -eq 0 ]
  run grep -F 'fleet-wide zero' "$observer"
  [ "$status" -eq 0 ]
  run grep -F 'different Genesis lineage' "$observer"
  [ "$status" -ne 0 ]
  run grep -F 'phase sequence is incomplete or out of order' "$observer"
  [ "$status" -eq 0 ]
  run grep -F 'trigger_height' "$observer"
  [ "$status" -eq 0 ]
  run grep -F 'resolve_expected_network_participants' "$observer"
  [ "$status" -eq 0 ]
  run grep -F 'current-lineage topology is absent; import sanitized JOIN receipts' "$observer"
  [ "$status" -ne 0 ]
}

@test "Host upgrade is immutable, local, resumable, and rejects unsafe plan heights" {
  prepare="$RUNBOOK/scripts/phase-host-upgrade-prepare.sh"
  watch="$RUNBOOK/scripts/phase-host-upgrade-watch.sh"

  [ -x "$prepare" ]
  [ -x "$watch" ]
  run grep -F 'Host-scoped target preparation' "$prepare"
  [ "$status" -eq 0 ]
  run grep -F 'GDC_UPGRADE_MIN_LEAD_BLOCKS' "$prepare"
  [ "$status" -eq 0 ]
  run grep -F 'GDC_HOST_UPGRADE_WATCH_TIMEOUT_SECONDS' "$watch"
  [ "$status" -eq 0 ]
  run grep -F 'exit 0' "$watch"
  [ "$status" -eq 0 ]
  run grep -F 'PREPARED' "$watch"
  [ "$status" -eq 0 ]
  run grep -F 'WAITING_HEIGHT' "$watch"
  [ "$status" -eq 0 ]
  run grep -F 'ACTIVATED' "$watch"
  [ "$status" -eq 0 ]
  run grep -F 'SYNCED' "$watch"
  [ "$status" -eq 0 ]
  run grep -F 'VALIDATOR_EFFECTIVE' "$watch"
  [ "$status" -eq 0 ]
  run grep -F 'FAILED' "$watch"
  [ "$status" -eq 0 ]
}

@test "managed firewall keeps explicit monitoring and ML allows terminal" {
  run "$RUNBOOK/scripts/test-firewall-policy.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"explicit allows are terminal"* ]]
}
