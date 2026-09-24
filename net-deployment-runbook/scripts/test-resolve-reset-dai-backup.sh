#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
reset_dir="$tmp/reset"
mkdir -p "$reset_dir"
chmod 700 "$reset_dir"

metadata="$reset_dir/reset-run-a-dai-backup.json"
jq -n '{schema_version:1,kind:"gdc-reset-dai-backup",identity_present:true,signer_stopped:true,archive_path:"/srv/backup/reset-run-a-dai-backup.tar",archive_sha256:("a" * 64)}' >"$metadata"
chmod 600 "$metadata"
metadata_sha256="$(sha256sum "$metadata" | awk '{print $1}')"
jq -n --arg path "$metadata" --arg sha "$metadata_sha256" \
  '{schema_version:1,kind:"gdc-reset-dai-backup-reference",metadata_path:$path,metadata_sha256:$sha}' \
  >"$reset_dir/latest-identity.json"
chmod 600 "$reset_dir/latest-identity.json"

[[ "$(bash "$ROOT/scripts/resolve-reset-dai-backup.sh" "$reset_dir")" == "$metadata" ]]

# A later reset with no identity never replaces the identity-bearing pointer.
empty="$reset_dir/reset-run-b-dai-backup.json"
jq -n '{schema_version:1,kind:"gdc-reset-dai-backup",identity_present:false,signer_stopped:true,archive_path:"/srv/backup/reset-run-b-dai-backup.tar",archive_sha256:("b" * 64)}' >"$empty"
chmod 600 "$empty"
[[ "$(bash "$ROOT/scripts/resolve-reset-dai-backup.sh" "$reset_dir")" == "$metadata" ]]

printf 'wrong\n' >"$reset_dir/latest-identity.json"
chmod 600 "$reset_dir/latest-identity.json"
if bash "$ROOT/scripts/resolve-reset-dai-backup.sh" "$reset_dir" >/dev/null 2>&1; then
  echo 'tampered reset identity pointer unexpectedly accepted' >&2
  exit 1
fi

rm -f -- "$reset_dir/latest-identity.json"
legacy="$reset_dir/reset-dai-backup.json"
cp "$metadata" "$legacy"
chmod 600 "$legacy"
[[ "$(bash "$ROOT/scripts/resolve-reset-dai-backup.sh" "$reset_dir")" == "$legacy" ]]

printf 'PASS reset archive resolution retains only identity-bearing recovery authority\n'
