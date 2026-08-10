#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
OUT="${1:-$STATE/secrets}"
GENESIS_NODE="${2:-}"
[[ "$GENESIS_NODE" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'Usage: make-secrets.sh [secrets-dir] GENESIS_SSH_ALIAS' >&2; exit 2; }
umask 077
mkdir -p "$OUT"
new_count=0 keep_count=0
random() { openssl rand -base64 48 | tr -d '\n/+=' | cut -c1-48; }
write_once() {
  local path="$1" value="$2"
  if [[ -e "$path" ]]; then
    keep_count=$((keep_count + 1))
  else
    printf '%s\n' "$value" > "$path"
    chmod 600 "$path"
    new_count=$((new_count + 1))
  fi
}
write_once "$OUT/$GENESIS_NODE.keyring" "$(random)"
write_once "$OUT/$GENESIS_NODE.postgres" "$(random)"
write_once "$OUT/operator.keyring" "$(random)"
write_once "$OUT/grafana.admin" "$(random)"
write_once "$OUT/gateway.admin-key" "sk-admin-$(openssl rand -hex 24)"
write_once "$OUT/gateway.client-keys" "sk-gdc-$(openssl rand -hex 24)"
write_once "$OUT/gateway.telegram-client-key" "sk-gdc-telegram-$(openssl rand -hex 24)"
write_once "$OUT/telegram.conversation-api-token" "$(random)"
write_once "$OUT/bridge.jwt" "$(openssl rand -hex 32)"
printf 'SECRETS  new=%d kept=%d path=%s\n' "$new_count" "$keep_count" "$OUT"
