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

grep -Fq 'load_project host-recovery' "$ROOT/gdc.sh"
grep -Fq 'load_project host-recovery' "$ROOT/scripts/validator-backup.sh"
grep -Fq "stable identity migration failed" "$ROOT/scripts/validator-backup.sh"
grep -Fq 'tmkms inference 2>/dev/null' "$ROOT/scripts/validator-backup.sh"
! grep -Fq 'mkdir -p "$stage/remote-state"' "$ROOT/scripts/validator-backup.sh"
[[ -x "$ROOT/scripts/phase-host-backup.sh" ]]
printf 'PASS Host backup loads local recovery context without JOIN seed discovery\n'
