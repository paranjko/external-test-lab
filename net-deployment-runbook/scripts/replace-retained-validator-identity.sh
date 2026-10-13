#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# == 2 ]] || { echo 'usage: replace-retained-validator-identity.sh NODE RUN_ID' >&2; exit 2; }
node="$1"
run_id="$2"
root="${GDC_REMOTE_IDENTITY_ROOT:-/srv/dai}"
[[ "$node" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo 'invalid validator alias' >&2; exit 2; }
[[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || { echo 'invalid JOIN run identifier' >&2; exit 2; }
[[ "$root" == /* && -d "$root" && ! -L "$root" ]] || { echo 'invalid validator identity root' >&2; exit 2; }

identity="$root/identity"
signer="$root/signer"
bootstrap="$root/identity-bootstrap/$node.json"
archive_dir="$root/rejoin/$node"
archive="$archive_dir/replaced-$run_id.tar"
receipt="$archive_dir/replaced-$run_id.json"
[[ ! -L "$root/identity" && ! -L "$root/signer" && ! -L "$root/identity-bootstrap" && ! -L "$root/rejoin" \
    && ! -L "$identity" && ! -L "$signer" && ! -L "$archive_dir" ]] \
  || { echo 'validator identity replacement refuses symlinked state roots' >&2; exit 1; }
install -d -m 0700 "$archive_dir"
[[ -d "$archive_dir" && ! -L "$archive_dir" ]] \
  || { echo 'invalid validator identity archive directory' >&2; exit 1; }

write_receipt() {
  local archive_sha256="$1" receipt_tmp
  receipt_tmp="$(mktemp "$archive_dir/.replaced-$run_id.receipt.XXXXXX")"
  jq -cn --arg node "$node" --arg run_id "$run_id" --arg archive "$archive" \
    --arg archive_sha256 "$archive_sha256" \
    '{schema_version:1,kind:"gdc-retained-validator-identity-replacement",node_name:$node,run_id:$run_id,archive:$archive,archive_sha256:$archive_sha256,signer_was_running:false,identity_removed:true}' \
    >"$receipt_tmp"
  chmod 0600 "$receipt_tmp"
  mv -- "$receipt_tmp" "$receipt"
}

if [[ -s "$receipt" ]]; then
  [[ -s "$archive" && ! -e "$identity" && ! -e "$signer" ]] \
    || { echo 'retained validator identity replacement receipt contradicts Host state' >&2; exit 1; }
  archive_sha256="$(sha256sum "$archive" | awk '{print $1}')"
  jq -e --arg node "$node" --arg run_id "$run_id" --arg archive "$archive" --arg sha "$archive_sha256" '
    .schema_version == 1 and .kind == "gdc-retained-validator-identity-replacement" and
    .node_name == $node and .run_id == $run_id and .archive == $archive and
    .archive_sha256 == $sha and .signer_was_running == false and .identity_removed == true
  ' "$receipt" >/dev/null || { echo 'retained validator identity replacement receipt is invalid' >&2; exit 1; }
  cat "$receipt"
  exit 0
fi

if [[ -s "$archive" ]]; then
  [[ ! -e "$identity" && ! -e "$signer" ]] \
    || { echo 'retained validator identity archive exists beside active identity state' >&2; exit 1; }
  archive_sha256="$(sha256sum "$archive" | awk '{print $1}')"
  write_receipt "$archive_sha256"
  cat "$receipt"
  exit 0
fi

[[ -s "$identity/p2p/node_key.json" && -s "$signer/tmkms/secrets/priv_validator_key.softsign" ]] \
  || { echo 'retained validator identity is incomplete' >&2; exit 1; }
running_signer="$(docker ps -q \
    --filter "label=com.docker.compose.project=$node" \
    --filter 'label=com.docker.compose.service=tmkms')" \
  || { echo 'retained validator signer state cannot be verified' >&2; exit 1; }
if [[ -n "$running_signer" ]]; then
  echo 'retained validator signer is still running' >&2
  exit 1
fi

archive_tmp="$(mktemp "$archive_dir/.replaced-$run_id.XXXXXX")"
trap 'rm -f -- "$archive_tmp"' EXIT

members=(identity signer)
[[ ! -f "$bootstrap" || -L "$bootstrap" ]] || members+=("identity-bootstrap/$node.json")
tar -C "$root" -cf "$archive_tmp" "${members[@]}"
chmod 0600 "$archive_tmp"
archive_sha256="$(sha256sum "$archive_tmp" | awk '{print $1}')"
mv -- "$archive_tmp" "$archive"
trap - EXIT

rm -rf -- "$identity" "$signer"
rm -f -- "$bootstrap"
write_receipt "$archive_sha256"
cat "$receipt"
