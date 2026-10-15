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

# Capture and bind canonical Host identity without migration
fixture_script="$tmp/same-host-restore-canonical.sh"
sed \
  -e "s#root=/srv/dai#root=$tmp/capture/srv/dai#" \
  -e "s#backup_root=/srv/backup#backup_root=$tmp/capture/srv/backup#" \
  -e "s#\^/srv/backup#\^$tmp/capture/srv/backup#g" \
  -e 's/\[\[ \$EUID == 0 && "\$node" =~/[[ true \&\& "$node" =~/' \
  -e 's/ && "$(stat -c %u "\$backup_root")" == 0//' \
  -e 's/ && "$(stat -c %u "\$archive")" == 0//' \
  "$ROOT/scripts/same-host-restore.sh" >"$fixture_script"
chmod 700 "$fixture_script"
fixture_node=gdc-node0
fixture_root="$tmp/capture/srv/dai"
mkdir -p "$tmp/capture/bin" \
  "$fixture_root/identity/p2p" \
  "$fixture_root/identity/warm/keyring-file" \
  "$fixture_root/signer/tmkms/secrets" \
  "$fixture_root/signer/tmkms/state" \
  "$fixture_root/data/config"
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/capture/bin/docker"
chmod 700 "$tmp/capture/bin/docker"
printf '{"priv_key":{"type":"tendermint/PrivKeyEd25519","value":"fixture"}}\n' \
  >"$fixture_root/identity/p2p/node_key.json"
printf 'warm fixture\n' >"$fixture_root/identity/warm/keyring-file/key"
printf 'signer fixture\n' >"$fixture_root/signer/tmkms/secrets/priv_validator_key.softsign"
printf 'kms fixture\n' >"$fixture_root/signer/tmkms/secrets/kms-identity.key"
printf '{"block_id":null,"height":"0","round":"0","step":0}\n' \
  >"$fixture_root/signer/tmkms/state/priv_validator_state.json"
printf 'chain_id = "fixture-chain"\n' >"$fixture_root/signer/tmkms/tmkms.toml"
printf '{"chain_id":"fixture-chain"}\n' >"$fixture_root/data/config/genesis.json"
PATH="$tmp/capture/bin:$PATH" bash "$fixture_script" --remote capture "$fixture_node" fixture-run \
  >"$tmp/capture-metadata.json"
fixture_archive="$(jq -r .archive_path "$tmp/capture-metadata.json")"
[[ "$fixture_archive" == "$tmp/capture/srv/backup/reset-fixture-run-dai-backup.tar" ]]
tar -tf "$fixture_archive" | grep -Fx 'identity/p2p/node_key.json' >/dev/null
tar -tf "$fixture_archive" | grep -Fx 'signer/tmkms/secrets/priv_validator_key.softsign' >/dev/null
jq -e '.chain_id == "fixture-chain" and .identity_present == true' "$tmp/capture-metadata.json" >/dev/null
printf 'PASS reset archive fence preserves the highest signing minimum (SSH mocked)\n'

# A partial JOIN can leave only TMKMS identity material. Its explicit
# chain_id remains enough to bind the reset archive without deploy/.env or
# genesis, so reset can preserve the signer before clearing /srv/dai.
rm -f -- "$fixture_root/data/config/genesis.json"
PATH="$tmp/capture/bin:$PATH" bash "$fixture_script" --remote capture "$fixture_node" tmkms-chain \
  >"$tmp/tmkms-chain-metadata.json"
jq -e '.chain_id == "fixture-chain" and .identity_present == true' "$tmp/tmkms-chain-metadata.json" >/dev/null
printf 'PASS reset capture falls back to the retained TMKMS chain binding\n'

# If every chain binding has disappeared, reset still preserves the signer
# externally and clears the Host. The null binding deliberately cannot later
# select the automatic same-Host restore path.
rm -f -- "$fixture_root/signer/tmkms/tmkms.toml"
PATH="$tmp/capture/bin:$PATH" bash "$fixture_script" --remote capture "$fixture_node" unbound \
  >"$tmp/unbound-metadata.json"
jq -e '.chain_id == null and .identity_present == true' "$tmp/unbound-metadata.json" >/dev/null
[[ -f "$(jq -r .archive_path "$tmp/unbound-metadata.json")" ]]
printf 'PASS reset preserves an unbound signer without authorizing automatic restore\n'

# The current flat reset path must accept both never-signed forms, but refuse
# malformed state before publishing recovery authority or permitting removal.
mkdir -p "$fixture_root/deploy"
printf 'CHAIN_ID=fixture-chain\n' >"$fixture_root/deploy/.env"
for parts in parts part_set_header; do
  printf '{"height":"0","round":"0","step":0,"block_id":{"hash":"","%s":{"total":0,"hash":""}}}\n' "$parts" \
    >"$fixture_root/signer/tmkms/state/priv_validator_state.json"
  PATH="$tmp/capture/bin:$PATH" bash "$fixture_script" --remote capture "$fixture_node" "flat-$parts" \
    >"$tmp/flat-$parts.json"
  jq -e '.identity_present == true and .signing_state.height == "0"' "$tmp/flat-$parts.json" >/dev/null
done
printf '{"height":"0","round":0,"step":0,"block_id":null}\n' \
  >"$fixture_root/signer/tmkms/state/priv_validator_state.json"
if PATH="$tmp/capture/bin:$PATH" bash "$fixture_script" --remote capture "$fixture_node" malformed \
    >"$tmp/malformed.out" 2>"$tmp/malformed.err"; then
  echo 'reset capture accepted malformed signing state' >&2; exit 1
fi
grep -Fq 'validator signing state is malformed' "$tmp/malformed.err"
[[ ! -e "$tmp/capture/srv/backup/reset-malformed-dai-backup.tar" ]]
[[ -s "$fixture_root/signer/tmkms/secrets/priv_validator_key.softsign" ]]
printf 'PASS flat reset validates signing state before publishing its external archive\n'

# A reset archive for another signer is invalid operator recovery input. It
# has a distinct data-error exit so the JOIN launcher does not report it as a
# Host incident; any transport or archive failure keeps its ordinary error.
mismatch_archive="$tmp/capture/srv/backup/reset-mismatch-dai-backup.tar"
cat >"$mismatch_archive.json" <<'EOF'
{"schema_version":1,"kind":"gdc-reset-dai-backup","machine_sha256":"different-machine","key_sha256":"different-key","chain_id":"fixture-chain","signer_stopped":true,"signing_state":{"height":"0","round":"0","step":0,"block_id":null},"archive_path":"PLACEHOLDER","archive_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
EOF
sed -i "s#PLACEHOLDER#$mismatch_archive#" "$mismatch_archive.json"
rc=0
PATH="$tmp/capture/bin:$PATH" bash "$fixture_script" --remote bind "$fixture_node" fixture-chain "$mismatch_archive" \
  >"$tmp/mismatch.out" 2>"$tmp/mismatch.err" || rc=$?
[[ "$rc" == 65 ]]
grep -Fq 'reset archive does not match restored signer identity' "$tmp/mismatch.err"
printf 'PASS reset archive identity mismatch returns the dedicated data-error exit\n'

# Retired identity roots must stop capture before Docker or archive mutation
mkdir -p "$fixture_root/identity/$fixture_node"
printf 'retained key\n' >"$fixture_root/identity/$fixture_node/sentinel"
printf '#!/usr/bin/env bash\nexit 99\n' >"$tmp/capture/bin/docker"
if PATH="$tmp/capture/bin:$PATH" bash "$fixture_script" --remote capture "$fixture_node" retired >"$tmp/retired.out" 2>"$tmp/retired.err"; then
  echo 'retired identity layout accepted' >&2; exit 1
fi
grep -Fq 'legacy validator identity layout is unsupported' "$tmp/retired.err"
[[ ! -e "$tmp/capture/srv/backup/reset-retired-dai-backup.tar" ]]
[[ "$(cat "$fixture_root/identity/$fixture_node/sentinel")" == 'retained key' ]]
printf 'PASS retired identity layout refused before capture and reset\n'
