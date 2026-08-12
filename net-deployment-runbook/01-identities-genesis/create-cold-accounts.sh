#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
PASSWORD_FILE="${1:-$STATE/secrets/operator.keyring}"
[[ -s "$PASSWORD_FILE" ]] || { echo "Missing $PASSWORD_FILE; run scripts/make-secrets.sh" >&2; exit 1; }
PASSWORD="$(<"$PASSWORD_FILE")"
shift || true
BACKUP_DIR="$GDC_HOME/mnemonics"
normalize_account_name() {
  local input="$1" base
  case "$input" in
    gdc-gateway-cold|gdc-gateway) base="gdc-gateway" ;;
    *-cold)
      base="${input%-cold}"
      [[ "$base" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Invalid account target: $input" >&2; return 1; }
      ;;
    *)
      base="$input"
      [[ "$base" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Invalid account target: $input" >&2; return 1; }
      ;;
  esac
  printf '%s\n' "$base-cold"
}

if [[ "$#" -gt 0 ]]; then
  TARGETS=()
  for input in "$@"; do
    TARGETS+=( "$(normalize_account_name "$input")" )
  done
else
  echo 'Specify at least one validator alias and/or gdc-gateway; refusing to create an implicit topology.' >&2
  exit 2
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
  address_backup="$BACKUP_DIR/$name.address"
  address="$(jq -er .address "$GDC_HOME/accounts/$name.json")"
  [[ "$address" =~ ^gonka1[0-9a-z]{20,90}$ ]] || {
    echo "FAILED  $name public account export has an invalid cold address" >&2
    exit 1
  }
  # The mnemonic remains the recovery secret. Keep its matching public cold
  # address alongside it so an operator can identify the wallet without
  # importing the seed. Treat an unexpected pre-existing value as a safety
  # failure rather than silently replacing a recovery reference.
  if [[ -e "$address_backup" ]]; then
    [[ "$(<"$address_backup")" == "$address" ]] || {
      echo "FAILED  $name cold-address backup disagrees with the keyring" >&2
      exit 1
    }
  else
    printf '%s\n' "$address" >"$address_backup"
    chmod 600 "$address_backup"
  fi
done
printf 'ACCOUNTS  new=%d kept=%d cold-address-references=%d\n' \
  "$new_count" "$keep_count" "${#seen[@]}"
