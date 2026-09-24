#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

# Recovery evidence must be published without replacement.  A race or an
# interrupted reset may leave a previous archive authoritative; the next
# attempt must refuse rather than silently change those bytes.
grep -Fq 'ln "$stage/archive.tar" "$archive" || die' "$ROOT/scripts/same-host-restore.sh"
grep -Fq 'ln "$stage/archive.json" "$archive.json"' "$ROOT/scripts/same-host-restore.sh"
if grep -Fq 'mv "$stage/archive.tar" "$archive"' "$ROOT/scripts/same-host-restore.sh"; then
  echo 'reset archive publication still replaces the final recovery path' >&2
  exit 1
fi

# The remote side validates archive ownership, digest, machine, chain and
# consensus key. This fixture isolates the local restore fence: it must retain
# the greater of the archived and restored signing minima without exposing the
# archive on the command line or relying on the deleted deployment root.
printf '{"consensus_pubkey":"fixture-key"}\n' >"$tmp/identity.json"
printf '{"archive_path":"/srv/backup/reset-fixture-dai-backup.tar","archive_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n' >"$tmp/reset-metadata.json"
printf '{"height":"10","round":"0","step":0,"block_id":null}\n' >"$tmp/current-state"

export RESTORE_TEST_DIR="$tmp"
ssh() {
  local operation="${*: -1}"
  case "$operation" in
    *'--remote bind'*)
      cat >/dev/null
      printf '%s\n' '{"schema_version":1,"kind":"gdc-reset-dai-backup","signer_stopped":true,"signing_state":{"height":"42","round":"0","step":0,"block_id":null}}'
      ;;
    *'sudo -n cat'*priv_validator_state.json*) cat "$RESTORE_TEST_DIR/current-state" ;;
    *'sudo -n tee'*priv_validator_state.json*) cat >"$RESTORE_TEST_DIR/current-state" ;;
    *'sudo -n bash -s -- '*priv_validator_key.softsign*) cat >/dev/null; printf 'fixture-key\n' ;;
    *) printf 'unexpected mock SSH: %s\n' "$operation" >&2; return 99 ;;
  esac
}
export -f ssh

bash "$ROOT/scripts/same-host-restore.sh" bind fixture-validator "$tmp/identity.json" fixture-chain \
  "$tmp/reset-metadata.json" "$tmp/bound.json"
jq -e '.height == "42"' "$tmp/current-state" >/dev/null
printf '{"height":"50","round":"0","step":0,"block_id":null}\n' >"$tmp/current-state"
bash "$ROOT/scripts/same-host-restore.sh" bind fixture-validator "$tmp/identity.json" fixture-chain \
  "$tmp/reset-metadata.json" "$tmp/bound2.json"
jq -e '.height == "50"' "$tmp/current-state" >/dev/null
jq -e '.kind == "gdc-reset-dai-backup" and .signer_stopped == true' "$tmp/bound.json" >/dev/null

# A pre-flat Host stored the exact same material below per-Host roots. Its
# reset archive must normalize those roots without deleting the only signer
# before recovery evidence exists.
legacy_script="$tmp/same-host-restore-legacy.sh"
sed \
  -e "s#root=/srv/dai#root=$tmp/legacy/srv/dai#" \
  -e "s#backup_root=/srv/backup#backup_root=$tmp/legacy/srv/backup#" \
  -e 's/\[\[ \$EUID == 0 && "\$node" =~/[[ true \&\& "$node" =~/' \
  -e 's/ && "$(stat -c %u "\$backup_root")" == 0//' \
  -e 's/ && "$(stat -c %u "\$archive")" == 0//' \
  "$ROOT/scripts/same-host-restore.sh" >"$legacy_script"
chmod 700 "$legacy_script"
legacy_node=gdc-node0
legacy_root="$tmp/legacy/srv/dai"
mkdir -p "$tmp/legacy/bin" \
  "$legacy_root/identity/$legacy_node/p2p" \
  "$legacy_root/identity/$legacy_node/warm/keyring-file" \
  "$legacy_root/signer/$legacy_node/tmkms/secrets" \
  "$legacy_root/signer/$legacy_node/tmkms/state" \
  "$legacy_root/$legacy_node/inference/config"
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/legacy/bin/docker"
chmod 700 "$tmp/legacy/bin/docker"
printf '{"priv_key":{"type":"tendermint/PrivKeyEd25519","value":"fixture"}}\n' \
  >"$legacy_root/identity/$legacy_node/p2p/node_key.json"
printf 'warm fixture\n' >"$legacy_root/identity/$legacy_node/warm/keyring-file/key"
printf 'signer fixture\n' >"$legacy_root/signer/$legacy_node/tmkms/secrets/priv_validator_key.softsign"
printf 'kms fixture\n' >"$legacy_root/signer/$legacy_node/tmkms/secrets/kms-identity.key"
printf '{"block_id":null,"height":"0","round":"0","step":0}\n' \
  >"$legacy_root/signer/$legacy_node/tmkms/state/priv_validator_state.json"
printf 'chain_id = "fixture-chain"\n' >"$legacy_root/signer/$legacy_node/tmkms/tmkms.toml"
printf '{"chain_id":"fixture-chain"}\n' >"$legacy_root/$legacy_node/inference/config/genesis.json"
PATH="$tmp/legacy/bin:$PATH" bash "$legacy_script" --remote capture "$legacy_node" fixture-run \
  >"$tmp/legacy-metadata.json"
legacy_archive="$(jq -r .archive_path "$tmp/legacy-metadata.json")"
[[ "$legacy_archive" == "$tmp/legacy/srv/backup/reset-fixture-run-dai-backup.tar" ]]
tar -tf "$legacy_archive" | grep -Fx 'identity/p2p/node_key.json' >/dev/null
tar -tf "$legacy_archive" | grep -Fx 'signer/tmkms/secrets/priv_validator_key.softsign' >/dev/null
if tar -tf "$legacy_archive" | grep -Fq "$legacy_node"; then
  echo 'legacy reset archive retained a per-Host path instead of normalizing it' >&2
  exit 1
fi
jq -e '.chain_id == "fixture-chain" and .identity_present == true' "$tmp/legacy-metadata.json" >/dev/null
printf 'PASS reset archive fence preserves the highest signing minimum (SSH mocked)\n'
