#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 2 && "$1" =~ ^gdc-node[1-4]$ ]] || {
  echo 'Usage: make-node-operator-secrets.sh gdc-nodeN secrets-dir' >&2
  exit 2
}

NODE="$1"
OUT="$2"
umask 077
install -d -m 0700 "$OUT"

random() {
  openssl rand -base64 48 | tr -d '\n/+=' | cut -c1-48
}

write_once() {
  local path="$1"
  [[ -e "$path" ]] || {
    printf '%s\n' "$(random)" >"$path"
    chmod 600 "$path"
  }
}

# These files protect keys created by this operator. They do not contain or
# derive any Genesis-operator key material.
write_once "$OUT/operator.keyring"
write_once "$OUT/$NODE.keyring"
write_once "$OUT/$NODE.postgres"
printf 'READY local secrets for %s\n' "$NODE"
