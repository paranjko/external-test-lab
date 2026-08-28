#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP="$ROOT/scripts/validator-backup.sh"
RUNNING_RECOVERY="$ROOT/scripts/recover-running-host-state.sh"
RECOVERY_EVALUATOR="$ROOT/scripts/evaluate-running-host-recovery.sh"
DEPLOYMENT_SECRET_RECOVERY="$ROOT/scripts/recover-running-host-deployment-secrets.sh"
REMOTE_IDENTITY_RESTORE="$ROOT/scripts/restore-validator-identity-remote.sh"
TMKMS_PUBLIC_KEY="$ROOT/scripts/tmkms-softsign-public-key.sh"
MNEMONIC_IDENTITY="$ROOT/scripts/derive-mnemonic-identity.sh"
REMOTE_RESTORE_COMMAND="$ROOT/scripts/build-validator-identity-restore-command.sh"

bash -n "$BACKUP" "$RUNNING_RECOVERY" "$RECOVERY_EVALUATOR" "$DEPLOYMENT_SECRET_RECOVERY" \
  "$REMOTE_IDENTITY_RESTORE" "$REMOTE_RESTORE_COMMAND" "$TMKMS_PUBLIC_KEY" "$MNEMONIC_IDENTITY" \
  "$ROOT/gdc.sh" "$ROOT/scripts/phase-join.sh" "$ROOT/scripts/phase-genesis.sh" \
  "$ROOT/01-identities-genesis/collect-identities.sh" "$ROOT/02-node/init-identity.sh" \
  "$ROOT/03-join/grant-ml-ops.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
secret_canary='VALIDATOR_ARCHIVE_SECRET_CANARY_51'

# Execute the production mnemonic validator through the host awk. Fixtures are
# synthetic, outputs are captured, and diagnostics must never echo their words.
mnemonic_word='syntheticword'
awk -v word="$mnemonic_word" 'BEGIN {
  for (i = 1; i <= 24; i++) printf "%s%s", (i == 1 ? "" : " "), word
  print ""
}' >"$tmp/valid.mnemonic"
GDC_VALIDATOR_BACKUP_TEST_MODE=true "$BACKUP" validate-mnemonic \
  "$tmp/valid.mnemonic" >"$tmp/valid-mnemonic.out" 2>"$tmp/valid-mnemonic.err"
[[ ! -s "$tmp/valid-mnemonic.out" && ! -s "$tmp/valid-mnemonic.err" ]]

awk -v word="$mnemonic_word" 'BEGIN {
  for (i = 1; i <= 23; i++) printf "%s%s", (i == 1 ? "" : " "), word
  print ""
}' >"$tmp/short.mnemonic"
cp "$tmp/valid.mnemonic" "$tmp/multiline.mnemonic"
printf '%s\n' "$mnemonic_word" >>"$tmp/multiline.mnemonic"
for mnemonic_case in short multiline; do
  if GDC_VALIDATOR_BACKUP_TEST_MODE=true "$BACKUP" validate-mnemonic \
    "$tmp/$mnemonic_case.mnemonic" >"$tmp/$mnemonic_case-mnemonic.out" \
    2>"$tmp/$mnemonic_case-mnemonic.err"; then
    echo "malformed synthetic mnemonic was accepted: $mnemonic_case" >&2
    exit 1
  fi
  grep -Fq 'validator backup contains malformed account recovery material' \
    "$tmp/$mnemonic_case-mnemonic.err"
  ! grep -Fq "$mnemonic_word" "$tmp/$mnemonic_case-mnemonic.out" \
    "$tmp/$mnemonic_case-mnemonic.err"
done

if bash -x "$MNEMONIC_IDENTITY" "$tmp/$secret_canary.mnemonic" \
  "$tmp/$secret_canary.password" recovery-key \
  gonka1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq \
  >"$tmp/mnemonic-xtrace.out" 2>"$tmp/mnemonic-xtrace.err"; then
  echo 'missing mnemonic xtrace fixture unexpectedly succeeded' >&2
  exit 1
fi
! grep -Fq "$secret_canary" "$tmp/mnemonic-xtrace.out" "$tmp/mnemonic-xtrace.err"
if bash -x "$TMKMS_PUBLIC_KEY" "$tmp/$secret_canary.softsign" \
  >"$tmp/tmkms-xtrace.out" 2>"$tmp/tmkms-xtrace.err"; then
  echo 'missing TMKMS xtrace fixture unexpectedly succeeded' >&2
  exit 1
fi
! grep -Fq "$secret_canary" "$tmp/tmkms-xtrace.out" "$tmp/tmkms-xtrace.err"

cat >"$tmp/make-archive.py" <<'PY'
import hashlib
import io
import sys
import tarfile

case, output, canary = sys.argv[1:]

remote_dirs = ['tmkms', 'tmkms/secrets', 'tmkms/state', 'inference', 'inference/config']
remote_files = {
    'tmkms/tmkms.toml': b'config\n',
    'tmkms/secrets/priv_validator_key.softsign': b'key\n',
    'tmkms/secrets/kms-identity.key': b'identity\n',
    'tmkms/state/priv_validator_state.json': b'{}\n',
    'inference/config/node_key.json': b'{}\n',
}

def directory(name):
    member = tarfile.TarInfo(name)
    member.type = tarfile.DIRTYPE
    member.mode = 0o700
    return member, None

def regular(name, data):
    member = tarfile.TarInfo(name)
    member.size = len(data)
    member.mode = 0o600
    return member, io.BytesIO(data)

def symlink(name, target):
    member = tarfile.TarInfo(name)
    member.type = tarfile.SYMTYPE
    member.linkname = target
    return member, None

if case == 'malformed':
    with open(output, 'wb') as target:
        target.write(canary.encode('ascii'))
    sys.exit(0)

members = [directory(path) for path in remote_dirs]
members += [regular(path, data) for path, data in remote_files.items()]
if case == 'missing':
    members = [item for item in members if item[0].name != 'inference/config/node_key.json']
elif case == 'wrong-type':
    members = [item for item in members if item[0].name != 'inference/config/node_key.json']
    members.append(directory('inference/config/node_key.json'))
elif case == 'duplicate':
    members.append(regular('inference/config/node_key.json', b'duplicate\n'))
elif case == 'traversal':
    members.append(regular(f'tmkms/../{canary}', b'secret body\n'))
elif case == 'symlink':
    members.append(symlink('tmkms/secret-link', f'/{canary}'))
elif case == 'secret-redaction':
    members.append(regular(canary, canary.encode('ascii')))
elif case in ('duplicate-control', 'ambiguous-checksum'):
    prefixed = []
    for path in remote_dirs:
        prefixed.append(directory(f'remote-state/{path}'))
    for path, data in remote_files.items():
        prefixed.append(regular(f'remote-state/{path}', data))
    controls = {
        'manifest.json': b'{}\n',
        'identity.json': b'{}\n',
        'mnemonics/gdc-node1-cold.mnemonic': b'word\n',
        'mnemonics/gdc-node1-warm.mnemonic': b'word\n',
    }
    checksum_lines = []
    for path, data in {**controls, **{f'remote-state/{k}': v for k, v in remote_files.items()}}.items():
        checksum_lines.append(f'{hashlib.sha256(data).hexdigest()}  {path}\n')
    if case == 'ambiguous-checksum':
        checksum_lines.append(f'{"0" * 64}  ../{canary}\n')
    controls['manifest.sha256'] = ''.join(checksum_lines).encode('ascii')
    members = [directory('mnemonics'), directory('remote-state')] + prefixed
    members += [regular(path, data) for path, data in controls.items()]
    if case == 'duplicate-control':
        members.append(regular('identity.json', canary.encode('ascii')))

with tarfile.open(output, 'w') as archive:
    for member, body in members:
        archive.addfile(member, body)
PY

declare -a archive_cases=(malformed missing wrong-type duplicate traversal symlink secret-redaction)
for test_case in "${archive_cases[@]}"; do
  python3 "$tmp/make-archive.py" "$test_case" "$tmp/$test_case.tar" "$secret_canary"
  if GDC_VALIDATOR_BACKUP_TEST_MODE=true "$BACKUP" inspect-archive remote-state \
    "$tmp/$test_case.tar" "$tmp/extract-$test_case" gdc-node1 \
    >"$tmp/$test_case.out" 2>"$tmp/$test_case.err"; then
    echo "unsafe remote identity archive was accepted: $test_case" >&2
    exit 1
  fi
  ! grep -Fq "$secret_canary" "$tmp/$test_case.out" "$tmp/$test_case.err"
done

# Archive and trailing-padding limits are checked from file metadata before
# member bodies are copied. Sparse padding keeps this regression lightweight.
python3 "$tmp/make-archive.py" valid "$tmp/valid-remote-state.tar" "$secret_canary"
GDC_VALIDATOR_BACKUP_TEST_MODE=true "$BACKUP" inspect-archive remote-state \
  "$tmp/valid-remote-state.tar" "$tmp/extract-valid" gdc-node1
archive_end_offset="$(python3 - "$tmp/valid-remote-state.tar" <<'PY'
import sys
import tarfile

with tarfile.open(sys.argv[1], mode='r:') as archive:
    for _ in archive:
        pass
    print(archive.offset)
PY
)"
[[ "$archive_end_offset" =~ ^[1-9][0-9]*$ ]]
max_trailing_padding=$((1024 * 1024))
max_archive_size=$((66 * 1024 * 1024))

cp "$tmp/valid-remote-state.tar" "$tmp/trailing-padding-boundary.tar"
truncate -s $((archive_end_offset + max_trailing_padding)) \
  "$tmp/trailing-padding-boundary.tar"
GDC_VALIDATOR_BACKUP_TEST_MODE=true "$BACKUP" inspect-archive remote-state \
  "$tmp/trailing-padding-boundary.tar" "$tmp/extract-trailing-boundary" gdc-node1

cp "$tmp/valid-remote-state.tar" "$tmp/trailing-padding-overflow.tar"
truncate -s $((archive_end_offset + max_trailing_padding + 512)) \
  "$tmp/trailing-padding-overflow.tar"
if GDC_VALIDATOR_BACKUP_TEST_MODE=true "$BACKUP" inspect-archive remote-state \
  "$tmp/trailing-padding-overflow.tar" "$tmp/extract-trailing-overflow" gdc-node1 \
  >"$tmp/trailing-overflow.out" 2>"$tmp/trailing-overflow.err"; then
  echo 'archive above the trailing padding boundary was accepted' >&2
  exit 1
fi
[[ ! -e "$tmp/extract-trailing-overflow" ]]

cp "$tmp/valid-remote-state.tar" "$tmp/oversized-sparse.tar"
truncate -s $((max_archive_size + 512)) "$tmp/oversized-sparse.tar"
if GDC_VALIDATOR_BACKUP_TEST_MODE=true "$BACKUP" inspect-archive remote-state \
  "$tmp/oversized-sparse.tar" "$tmp/extract-oversized-sparse" gdc-node1 \
  >"$tmp/oversized-sparse.out" 2>"$tmp/oversized-sparse.err"; then
  echo 'oversized sparse validator archive was accepted' >&2
  exit 1
fi
[[ "$(stat -c %s "$tmp/oversized-sparse.tar")" == $((max_archive_size + 512)) ]]
[[ ! -e "$tmp/extract-oversized-sparse" ]]

for test_case in duplicate-control ambiguous-checksum; do
  python3 "$tmp/make-archive.py" "$test_case" "$tmp/$test_case.tar" "$secret_canary"
  if GDC_VALIDATOR_BACKUP_TEST_MODE=true "$BACKUP" inspect-archive backup \
    "$tmp/$test_case.tar" "$tmp/extract-$test_case" gdc-node1 \
    >"$tmp/$test_case.out" 2>"$tmp/$test_case.err"; then
    echo "ambiguous backup control archive was accepted: $test_case" >&2
    exit 1
  fi
  ! grep -Fq "$secret_canary" "$tmp/$test_case.out" "$tmp/$test_case.err"
done

material="$tmp/material-valid"
install -d -m 0700 "$material/tmkms/secrets" "$material/tmkms/state" "$material/inference/config"
printf '01234567890123456789012345678901' | base64 >"$material/tmkms/secrets/priv_validator_key.softsign"
consensus_key="$("$TMKMS_PUBLIC_KEY" "$material/tmkms/secrets/priv_validator_key.softsign")"
printf 'abcdefghijklmnopqrstuvwxyzABCDEF' | base64 >"$material/tmkms/secrets/kms-identity.key"
cat >"$material/tmkms/tmkms.toml" <<'EOF'
[[chain]]
id = "test-chain"
state_file = "/root/.tmkms/state/priv_validator_state.json"
[[providers.softsign]]
chain_ids = ["test-chain"]
key_type = "consensus"
path = "/root/.tmkms/secrets/priv_validator_key.softsign"
[[validator]]
chain_id = "test-chain"
addr = "tcp://node:26658"
secret_key = "/root/.tmkms/secrets/kms-identity.key"
protocol_version = "v0.34"
EOF
jq -n '{height:"10",round:"0",step:6,block_id:{hash:("A" * 64),
  part_set_header:{total:1,hash:("B" * 64)}}}' \
  >"$material/tmkms/state/priv_validator_state.json"
printf '12345678901234567890123456789012' | base64 >"$tmp/node-seed.base64"
node_public="$("$TMKMS_PUBLIC_KEY" "$tmp/node-seed.base64")"
node_id="$(printf '%s' "$node_public" | base64 -d | sha256sum | cut -c1-40)"
base64 -d "$tmp/node-seed.base64" >"$tmp/node-key.raw"
printf '%s' "$node_public" | base64 -d >>"$tmp/node-key.raw"
node_private="$(base64 <"$tmp/node-key.raw" | tr -d '\n')"
jq -n --arg value "$node_private" \
  '{priv_key:{type:"tendermint/PrivKeyEd25519",value:$value}}' \
  >"$material/inference/config/node_key.json"
warm_public="$(printf '123456789012345678901234567890123' | base64 | tr -d '\n')"
jq -n --arg consensus "$consensus_key" --arg warm "$warm_public" --arg node_id "$node_id" \
  '{node_name:"gdc-node1",node_id:$node_id,consensus_pubkey:$consensus,warm_address:"gonka1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq",warm_pubkey_b64:$warm}' \
  >"$tmp/identity.json"

printf 'abcdefghijklmnopqrstuvwxzy123456' | base64 >"$tmp/other-node-seed.base64"
other_node_public="$("$TMKMS_PUBLIC_KEY" "$tmp/other-node-seed.base64")"
base64 -d "$tmp/other-node-seed.base64" >"$tmp/other-node-key.raw"
printf '%s' "$other_node_public" | base64 -d >>"$tmp/other-node-key.raw"
other_node_private="$(base64 <"$tmp/other-node-key.raw" | tr -d '\n')"
jq -n --arg value "$other_node_private" \
  '{priv_key:{type:"tendermint/PrivKeyEd25519",value:$value}}' \
  >"$tmp/other-node-key.json"

# Schema v1 permits exactly the original manifest key set and the later key set
# with ml_host. No other omission, extension, or malformed ml_host is accepted.
jq -n --slurpfile identity "$tmp/identity.json" '
  {schema_version:1,node_name:"gdc-node1",created_at:"2026-08-20T12:00:00Z",
   chain_id:"test-chain",genesis_sha256:("a" * 64),
   participant_address:"gonka1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq",
   identity:$identity[0]}
' >"$tmp/manifest-without-ml-host.json"
GDC_VALIDATOR_BACKUP_TEST_MODE=true "$BACKUP" validate-manifest \
  "$tmp/manifest-without-ml-host.json" "$tmp/identity.json" gdc-node1

jq '.ml_host = null' "$tmp/manifest-without-ml-host.json" >"$tmp/manifest-null-ml-host.json"
GDC_VALIDATOR_BACKUP_TEST_MODE=true "$BACKUP" validate-manifest \
  "$tmp/manifest-null-ml-host.json" "$tmp/identity.json" gdc-node1
jq '.ml_host = "gdc-node1-ml"' "$tmp/manifest-without-ml-host.json" \
  >"$tmp/manifest-split-ml-host.json"
GDC_VALIDATOR_BACKUP_TEST_MODE=true "$BACKUP" validate-manifest \
  "$tmp/manifest-split-ml-host.json" "$tmp/identity.json" gdc-node1

declare -a manifest_cases=(extra-key missing-chain malformed-ml-host wrong-ml-host-type)
for test_case in "${manifest_cases[@]}"; do
  case "$test_case" in
    extra-key) jq '.legacy = true' "$tmp/manifest-without-ml-host.json" ;;
    missing-chain) jq 'del(.chain_id)' "$tmp/manifest-without-ml-host.json" ;;
    malformed-ml-host) jq '.ml_host = "bad alias"' "$tmp/manifest-without-ml-host.json" ;;
    wrong-ml-host-type) jq '.ml_host = 7' "$tmp/manifest-without-ml-host.json" ;;
  esac >"$tmp/manifest-$test_case.json"
  if GDC_VALIDATOR_BACKUP_TEST_MODE=true "$BACKUP" validate-manifest \
    "$tmp/manifest-$test_case.json" "$tmp/identity.json" gdc-node1 \
    >"$tmp/manifest-$test_case.out" 2>"$tmp/manifest-$test_case.err"; then
    echo "malformed validator backup manifest was accepted: $test_case" >&2
    exit 1
  fi
  grep -Fq 'validator backup manifest metadata is malformed or inconsistent' \
    "$tmp/manifest-$test_case.err"
done

GDC_VALIDATOR_BACKUP_TEST_MODE=true "$BACKUP" validate-material \
  "$material" "$tmp/identity.json" gdc-node1 test-chain

declare -a material_cases=(
  malformed-softsign
  malformed-kms
  missing-state
  wrong-type-node
  malformed-state
  state-total-float
  state-total-negative
  state-total-overflow
  state-total-wrong-type
  inconsistent-expanded-key
  malformed-config
  mismatched-node-key
  mismatched-node-id
)
for test_case in "${material_cases[@]}"; do
  candidate="$tmp/material-$test_case"
  test_identity="$tmp/identity-$test_case.json"
  cp -a "$material" "$candidate"
  cp "$tmp/identity.json" "$test_identity"
  case "$test_case" in
    malformed-softsign) printf '%s\n' "$secret_canary" >"$candidate/tmkms/secrets/priv_validator_key.softsign" ;;
    malformed-kms) printf '%s\n' "$secret_canary" >"$candidate/tmkms/secrets/kms-identity.key" ;;
    missing-state) rm -f "$candidate/tmkms/state/priv_validator_state.json" ;;
    wrong-type-node)
      rm -f "$candidate/inference/config/node_key.json"
      mkdir "$candidate/inference/config/node_key.json"
      ;;
    malformed-state) printf '{"signature":"%s"}\n' "$secret_canary" >"$candidate/tmkms/state/priv_validator_state.json" ;;
    state-total-float)
      jq '.block_id.part_set_header.total = 1.5' "$material/tmkms/state/priv_validator_state.json" \
        >"$candidate/tmkms/state/priv_validator_state.json"
      ;;
    state-total-negative)
      jq '.block_id.part_set_header.total = -1' "$material/tmkms/state/priv_validator_state.json" \
        >"$candidate/tmkms/state/priv_validator_state.json"
      ;;
    state-total-overflow)
      jq '.block_id.part_set_header.total = 4294967296' "$material/tmkms/state/priv_validator_state.json" \
        >"$candidate/tmkms/state/priv_validator_state.json"
      ;;
    state-total-wrong-type)
      jq '.block_id.part_set_header.total = "1"' "$material/tmkms/state/priv_validator_state.json" \
        >"$candidate/tmkms/state/priv_validator_state.json"
      ;;
    inconsistent-expanded-key)
      base64 -d "$material/tmkms/secrets/priv_validator_key.softsign" >"$tmp/expanded.raw"
      printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' >>"$tmp/expanded.raw"
      base64 <"$tmp/expanded.raw" >"$candidate/tmkms/secrets/priv_validator_key.softsign"
      ;;
    malformed-config) printf '# %s\n' "$secret_canary" >"$candidate/tmkms/tmkms.toml" ;;
    mismatched-node-key)
      cp "$tmp/other-node-key.json" "$candidate/inference/config/node_key.json"
      ;;
    mismatched-node-id)
      jq '.node_id = "0000000000000000000000000000000000000000"' "$tmp/identity.json" \
        >"$test_identity"
      ;;
  esac
  if GDC_VALIDATOR_BACKUP_TEST_MODE=true "$BACKUP" validate-material \
    "$candidate" "$test_identity" gdc-node1 test-chain \
    >"$tmp/material-$test_case.out" 2>"$tmp/material-$test_case.err"; then
    echo "malformed validator material was accepted: $test_case" >&2
    exit 1
  fi
  case "$test_case" in
    state-total-*)
      grep -Fq 'validator backup contains malformed TMKMS signing state' \
        "$tmp/material-$test_case.err"
      ;;
    mismatched-node-key|mismatched-node-id)
      grep -Fq 'validator backup P2P node key does not match its recorded node identity' \
        "$tmp/material-$test_case.err"
      ;;
  esac
  ! grep -Fq "$secret_canary" "$tmp/material-$test_case.out" "$tmp/material-$test_case.err"
done

grep -Fq -- '--restore)' "$ROOT/gdc.sh"
grep -Fq 'GDC_RESTORE_VALIDATOR_BACKUP_ARCHIVE' "$ROOT/gdc.sh"
grep -Fq 'validator-backup.sh" restore' "$ROOT/scripts/phase-join.sh"
grep -Fq 'recover-running-host-state.sh" "$NODE"' "$ROOT/scripts/phase-join.sh"
grep -Fq 'validator-backup.sh" create' "$ROOT/scripts/phase-join.sh"
grep -Fq 'validator-backup.sh" create' "$ROOT/scripts/phase-genesis.sh"
grep -Fq 'topology_contains_node "$2" || die "unknown SSH alias: $2"' "$BACKUP"
grep -Fq 'create_backup "$2"' "$BACKUP"
grep -Fq 'configured_gpu="$(node_ml_host "$node" || true)"' "$BACKUP"
! grep -Fq 'create_backup "$(node_name "$2")"' "$BACKUP"
grep -Fq 'refusing to create a duplicate participant' "$ROOT/scripts/phase-join.sh"
grep -Fq 'cold and warm mnemonics alone cannot restore it' "$ROOT/scripts/phase-join.sh"
participant_check_line="$(grep -n 'participant already exists on this chain' "$ROOT/scripts/phase-join.sh" | head -n1 | cut -d: -f1)"
identity_bootstrap_line="$(grep -n 'collect-identities.sh' "$ROOT/scripts/phase-join.sh" | head -n1 | cut -d: -f1)"
[[ "$participant_check_line" -lt "$identity_bootstrap_line" ]] || {
  echo 'existing participant recovery check must precede identity bootstrap' >&2
  exit 1
}
acceptance_line="$(grep -n 'phase-join-acceptance.sh' "$ROOT/scripts/phase-join.sh" | tail -n1 | cut -d: -f1)"
backup_line="$(grep -n 'validator-backup.sh" create' "$ROOT/scripts/phase-join.sh" | tail -n1 | cut -d: -f1)"
[[ "$backup_line" -lt "$acceptance_line" ]]
genesis_acceptance_line="$(grep -n 'phase-join-acceptance.sh' "$ROOT/scripts/phase-genesis.sh" | tail -n1 | cut -d: -f1)"
genesis_backup_line="$(grep -n 'validator-backup.sh" create' "$ROOT/scripts/phase-genesis.sh" | tail -n1 | cut -d: -f1)"
[[ "$genesis_backup_line" -gt "$genesis_acceptance_line" ]]
grep -Fq 'keys add "$KEY_NAME" --recover --keyring-backend file' "$ROOT/02-node/init-identity.sh"
grep -Fq -- '--warm-mnemonic' "$ROOT/01-identities-genesis/collect-identities.sh"
grep -Fq 'verify_checksum_manifest "$extracted"' "$BACKUP"
grep -Fq 'MAX_VALIDATOR_BACKUP_ARCHIVE_BYTES=$((66 * 1024 * 1024))' "$BACKUP"
grep -Fq 'MAX_VALIDATOR_BACKUP_TRAILING_BYTES=$((1024 * 1024))' "$BACKUP"
grep -Fq 'raw_archive.read(min(TRAILING_READ_SIZE, remaining))' "$BACKUP"
! grep -Fq 'install -m 0600 "$archive" "$stage/input.tar"' "$BACKUP"
grep -Fq 'sudo env GDC_VALIDATOR_IDENTITY_REMOTE=true bash -s --' "$REMOTE_RESTORE_COMMAND"
grep -Fq 'tmkms-softsign-public-key.sh' "$BACKUP"
grep -Fq 'build-validator-identity-restore-command.sh' "$BACKUP"
grep -Fq 'validator backup contains an invalid consensus public key' "$REMOTE_RESTORE_COMMAND"
grep -Fq "printf ' %q'" "$REMOTE_RESTORE_COMMAND"
grep -Fq 'ssh -T "$node"' "$BACKUP"
grep -Fq 'sudo tar -C \"\$state\" -cf -' "$BACKUP"
! grep -Fq 'validator-backup-$$.tar' "$BACKUP"
grep -Fq '"$remote_restore_command"' "$BACKUP"
grep -Fq '<"$ROOT/scripts/build-validator-identity-restore-command.sh"' "$BACKUP"
grep -Fq '.gdc-validator-identity-restore.sha256' "$REMOTE_RESTORE_COMMAND"
grep -Fq 'mv "$transaction" "$state"' "$REMOTE_RESTORE_COMMAND"
! grep -Fq 'present=$((present + 1))' "$BACKUP" || {
  echo 'validator identity classification must not run as the unprivileged SSH user' >&2
  exit 1
}
grep -Fq 'running validator identity does not match the supplied backup' "$REMOTE_RESTORE_COMMAND"
grep -Fq 'staged TMKMS key does not match the validator backup consensus identity' "$REMOTE_RESTORE_COMMAND"
grep -Fq 'chown root:root "$candidate"' "$REMOTE_RESTORE_COMMAND"
grep -Fq 'staged validator identity contains a link or special file' "$REMOTE_RESTORE_COMMAND"
grep -Fq 'validator identity state is partial, mixed, or ambiguous' "$REMOTE_RESTORE_COMMAND"
grep -Fq 'remote state was not changed' "$BACKUP"
material_validation_line="$(grep -n -F 'validate_recovery_material "$extracted/remote-state"' \
  "$BACKUP" | head -n1 | cut -d: -f1)"
remote_stage_line="$(grep -n -F 'remote="$(ssh -T "$node"' "$BACKUP" | head -n1 | cut -d: -f1)"
[[ -n "$material_validation_line" && -n "$remote_stage_line" \
  && "$material_validation_line" -lt "$remote_stage_line" ]] || {
  echo 'validator recovery material must be bound before remote staging' >&2
  exit 1
}
grep -Fq 'interrupted validator identity restore is inconsistent' "$REMOTE_RESTORE_COMMAND"
grep -Fq 'remote_identity_write:false' "$RUNNING_RECOVERY"
grep -Fq 'evaluate-running-host-recovery.sh" participant' "$RUNNING_RECOVERY"
grep -Fq '.account.pub_key.key == $key' "$RUNNING_RECOVERY"
grep -Fq 'GDC_OPERATOR_HOME="$check_home/keyring"' "$MNEMONIC_IDENTITY"
grep -Fq '{ set +x; } 2>/dev/null' "$MNEMONIC_IDENTITY" "$TMKMS_PUBLIC_KEY"
grep -Fq 'keys add "$KEY_NAME" --recover --keyring-backend file' "$MNEMONIC_IDENTITY"
grep -Fq '"$NODE-cold-recovery-check" "$EXPECTED_ADDRESS"' "$RUNNING_RECOVERY"
grep -Fq '"$NODE-warm-recovery-check" "$EXPECTED_WARM_ADDRESS" "$EXPECTED_WARM_KEY"' "$RUNNING_RECOVERY"
grep -Fq '.account_pubkey_b64 "$ACCOUNT"' "$RUNNING_RECOVERY"
grep -Fq 'recover-running-host-deployment-secrets.sh" "$NODE" "$SECRETS"' "$RUNNING_RECOVERY"
deployment_secret_line="$(grep -n 'recover-running-host-deployment-secrets.sh' "$RUNNING_RECOVERY" | head -n1 | cut -d: -f1)"
local_secret_line="$(grep -n 'make-node-operator-secrets.sh' "$RUNNING_RECOVERY" | head -n1 | cut -d: -f1)"
[[ "$deployment_secret_line" -lt "$local_secret_line" ]] || {
  echo 'running Host deployment passwords must be recovered before any local secret generation' >&2
  exit 1
}
grep -Fq 'KEYRING_PASSWORD="$(<"$SECRETS/$NODE.keyring")"' "$ROOT/02-node/render-node-env.sh"
grep -Fq 'POSTGRES_PASSWORD="$(<"$SECRETS/$NODE.postgres")"' "$ROOT/02-node/render-node-env.sh"
grep -Fq 'GDC_RECOVERY_SYNC_TIMEOUT_SECONDS:-300' "$RUNNING_RECOVERY"
grep -Fq 'GDC_RECOVERY_FETCH_ATTEMPTS:-5' "$RUNNING_RECOVERY"
grep -Fq 'evaluate-running-host-recovery.sh" status' "$RUNNING_RECOVERY"
[[ "$(grep -Fc 'if type == "boolean" then tostring else "unknown" end' "$RUNNING_RECOVERY")" == 2 ]] \
  || { echo 'recovery diagnostics must preserve explicit catching_up=false values' >&2; exit 1; }
! grep -Fq '.result.sync_info.catching_up // true' "$RUNNING_RECOVERY"
grep -Fq 'capture_canonical_genesis "$CHAIN_BASE/chain-rpc/genesis"' "$RUNNING_RECOVERY"
grep -Fq 'evaluate-running-host-recovery.sh" lineage' "$RUNNING_RECOVERY"
grep -Fq 'evaluate-running-host-recovery.sh" block' "$RUNNING_RECOVERY"
grep -Fq 'evaluate-running-host-recovery.sh" validators' "$RUNNING_RECOVERY"
grep -Fq 'evaluate-running-host-recovery.sh" signature' "$RUNNING_RECOVERY"
grep -Fq 'VALIDATOR_HEIGHT="$FINAL_CHAIN_HEIGHT"' "$RUNNING_RECOVERY"
grep -Fq 'evaluate-running-host-recovery.sh" decision-height' "$RUNNING_RECOVERY"
grep -Fq 'evaluate-running-host-recovery.sh" validator-pages' "$RUNNING_RECOVERY"
grep -Fq 'validators?height=$height&page=$page&per_page=$page_size' "$RUNNING_RECOVERY"
grep -Fq 'commit_height=$((height - offset))' "$RUNNING_RECOVERY"
grep -Fq '/chain-rpc/commit?height=$commit_height' "$RUNNING_RECOVERY"
! grep -Fq 'validators?height=$COMMON_HEIGHT' "$RUNNING_RECOVERY"
grep -Fq 'sync_samples >= 3' "$RUNNING_RECOVERY"
grep -Fq 'last_accepted_public_height="$(jq -er .public_height' "$RUNNING_RECOVERY"
grep -Fq 'last_accepted_remote_height="$(jq -er .local_height' "$RUNNING_RECOVERY"
grep -Fq 'VALIDATOR_EFFECTIVE=false' "$RUNNING_RECOVERY"
grep -Fq '((VOTING_POWER > 0)) && VALIDATOR_EFFECTIVE=true' "$RUNNING_RECOVERY"
grep -Fq 'CONSENSUS_SIGNED_RECENTLY=true' "$RUNNING_RECOVERY"
grep -Fq 'no signed canonical commit was found in the five-height decision window' "$RUNNING_RECOVERY"
! grep -Fq 'uniquely effective with positive voting power' "$RUNNING_RECOVERY"
grep -Fq 'validator_effective:$validator_effective' "$RUNNING_RECOVERY"
grep -Fq '.ml_ssh_alias == $alias' "$RECOVERY_EVALUATOR"
grep -Fq '.ml_endpoint == $endpoint' "$RECOVERY_EVALUATOR"
grep -Fq 'length == 1 and .[0].id == $runtime_id' "$RECOVERY_EVALUATOR"
grep -Fq '"$NODE" "$EXPECTED_RUNTIME_ID" "$EXPECTED_ML_HOST"' "$RUNNING_RECOVERY"
grep -Fq 'ssh -T "$EXPECTED_ML_HOST"' "$RUNNING_RECOVERY"
grep -Fq 'evaluate-running-host-recovery.sh" topology' "$RUNNING_RECOVERY"
grep -Fq 'publish-running-host-recovery.sh' "$RUNNING_RECOVERY"
restore_line="$(grep -n 'validator-backup.sh" restore' "$ROOT/scripts/phase-join.sh" | head -n1 | cut -d: -f1)"
prepare_line="$(grep -n 'phase-prepare.sh' "$ROOT/scripts/phase-join.sh" | head -n1 | cut -d: -f1)"
[[ "$restore_line" -lt "$prepare_line" ]] || {
  echo 'existing Host recovery must complete before any remote preparation' >&2
  exit 1
}
grep -Fq 'inference/config/node_key.json' "$BACKUP" || { echo 'backup must preserve the P2P node identity' >&2; exit 1; }
grep -Fq 'remote-state/inference/config/node_key.json' "$BACKUP"
grep -Fq 'validator-backup.tar' "$ROOT/ROLE-JOIN.md"
! grep -Fq -- '--restore' "$ROOT/ROLE-JOIN.md"
grep -Fq 'committed after timeout readback' "$ROOT/03-join/grant-ml-ops.sh"
grep -Fq 'query tx "$grant_tx_hash" --node "$RPC" --output json' "$ROOT/03-join/grant-ml-ops.sh"
grep -Fq 'do not retry automatically' "$ROOT/03-join/grant-ml-ops.sh"
grep -Fq "sed '/^Usage:/,\$d'" "$ROOT/03-join/grant-ml-ops.sh"

printf 'PASS validator backup and restore contract\n'
