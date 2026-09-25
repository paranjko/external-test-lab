#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

mkdir -p "$temporary/bin"
cat >"$temporary/bin/getent" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >"$HOST_RECOVERY_GETENT_MARKER"
exit 99
EOF
chmod +x "$temporary/bin/getent"

cat >"$temporary/role-input.env" <<'EOF'
GDC_NODE_ALIASES=backup-node
GDC_NODE_PUBLIC_HOSTS=backup-node=unresolvable.example.invalid
GDC_NODE_P2P_PORTS=backup-node=5000
GDC_NODE_ML_HOSTS=
GDC_DEPLOYMENT_PROFILE=community-lab
GDC_OPERATOR_SERVICES_PROFILE=gdc-lab
GDC_JOIN_ROLE_INPUT=true
EOF

(
  export PATH="$temporary/bin:$PATH"
  export HOST_RECOVERY_GETENT_MARKER="$temporary/getent-called"
  export GDC_HOME="$temporary/data/backup-node"
  export GDC_DATA_ROOT="$temporary/data"
  export GDC_ENV="$temporary/role-input.env"
  export GDC_RELEASE_PROFILE=removed-release
  source "$ROOT/scripts/lib.sh"
  load_project host-recovery
  topology_contains_node backup-node
  [[ "$GDC_RUN_CONTEXT" == host-recovery ]]
  [[ "$GENESIS" == "$GDC_HOME/genesis" ]]
  [[ "$IDENTITIES" == "$GDC_HOME/state/identities" ]]
  [[ ! -e "$HOST_RECOVERY_GETENT_MARKER" ]]
  export GDC_RUN_ID=backup-run
  ensure_run_manifest backup-backup-node
  grep -qx 'profile_kind=host_recovery' "$GDC_HOME/runs/backup-run/manifest.env"
  ! grep -q '^release_profile=' "$GDC_HOME/runs/backup-run/manifest.env"
)

release_home="$temporary/release-data/backup-node"
release_run=active-upgrade-run
mkdir -p "$release_home/state" "$release_home/runs/$release_run"
printf '%s\n' "$release_run" >"$release_home/state/active-run-id"
release_hash=0000000000000000000000000000000000000000000000000000000000000000
cat >"$release_home/runs/$release_run/manifest.env" <<EOF
schema_version=2
run_id=$release_run
operator_data_home=$release_home
release_profile=v2026.08.06
release_profile_sha256=$release_hash
EOF
(
  export GDC_HOME="$release_home"
  export GDC_DATA_ROOT="$temporary/release-data"
  export GDC_ENV="$temporary/role-input.env"
  source "$ROOT/scripts/lib.sh"
  load_project host-recovery
  [[ "$GDC_RUN_CONTEXT" == host-recovery ]]
  [[ "$GDC_RUN_ID" == "$release_run" ]]
  ensure_run_manifest backup-backup-node
)

foreign_home="$temporary/foreign-data/backup-node"
mkdir -p "$foreign_home/state" "$foreign_home/runs/$release_run"
printf '%s\n' "$release_run" >"$foreign_home/state/active-run-id"
cp "$release_home/runs/$release_run/manifest.env" "$foreign_home/runs/$release_run/manifest.env"
if (
  export GDC_HOME="$foreign_home"
  export GDC_DATA_ROOT="$temporary/foreign-data"
  export GDC_ENV="$temporary/role-input.env"
  source "$ROOT/scripts/lib.sh"
  load_project host-recovery
  ensure_run_manifest backup-backup-node
) >"$temporary/foreign.out" 2>"$temporary/foreign.err"; then
  echo 'Host recovery accepted an active run from another operator data home' >&2
  exit 1
fi
grep -Fq 'run manifest belongs to another operator data home' "$temporary/foreign.err"

if (
  export PATH="$temporary/bin:$PATH"
  export HOST_RECOVERY_GETENT_MARKER="$temporary/network-getent-called"
  export GDC_HOME="$temporary/network/backup-node"
  export GDC_DATA_ROOT="$temporary/network"
  export GDC_ENV="$temporary/role-input.env"
  source "$ROOT/scripts/lib.sh"
  load_project
) >"$temporary/network.out" 2>"$temporary/network.err"; then
  echo 'network context accepted JOIN role input without its network seed host' >&2
  exit 1
fi
grep -Fq 'JOIN role input lacks a network seed host' "$temporary/network.err"
[[ ! -e "$temporary/network-getent-called" ]]

fallback_root="$temporary/fallback-runbook"
fallback_home="$temporary/fallback-home"
mkdir -p "$fallback_root/scripts" "$fallback_home/state" \
  "$fallback_home/runs/retained-run/join-backup-node" "$fallback_home/mnemonics"
sed -n '/^validate_mnemonic_bindings()/,/^}/p' \
  "$ROOT/scripts/validator-backup.sh" >"$fallback_root/validate-mnemonic-bindings.sh"
cat >"$fallback_root/scripts/join-profile.sh" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == validate && "$2" == --allow-expired && -f "$3" ]]
EOF
cat >"$fallback_root/scripts/ensure-inferenced-cli.sh" <<'EOF'
#!/usr/bin/env bash
printf 'ensure %s\n' "$*" >>"$BACKUP_FALLBACK_LOG"
touch "$BACKUP_MIGRATED_MARKER"
EOF
cat >"$fallback_root/scripts/resolve-shared-inferenced-cli.sh" <<'EOF'
#!/usr/bin/env bash
[[ -f "$BACKUP_MIGRATED_MARKER" ]] || exit 1
printf 'resolve %s\n' "$*" >>"$BACKUP_FALLBACK_LOG"
printf '%s\n' "$BACKUP_FAKE_CLI"
EOF
cat >"$fallback_root/scripts/derive-mnemonic-identity.sh" <<'EOF'
#!/usr/bin/env bash
jq -cn --arg address "$4" --arg pubkey "${5:-}" '{address:$address,pubkey:$pubkey}'
EOF
chmod +x "$fallback_root/scripts/"*.sh
printf 'retained-run\n' >"$fallback_home/state/active-run-id"
printf '{}\n' >"$fallback_home/runs/retained-run/join-backup-node/join-profile.v1.json"
printf 'cold words\n' >"$fallback_home/mnemonics/backup-node-cold.mnemonic"
printf 'warm words\n' >"$fallback_home/mnemonics/backup-node-warm.mnemonic"
cat >"$fallback_home/manifest.json" <<'EOF'
{"participant_address":"gonka1participant"}
EOF
cat >"$fallback_home/identity.json" <<'EOF'
{"warm_address":"gonka1warm","warm_pubkey_b64":"warm-public-key"}
EOF
cat >"$fallback_home/inferenced" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fallback_home/inferenced"
(
  export ROOT="$fallback_root" STATE="$fallback_home/state" GDC_HOME="$fallback_home"
  export HOME="$temporary/no-home" BACKUP_FALLBACK_LOG="$temporary/fallback.log"
  export BACKUP_MIGRATED_MARKER="$temporary/migrated" BACKUP_FAKE_CLI="$fallback_home/inferenced"
  die() { printf '%s\n' "$*" >&2; return 1; }
  source "$fallback_root/validate-mnemonic-bindings.sh"
  validate_mnemonic_bindings "$fallback_home" "$fallback_home/manifest.json" \
    "$fallback_home/identity.json" backup-node
)
sed -n '1p' "$temporary/fallback.log" | grep -Fq \
  'ensure --allow-expired --join-profile '
sed -n '2p' "$temporary/fallback.log" | grep -Fq \
  'resolve '

grep -Fq 'load_project host-recovery' "$ROOT/gdc.sh"
grep -Fq 'load_project host-recovery' "$ROOT/scripts/validator-backup.sh"
grep -Fq "stable identity migration failed" "$ROOT/scripts/validator-backup.sh"
grep -Fq 'tmkms inference 2>/dev/null' "$ROOT/scripts/validator-backup.sh"
grep -Fq 'generated JOIN deliberately keeps its exact CLI outside PATH' "$ROOT/scripts/validator-backup.sh"
grep -Fq 'resolve-shared-inferenced-cli.sh" "$retained_profile"' "$ROOT/scripts/validator-backup.sh"
grep -Fq 'docker inspect -f' "$ROOT/scripts/validator-backup.sh"
grep -Fq '/srv/dai/$node/tmkms) signer=' "$ROOT/scripts/validator-backup.sh"
grep -Fq 'load_retained_join_profile_for_node "$1"' "$ROOT/gdc.sh"
grep -Fq 'retained generated JOIN profile does not match its run manifest' "$ROOT/scripts/lib.sh"
! grep -Fq 'mkdir -p "$stage/remote-state"' "$ROOT/scripts/validator-backup.sh"
[[ -x "$ROOT/scripts/phase-host-backup.sh" ]]
printf 'PASS Host backup loads local recovery context without JOIN seed discovery\n'
