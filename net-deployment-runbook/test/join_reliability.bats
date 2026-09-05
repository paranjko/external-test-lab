#!/usr/bin/env bats

setup() {
  RUNBOOK="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

run_contract() {
  run "$RUNBOOK/scripts/$1"
  [ "$status" -eq 0 ]
}

@test "JOIN reliability contracts preserve stable identity and reject unsafe promotion" {
  run_contract test-migrate-v1-validator-identity.sh
  run_contract test-promote-state-sync-generation.sh
}

@test "JOIN reliability contracts keep the canary and signer safely fenced" {
  run_contract test-signer-activation-gate.sh
  run_contract test-verify-tmkms-signing-state.sh
}

@test "JOIN reliability contracts refuse stale lineage and retain idempotent history" {
  run_contract test-join-lineage-preflight.sh
  run_contract test-join-transition-receipts.sh
  run_contract test-host-join-plan.sh
}
