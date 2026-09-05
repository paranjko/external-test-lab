#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
grep -Fq 'profiles: [signer]' "$ROOT/02-node/compose.yaml"
grep -Fq 'independently acquired prior-Host evidence is not implemented' "$ROOT/scripts/phase-join-resume-signer.sh"
grep -Fq 'required: false' "$ROOT/02-node/compose.yaml"
grep -Fq -- '--enable-signer) enable_signer=true' "$ROOT/02-node/start-node.sh"
grep -Fq -- '--canary) canary=true' "$ROOT/02-node/start-node.sh"
grep -Fq 'services=(node)' "$ROOT/02-node/start-node.sh"
grep -Fq '[[ "$enable_signer" == false ]] && signerless_env=(env CONFIG_PRIV_VALIDATOR_LADDR=)' "$ROOT/02-node/start-node.sh"
grep -Fq 'profile_kind="$(awk -F=' "$ROOT/02-node/start-node.sh"
grep -Fq 'if [[ "$profile_kind" == generated_join ]]; then' "$ROOT/02-node/start-node.sh"
grep -Fq 'enable_signer=true' "$ROOT/02-node/start-node.sh"
grep -Fq 'verify-completed-join-signer-state.sh' "$ROOT/scripts/phase-node.sh"
grep -Fq 'remote_profile_binding=' "$ROOT/scripts/phase-node.sh"
grep -Fq 'GDC_JOIN_PROFILE_SHA256' "$ROOT/scripts/phase-node.sh"
grep -Fq 'does not match its completed signer receipt' "$ROOT/scripts/phase-node.sh"
grep -Fq 'start_args='\'' --enable-signer'\''' "$ROOT/scripts/phase-node.sh"
grep -Fq 'completed JOIN receipt does not authorize signer restart' "$ROOT/scripts/phase-node.sh"
# Exercise the default at the command boundary.  Genesis/HA-style release
# deployments must still select the signer profile, while a generated JOIN
# stays signerless unless its final phase requests --enable-signer.
mkdir -p "$tmp/start/bin"
cp "$ROOT/02-node/start-node.sh" "$tmp/start/start-node.sh"
cat >"$tmp/start/sync-node-config.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$tmp/start/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s signerless_listener=%s\n' "$*" "${CONFIG_PRIV_VALIDATOR_LADDR+set}" >>"$GDC_START_NODE_LOG"
exit 0
EOF
cat >"$tmp/start/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$tmp/start/start-node.sh" "$tmp/start/sync-node-config.sh" "$tmp/start/bin/docker" "$tmp/start/bin/sleep"
printf '%s\n' 'GDC_PROFILE_KIND=release' >"$tmp/start/.env"
printf '%s\n' 'services: {}' >"$tmp/start/compose.yaml"
printf '%s\n' false >"$tmp/start/.local-ml"
: >"$tmp/start/log"
PATH="$tmp/start/bin:$PATH" GDC_START_NODE_LOG="$tmp/start/log" "$tmp/start/start-node.sh" >"$tmp/start/release.out"
grep -Fq -- '--profile signer' "$tmp/start/log"
printf '%s\n' 'GDC_PROFILE_KIND=generated_join' >"$tmp/start/.env"
: >"$tmp/start/log"
PATH="$tmp/start/bin:$PATH" GDC_START_NODE_LOG="$tmp/start/log" "$tmp/start/start-node.sh" >"$tmp/start/join.out"
if grep -Fq -- '--profile signer' "$tmp/start/log"; then
  echo 'generated JOIN unexpectedly started its signer by default' >&2; exit 1
fi
grep -Fq 'signerless_listener=set' "$tmp/start/log"
PATH="$tmp/start/bin:$PATH" GDC_START_NODE_LOG="$tmp/start/log" "$tmp/start/start-node.sh" --enable-signer >"$tmp/start/join-signer.out"
grep -Fq -- '--profile signer' "$tmp/start/log"
grep -Fq 'CONFIG_priv_validator_laddr: ${CONFIG_PRIV_VALIDATOR_LADDR-tcp://0.0.0.0:26658}' "$ROOT/02-node/compose.yaml"
if grep -Fq 'CONFIG_priv_validator_laddr: ${CONFIG_PRIV_VALIDATOR_LADDR:-tcp://0.0.0.0:26658}' "$ROOT/02-node/compose.yaml"; then
  echo 'canary empty private-validator listener is incorrectly defaulted to TMKMS' >&2
  exit 1
fi
grep -Fq 'record_join_state "$NODE" SYNCING "$ADDRESS"' "$ROOT/scripts/phase-join.sh"
grep -Fq 'record_join_state "$NODE" PREPARED' "$ROOT/scripts/phase-join.sh"
grep -Fq 'record_join_state "$NODE" CAUGHT_UP "$ADDRESS"' "$ROOT/scripts/phase-join.sh"
grep -Fq 'record_join_state "$NODE" LINEAGE_VERIFIED "$ADDRESS"' "$ROOT/scripts/phase-join.sh"
grep -Fq 'record_join_state "$NODE" MEMBERSHIP_RECONCILED "$ADDRESS"' "$ROOT/scripts/phase-join.sh"
grep -Fq 'record_join_state "$NODE" PERMISSIONS_RECONCILED "$ADDRESS"' "$ROOT/scripts/phase-join.sh"
grep -Fq 'record_join_state "$NODE" SIGNER_FENCE_VERIFIED "$ADDRESS"' "$ROOT/scripts/phase-join.sh"
grep -Fq 'fence-existing-signer.sh' "$ROOT/scripts/phase-join.sh"
grep -Fq 'verify-signer-fence-receipt.sh' "$ROOT/scripts/phase-join.sh"
grep -Fq 'signer-fence-receipt.v1.json' "$ROOT/scripts/phase-join.sh"
grep -Fq 'kind:"signer_fence"' "$ROOT/scripts/phase-join.sh"
grep -Fq 'if [[ "$join_operation" == restore ]]; then' "$ROOT/scripts/phase-join.sh"
grep -Fq 'old_signer_fence_unprovable' "$ROOT/scripts/phase-join.sh"
grep -Fq 'controlled TMKMS stop failed' "$ROOT/02-node/fence-existing-signer.sh"
grep -Fq 'cannot inspect TMKMS after controlled stop' "$ROOT/02-node/fence-existing-signer.sh"
if grep -Fq 'stop tmkms >/dev/null 2>&1 || true' "$ROOT/02-node/fence-existing-signer.sh"; then
  echo 'signer fence masks controlled-stop failure' >&2
  exit 1
fi
grep -Fq 'record_join_state "$NODE" SIGNER_ENABLED "$ADDRESS"' "$ROOT/scripts/phase-join.sh"
grep -Fq 'record_signer_activation_guard' "$ROOT/scripts/phase-join.sh"
grep -Fq 'verify-active-signer-state.sh' "$ROOT/scripts/phase-join.sh"
grep -Fq 'verify-tmkms-signing-state.sh' "$ROOT/scripts/phase-join.sh"
prepared_line="$(grep -n 'record_join_state "$NODE" PREPARED' "$ROOT/scripts/phase-join.sh" | head -1 | cut -d: -f1)"
syncing_line="$(grep -n 'record_join_state "$NODE" SYNCING' "$ROOT/scripts/phase-join.sh" | head -1 | cut -d: -f1)"
lineage_line="$(grep -n 'record_join_state "$NODE" LINEAGE_VERIFIED' "$ROOT/scripts/phase-join.sh" | head -1 | cut -d: -f1)"
canonical_line="$(grep -n 'start-node.sh"$' "$ROOT/scripts/phase-join.sh" | head -1 | cut -d: -f1)"
canonical_verified_line="$(grep -n 'record_join_transition CANONICAL_VERIFIED' "$ROOT/scripts/phase-join.sh" | head -1 | cut -d: -f1)"
membership_line="$(grep -n 'record_join_state "$NODE" MEMBERSHIP_RECONCILED' "$ROOT/scripts/phase-join.sh" | head -1 | cut -d: -f1)"
permissions_line="$(grep -n 'record_join_state "$NODE" PERMISSIONS_RECONCILED' "$ROOT/scripts/phase-join.sh" | head -1 | cut -d: -f1)"
fenced_line="$(grep -n 'record_join_state "$NODE" SIGNER_FENCE_VERIFIED' "$ROOT/scripts/phase-join.sh" | head -1 | cut -d: -f1)"
enable_line="$(grep -n './start-node.sh --enable-signer' "$ROOT/scripts/phase-join.sh" | head -1 | cut -d: -f1)"
(( prepared_line < syncing_line && syncing_line < lineage_line )) || { echo 'JOIN state machine is not monotonic before signer enablement' >&2; exit 1; }
(( lineage_line < canonical_line && canonical_line < canonical_verified_line && canonical_verified_line < membership_line && membership_line < permissions_line && permissions_line < fenced_line && fenced_line < enable_line )) \
  || { echo 'signer can start before canonical verification, membership, permissions or technical fence verification' >&2; exit 1; }
restore_refusal_line="$(grep -n 'old_signer_fence_unprovable:' "$ROOT/scripts/phase-join.sh" | head -1 | cut -d: -f1)"
(( restore_refusal_line < fenced_line && restore_refusal_line < enable_line )) \
  || { echo 'restore can reach local fence or signer enablement without an external previous-Host fence' >&2; exit 1; }
observed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -n --arg observed_at "$observed_at" '{schema_version:1,kind:"gdc-signer-fence-receipt",run_id:"fixture-run",consensus_pubkey:"fixture-consensus-key",old_host_identity:"fixture-host",observed_at:$observed_at,method:"same_host_controlled_stop",controls:["compose_stop","process_readback"],old_signer_process_absent:true,old_signer_network_path_disabled:false,fence_height:0,evidence_sha256:("a" * 64)}' >"$tmp/fence.json"
chmod 600 "$tmp/fence.json"
"$ROOT/scripts/verify-signer-fence-receipt.sh" --receipt "$tmp/fence.json" --run-id fixture-run --consensus-pubkey fixture-consensus-key >"$tmp/fence.out"
grep -Fq 'PASS verified signer-fence receipt=' "$tmp/fence.out"
if "$ROOT/scripts/verify-signer-fence-receipt.sh" --receipt "$tmp/fence.json" --run-id fixture-run --consensus-pubkey fixture-consensus-key --replacement >"$tmp/replacement.out" 2>"$tmp/replacement.err"; then
  echo 'same-host signer stop unexpectedly authorized replacement signer activation' >&2; exit 1
fi
grep -Fq 'independently acquired prior-Host evidence' "$tmp/replacement.err"
jq -n --arg observed_at "$observed_at" '{schema_version:1,kind:"gdc-signer-fence-receipt",run_id:"fixture-run",consensus_pubkey:"fixture-consensus-key",old_host_identity:"previous-host",observed_at:$observed_at,method:"remote_host_controlled_stop",controls:["service_disabled","network_acl","process_readback"],old_signer_process_absent:true,old_signer_network_path_disabled:true,fence_height:42,evidence_sha256:("b" * 64)}' >"$tmp/replacement-fence.json"
chmod 600 "$tmp/replacement-fence.json"
if "$ROOT/scripts/verify-signer-fence-receipt.sh" --receipt "$tmp/replacement-fence.json" --run-id fixture-run --consensus-pubkey fixture-consensus-key --replacement >"$tmp/replacement-fence.out" 2>"$tmp/replacement-fence.err"; then
  echo 'operator-authored replacement signer fence unexpectedly verified' >&2; exit 1
fi
grep -Fq 'independently acquired prior-Host evidence' "$tmp/replacement-fence.err"
jq '.old_signer_process_absent = false' "$tmp/fence.json" >"$tmp/invalid-fence.json"
chmod 600 "$tmp/invalid-fence.json"
if "$ROOT/scripts/verify-signer-fence-receipt.sh" --receipt "$tmp/invalid-fence.json" --run-id fixture-run --consensus-pubkey fixture-consensus-key >"$tmp/invalid.out" 2>"$tmp/invalid.err"; then
  echo 'signer fence receipt without absence proof unexpectedly verified' >&2; exit 1
fi
grep -Fq 'invalid signer-fence receipt' "$tmp/invalid.err"
printf 'PASS JOIN keeps TMKMS fenced through canonical application and membership reconciliation\n'
