#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASSWORD_FILE="${1:-$ROOT/state/secrets/operator.keyring}"
[[ -s "$PASSWORD_FILE" ]] || { echo "Missing $PASSWORD_FILE; run scripts/make-secrets.sh" >&2; exit 1; }
PASSWORD="$(<"$PASSWORD_FILE")"
shift || true
BACKUP_DIR="$ROOT/artifacts/mnemonics"
normalize_account_name() {
  local input="$1" base
  case "$input" in
    gdc-node[0-4]-cold|gdc-node[0-4]) base="${input%-cold}" ;;
    node[0-4]-cold) base="gdc-${input%-cold}" ;;
    node[0-4]) base="gdc-$input" ;;
    gdc-gateway-cold|gdc-gateway) base="gdc-gateway" ;;
    *) echo "Unknown account target: $input" >&2; return 1 ;;
  esac
  printf '%s\n' "$base-cold"
}

if [[ "$#" -gt 0 ]]; then
  TARGETS=()
  for input in "$@"; do
    TARGETS+=( "$(normalize_account_name "$input")" )
  done
else
  TARGETS=(gdc-node0-cold gdc-node1-cold gdc-node2-cold gdc-node3-cold gdc-node4-cold gdc-gateway-cold)
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
umask 077
mkdir -p "$BACKUP_DIR"
new_count=0 keep_count=0
declare -A seen=()
for name in "${TARGETS[@]}"; do
  if [[ -n "${seen[$name]:-}" ]]; then
    continue
  fi
  seen[$name]=1
  backup="$BACKUP_DIR/$name.mnemonic"
  if printf '%s\n' "$PASSWORD" | "$ROOT/scripts/inferenced.sh" keys show "$name" --keyring-backend file -a >/dev/null 2>&1; then
    [[ -s "$backup" ]] || { echo "FAILED  $name exists without $backup; rotate the account" >&2; exit 1; }
    keep_count=$((keep_count + 1))
  else
    output="$TMP/$name.out"
    if ! printf '%s\n%s\n' "$PASSWORD" "$PASSWORD" \
      | "$ROOT/scripts/inferenced.sh" keys add "$name" --keyring-backend file >"$output" 2>&1; then
      install -m 0600 "$output" "$BACKUP_DIR/$name.error.log"
      echo "FAILED  $name creation; details: $BACKUP_DIR/$name.error.log" >&2
      exit 1
    fi
    mapfile -t phrases < <(awk 'NF == 24 {valid=1; for (i=1; i<=NF; i++) if ($i !~ /^[a-z]+$/) valid=0; if (valid) print}' "$output")
    (( ${#phrases[@]} == 1 )) || {
      install -m 0600 "$output" "$BACKUP_DIR/$name.error.log"
      echo "FAILED  cannot extract one mnemonic for $name; details: $BACKUP_DIR/$name.error.log" >&2
      exit 1
    }
    if [[ -e "$backup" ]]; then
      mv "$backup" "$BACKUP_DIR/$name.previous.$(date -u +%Y%m%dT%H%M%SZ).mnemonic"
    fi
    printf '%s\n' "${phrases[0]}" >"$backup"
    chmod 600 "$backup"
    new_count=$((new_count + 1))
  fi
  "$ROOT/01-identities-genesis/export-account-public.sh" "$name" "$PASSWORD_FILE" >/dev/null
done
printf 'ACCOUNTS  new=%d kept=%d\n' "$new_count" "$keep_count"
