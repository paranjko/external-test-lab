#!/usr/bin/env bash
# Resolve the last reset archive that still proves this Host's signer identity.
set -Eeuo pipefail
umask 077

die() { printf 'reset archive resolver: %s\n' "$*" >&2; exit 1; }

[[ $# -eq 1 ]] || die 'usage: resolve-reset-dai-backup.sh RESET_DIRECTORY'
reset_dir="$1"
[[ -d "$reset_dir" && ! -L "$reset_dir" ]] || die 'reset evidence directory is unsafe or absent'

validate_metadata() {
  local metadata="$1"
  [[ -f "$metadata" && ! -L "$metadata" && "$(stat -c %a "$metadata")" == 600 ]] \
    || die 'reset archive metadata is not a private regular file'
  jq -e '
    .schema_version == 1 and .kind == "gdc-reset-dai-backup"
    and .identity_present == true and .signer_stopped == true
    and (.archive_path | type == "string" and test("^/srv/backup/reset-[A-Za-z0-9][A-Za-z0-9._-]{0,127}-dai-backup\\.tar$"))
    and (.archive_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
  ' "$metadata" >/dev/null || die 'reset archive metadata does not prove a stopped signer identity'
}

pointer="$reset_dir/latest-identity.json"
if [[ -e "$pointer" ]]; then
  [[ -f "$pointer" && ! -L "$pointer" && "$(stat -c %a "$pointer")" == 600 ]] \
    || die 'reset archive identity pointer is not a private regular file'
  metadata="$(jq -er '.metadata_path | select(type == "string")' "$pointer")" \
    || die 'reset archive identity pointer lacks metadata_path'
  metadata_sha256="$(jq -er '.metadata_sha256 | select(type == "string" and test("^[0-9a-f]{64}$"))' "$pointer")" \
    || die 'reset archive identity pointer lacks metadata_sha256'
  case "$metadata" in
    "$reset_dir"/reset-*-dai-backup.json) ;;
    *) die 'reset archive identity pointer escapes its evidence directory' ;;
  esac
  validate_metadata "$metadata"
  [[ "$(sha256sum "$metadata" | awk '{print $1}')" == "$metadata_sha256" ]] \
    || die 'reset archive identity pointer digest does not match metadata'
  printf '%s\n' "$metadata"
  exit 0
fi

# Read-only compatibility for reset evidence produced before run-named local
# metadata was introduced. It is deliberately accepted only when it proves an
# identity-bearing archive, never for an empty later reset.
legacy="$reset_dir/reset-dai-backup.json"
validate_metadata "$legacy"
printf '%s\n' "$legacy"
