#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/state/secrets}"
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
for i in 0 1 2 3 4; do
  write_once "$OUT/gdc-node${i}.keyring" "$(random)"
  write_once "$OUT/gdc-node${i}.postgres" "$(random)"
done
write_once "$OUT/operator.keyring" "$(random)"
write_once "$OUT/grafana.admin" "$(random)"
write_once "$OUT/gateway.admin-key" "sk-admin-$(openssl rand -hex 24)"
write_once "$OUT/gateway.client-keys" "sk-gdc-$(openssl rand -hex 24)"
write_once "$OUT/bridge.jwt" "$(openssl rand -hex 32)"
printf 'SECRETS  new=%d kept=%d path=%s\n' "$new_count" "$keep_count" "$OUT"
