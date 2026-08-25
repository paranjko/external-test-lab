#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP="$ROOT/scripts/validator-backup.sh"

bash -n "$BACKUP" "$ROOT/gdc.sh" "$ROOT/scripts/phase-join.sh" "$ROOT/scripts/phase-genesis.sh" \
  "$ROOT/01-identities-genesis/collect-identities.sh" "$ROOT/02-node/init-identity.sh" \
  "$ROOT/03-join/grant-ml-ops.sh"

grep -Fq -- '--restore)' "$ROOT/gdc.sh"
grep -Fq 'GDC_RESTORE_VALIDATOR_BACKUP_ARCHIVE' "$ROOT/gdc.sh"
grep -Fq 'validator-backup.sh" restore' "$ROOT/scripts/phase-join.sh"
grep -Fq 'validator-backup.sh" create' "$ROOT/scripts/phase-join.sh"
grep -Fq 'validator-backup.sh" create' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'topology_contains_node "$2" || die "unknown SSH alias: $2"' "$BACKUP"
grep -Fq 'create_backup "$2"' "$BACKUP"
grep -Fq 'configured_gpu="$(node_ml_host "$node" || true)"' "$BACKUP"
! grep -Fq 'create_backup "$(node_name "$2")"' "$BACKUP"
grep -Fq 'refusing to create a duplicate participant' "$ROOT/scripts/phase-join.sh"
grep -Fq 'cold and warm mnemonics alone cannot restore it' "$ROOT/scripts/phase-join.sh"
participant_check_line="$(grep -n 'participant already exists on this chain' "$ROOT/scripts/phase-join.sh" | head -n1 | cut -d: -f1)"
identity_bootstrap_line="$(grep -n 'collect-identities.sh' "$ROOT/scripts/phase-join.sh" | head -n1 | cut -d: -f1)"
[[ "$participant_check_line" -lt "$identity_bootstrap_line" ]] || {
  echo 'existing participant recovery check must precede identity bootstrap' >&2
  exit 1
}
acceptance_line="$(grep -n 'phase-join-acceptance.sh' "$ROOT/scripts/phase-join.sh" | tail -n1 | cut -d: -f1)"
backup_line="$(grep -n 'validator-backup.sh" create' "$ROOT/scripts/phase-join.sh" | tail -n1 | cut -d: -f1)"
[[ "$backup_line" -lt "$acceptance_line" ]]
genesis_acceptance_line="$(grep -n 'phase-join-acceptance.sh' "$ROOT/scripts/phase-genesis.sh" | tail -n1 | cut -d: -f1)"
genesis_backup_line="$(grep -n 'validator-backup.sh" create' "$ROOT/scripts/phase-genesis.sh" | tail -n1 | cut -d: -f1)"
[[ "$genesis_backup_line" -gt "$genesis_acceptance_line" ]]
grep -Fq 'keys add "$KEY_NAME" --recover --keyring-backend file' "$ROOT/02-node/init-identity.sh"
grep -Fq -- '--warm-mnemonic' "$ROOT/01-identities-genesis/collect-identities.sh"
grep -Fq 'sha256sum -c manifest.sha256' "$BACKUP"
grep -Fq 'test ! -e' "$BACKUP" || { echo 'restore must refuse to overwrite existing validator state' >&2; exit 1; }
grep -Fq 'inference/config/node_key.json' "$BACKUP" || { echo 'backup must preserve the P2P node identity' >&2; exit 1; }
grep -Fq 'remote-state/inference/config/node_key.json' "$BACKUP"
grep -Fq 'validator-backup.tar' "$ROOT/ROLE-JOIN.md"
! grep -Fq -- '--restore' "$ROOT/ROLE-JOIN.md"
grep -Fq 'was accepted by the public RPC but was not committed within 60 seconds' "$ROOT/03-join/grant-ml-ops.sh"
grep -Fq "sed '/^Usage:/,\$d'" "$ROOT/03-join/grant-ml-ops.sh"

printf 'PASS validator backup and restore contract\n'
