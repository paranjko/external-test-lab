#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
cat >"$tmp/receipt.json" <<'EOF'
{"bootstrap":{"trust":{"height":3000,"expires_at":"2999-01-01T00:00:00Z"}},"fault_domains":[{"rpc_url":"https://rpc-a.example.test/chain-rpc","host":"rpc-a.example.test","port":443,"ip":"192.0.2.10"},{"rpc_url":"https://rpc-b.example.test/chain-rpc","host":"rpc-b.example.test","port":443,"ip":"192.0.2.11"}]}
EOF
mkdir -p "$tmp/bin"
cat >"$tmp/bin/date" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
for arg in "$@"; do [[ "$arg" == -d ]] && exit 1; done
if [[ "${1:-}" == -j ]]; then
  exec /bin/date -u -d "${5:-}" +%s
fi
exec /bin/date "$@"
EOF
chmod 0755 "$tmp/bin/date"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${!#}"
if [[ "$url" == */status || "$url" == *height=* ]]; then
  found=''
  for ((i=1; i<=$#; i++)); do [[ "${!i}" == --resolve ]] && { j=$((i+1)); found="${!j}"; break; }; done
  [[ "$found" == rpc-a.example.test:443:192.0.2.10 || "$found" == rpc-b.example.test:443:192.0.2.11 || "$url" == *join.example.test* ]] || exit 24
fi
case "$url" in
  */status) printf '%s\n' '{"result":{"sync_info":{"latest_block_height":"5000"}}}' ;;
  *height=5000)
    app=2222222222222222222222222222222222222222222222222222222222222222
    if [[ "${GDC_TEST_BAD_APPHASH:-false}" == true && "$url" == *join.example.test* ]]; then
      app=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    fi
    printf '{"result":{"block_id":{"hash":"1111111111111111111111111111111111111111111111111111111111111111"},"block":{"header":{"height":"5000","app_hash":"%s"}}}}\n' "$app"
    ;;
  *) exit 22 ;;
esac
EOF
chmod 0755 "$tmp/bin/curl"
PATH="$tmp/bin:$PATH" "$ROOT/scripts/verify-lineage-trust-fresh.sh" "$tmp/receipt.json" >"$tmp/fresh-trust.out"
grep -Fq 'PASS lineage trust remains fresh' "$tmp/fresh-trust.out"
PATH="$tmp/bin:$PATH" "$ROOT/scripts/verify-join-lineage-state.sh" https://join.example.test/chain-rpc "$tmp/receipt.json" >"$tmp/out"
grep -Fq 'PASS JOIN fresh post-sync checkpoint matches' "$tmp/out"
if PATH="$tmp/bin:$PATH" GDC_TEST_BAD_APPHASH=true "$ROOT/scripts/verify-join-lineage-state.sh" https://join.example.test/chain-rpc "$tmp/receipt.json" >"$tmp/divergence.out" 2>"$tmp/divergence.err"; then
  echo 'fresh AppHash divergence unexpectedly verified' >&2; exit 1
fi
grep -Fq 'apphash_divergence:' "$tmp/divergence.err"
PATH="$tmp/bin:$PATH" "$ROOT/scripts/verify-join-lineage-state.sh" http://join.example.test:8000/chain-rpc "$tmp/receipt.json" >"$tmp/http-port.out"
expired="$tmp/expired-receipt.json"
jq '.bootstrap.trust.expires_at = "2000-01-01T00:00:00Z"' "$tmp/receipt.json" >"$expired"
if PATH="$tmp/bin:$PATH" "$ROOT/scripts/verify-join-lineage-state.sh" https://join.example.test/chain-rpc "$expired" >"$tmp/expired.out" 2>"$tmp/expired.err"; then
  echo 'expired lineage trust unexpectedly verified' >&2; exit 1
fi
grep -Fq 'lineage_trust_expired:' "$tmp/expired.err"
grep -Fq 'CONFIG_statesync__trust_height' "$ROOT/02-node/compose.yaml"
grep -Fq 'CONFIG_statesync__trust_hash' "$ROOT/02-node/compose.yaml"
grep -Fq 'CONFIG_statesync__rpc_servers' "$ROOT/02-node/compose.yaml"
grep -Fq 'CONFIG_p2p__persistent_peers' "$ROOT/02-node/compose.yaml"
grep -Fq 'GDC_JOIN_PERSISTENT_PEERS' "$ROOT/02-node/compose.yaml"
grep -Fq 'CONFIG_priv_validator_laddr' "$ROOT/02-node/compose.yaml"
grep -Fq 'GDC_JOIN_SNAPSHOT_PEERS' "$ROOT/02-node/render-node-env.sh"
grep -Fq '[[ "$enable_signer" == false ]] && signerless_env=(env CONFIG_PRIV_VALIDATOR_LADDR=)' "$ROOT/02-node/start-node.sh"
grep -Fq 'if [[ "$profile_kind" == generated_join ]]; then' "$ROOT/02-node/start-node.sh"
grep -Fq 'enable_signer=true' "$ROOT/02-node/start-node.sh"
grep -Fq 'unregistered local key' "$ROOT/02-node/start-node.sh"
grep -Fq 'rtrimstr("/") + "/"' "$ROOT/02-node/verify-state-sync-config.sh"
grep -Fq 'config_matches_receipt' "$ROOT/02-node/verify-state-sync-config.sh"
grep -Fq 'lineage_trust_expired:' "$ROOT/02-node/verify-state-sync-config.sh"
grep -Fq 'verify-lineage-trust-fresh.sh' "$ROOT/scripts/phase-join.sh"
grep -Fq 'verify-join-lineage-state.sh' "$ROOT/scripts/phase-join.sh"
grep -Fq 'scripts/portable.sh' "$ROOT/scripts/phase-join.sh"
grep -Fq 'record-state-sync-canary.sh' "$ROOT/scripts/phase-join.sh"
grep -Fq 'lineage-state-sync-receipt.json' "$ROOT/scripts/phase-join.sh"
grep -Fq 'GDC_JOIN_GATEWAY_ADMISSION_PROTOCOLS_JSON' "$ROOT/scripts/phase-join.sh"
grep -Fq -- '--gateway-admission-protocols-json' "$ROOT/scripts/phase-join.sh"
grep -Fq 'JOIN lineage preflight did not provide a valid DevShard compatibility set' "$ROOT/04-ops/edge-node/render-env.sh"
grep -Fq 'stop-state-sync-canary.sh' "$ROOT/scripts/phase-join.sh"
grep -Fq 'record_join_state "$NODE" CANARY_STOPPED "$ADDRESS"' "$ROOT/scripts/phase-join.sh"
grep -Fq 'stop-state-sync-canary.sh' "$ROOT/02-node/install-node.sh"
grep -Fq 'ensure-warm-key.sh' "$ROOT/02-node/install-node.sh"
grep -Fq 'verify-canonical-join-state.sh' "$ROOT/02-node/install-node.sh"
grep -Fq 'verify-active-signer-state.sh' "$ROOT/02-node/install-node.sh"
grep -Fq 'migrate-v1-validator-identity.sh' "$ROOT/02-node/install-node.sh"
grep -Fq 'IDENTITY_DIR=/srv/dai/identity/$NODE' "$ROOT/02-node/render-node-env.sh"
grep -Fq 'SIGNER_DIR=/srv/dai/signer/$NODE' "$ROOT/02-node/render-node-env.sh"
grep -Fq '${SIGNER_DIR:?SIGNER_DIR is required}/tmkms' "$ROOT/02-node/compose.yaml"
grep -Fq '${IDENTITY_DIR:?IDENTITY_DIR is required}/warm/keyring-file:/root/.inference/keyring-file:ro' "$ROOT/02-node/compose.yaml"
grep -Fq '/gdc-identity/p2p/node_key.json' "$ROOT/02-node/node-entrypoint.sh"
grep -Fq 'migrate-v1-validator-identity.sh' "$ROOT/scripts/validator-backup.sh"
grep -Fq 'ln -s "$generation" "$next"' "$ROOT/02-node/promote-state-sync-generation.sh"
grep -Fq 'mv -Tf "$next" "$canonical"' "$ROOT/02-node/promote-state-sync-generation.sh"
grep -Fq 'write_receipt PROMOTING "$previous"' "$ROOT/02-node/promote-state-sync-generation.sh"
grep -Fq 'write_receipt PROMOTED "$previous"' "$ROOT/02-node/promote-state-sync-generation.sh"
grep -Fq 'canary_still_running' "$ROOT/02-node/promote-state-sync-generation.sh"
grep -Fq 'canonical data path is a legacy directory' "$ROOT/02-node/promote-state-sync-generation.sh"
grep -Fq 'stale active.next exists without a promotion journal' "$ROOT/02-node/promote-state-sync-generation.sh"
grep -Fq 'active pointer changed outside the recorded promotion' "$ROOT/02-node/promote-state-sync-generation.sh"
if grep -Fq 'mv "$generation" "$canonical"' "$ROOT/02-node/promote-state-sync-generation.sh"; then
  echo 'state-sync promotion still moves the candidate generation instead of atomically switching an active pointer' >&2
  exit 1
fi
grep -Fq 'gdc-stage.XXXXXX' "$ROOT/02-node/install-node.sh"
grep -Fq 'GDC_PROFILE_KIND' "$ROOT/02-node/install-node.sh"
grep -Fq 'generated_join)' "$ROOT/02-node/install-node.sh"
grep -Fq 'GDC_JOIN_PROFILE_SHA256' "$ROOT/02-node/install-node.sh"
grep -Fq 'gdc-join-profile.v1.json' "$ROOT/02-node/install-node.sh"
grep -Fq -- '--join-profile' "$ROOT/scripts/phase-join.sh"
grep -Fq 'different generated JOIN profile exists' "$ROOT/02-node/install-node.sh"
grep -Fq 'legacy release deployment exists' "$ROOT/02-node/install-node.sh"
grep -Fq 'generated JOIN deployment exists' "$ROOT/02-node/install-node.sh"
grep -Fq '"$STAGE/.gdc-join-profile"' "$ROOT/02-node/install-node.sh"
grep -Fq 'chmod 600 "$STAGE/.gdc-join-profile"' "$ROOT/02-node/install-node.sh"
grep -Fq 'mv "$STAGE" "$DEST"' "$ROOT/02-node/install-node.sh"
grep -Fq 'backup_move_started=false' "$ROOT/02-node/install-node.sh"
grep -Fq 'deployment_move_started=false' "$ROOT/02-node/install-node.sh"
grep -Fq 'if [[ -e "$BACKUP" ]]; then' "$ROOT/02-node/install-node.sh"
grep -Fq 'backup_move_started=true' "$ROOT/02-node/install-node.sh"
grep -Fq 'deployment_move_started=true' "$ROOT/02-node/install-node.sh"
grep -Fq '^https?://[A-Za-z0-9.-]+(:[1-9][0-9]{0,4})?/chain-rpc/$' "$ROOT/02-node/render-node-env.sh"
grep -Fq '^https?://[A-Za-z0-9.-]+(:[1-9][0-9]{0,4})?/chain-rpc$' "$ROOT/02-node/wait-state-sync-canary.sh"
grep -Fq 'restore-validator-backup.tar' "$ROOT/scripts/phase-join.sh"
grep -Fq 'restore_archive_sha256' "$ROOT/scripts/phase-join.sh"
grep -Fq 'validator backup archive changed after the JOIN profile was resolved' "$ROOT/scripts/phase-join.sh"
grep -Fq 'GDC_RESTORE_VALIDATOR_BACKUP_ARCHIVE="$restore_archive"' "$ROOT/scripts/phase-join.sh"
grep -Fq 'Bind $NODE warm account to the promoted signerless generation' "$ROOT/scripts/phase-join.sh"
grep -Fq 'Read back canonical signerless Core identity, runtime and state for $NODE' "$ROOT/scripts/phase-join.sh"
grep -Fq 'record_join_transition CANONICAL_VERIFIED' "$ROOT/scripts/phase-join.sh"
printf 'PASS JOIN pins receipt trust and verifies a fresh post-sync checkpoint\n'
