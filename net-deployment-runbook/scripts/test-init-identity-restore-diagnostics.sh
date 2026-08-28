#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INIT_IDENTITY="$ROOT/02-node/init-identity.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

canary='WARM_MNEMONIC_SECRET_CANARY'
cat >"$tmp/node.env" <<EOF
DATA_DIR=$tmp/data
KEYRING_PASSWORD=KEYRING_PASSWORD_SECRET_CANARY
KEY_NAME=gdc-node2-warm
NODE_NAME=gdc-node2
EOF
printf '%s\n' "$canary" >"$tmp/warm.mnemonic"

mkdir -p "$tmp/bin"
cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$FAKE_DOCKER_LOG"
case "$*" in
  *'keys show'*) exit 1 ;;
  *'keyring-file.gdc-pre-restore-'*) printf preserved ;;
  *'keys add'*'--recover'*) printf 'keyring password rejected\n' >&2; exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$tmp/bin/docker"

if PATH="$tmp/bin:$PATH" FAKE_DOCKER_LOG="$tmp/docker.log" "$INIT_IDENTITY" \
  --env "$tmp/node.env" --output "$tmp/identity.json" \
  --mnemonic-output "$tmp/new.mnemonic" --warm-mnemonic "$tmp/warm.mnemonic" \
  >"$tmp/out" 2>"$tmp/err"; then
  echo 'failed warm-key import unexpectedly succeeded' >&2
  exit 1
fi
grep -Fq 'READY preserved unreadable Host keyring before restoring validator backup identity' "$tmp/out"
grep -Fq 'Cannot restore warm key: reason=keyring_authentication_failed' "$tmp/err"
grep -Fq 'keyring-file.gdc-pre-restore-' "$tmp/docker.log"
! grep -Fq "$canary" "$tmp/out" "$tmp/err" "$tmp/docker.log"
! grep -Fq 'KEYRING_PASSWORD_SECRET_CANARY' "$tmp/out" "$tmp/err" "$tmp/docker.log"

printf 'PASS warm-key restore keeps stale keyring recoverable and diagnostics secret-safe\n'
