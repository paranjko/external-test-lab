#!/usr/bin/env bash
set +x
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
MAX_VALIDATOR_BACKUP_ARCHIVE_BYTES=$((66 * 1024 * 1024))
MAX_VALIDATOR_BACKUP_TRAILING_BYTES=$((1024 * 1024))

usage() {
  echo "Usage: $0 create SSH_ALIAS | restore SSH_ALIAS ARCHIVE" >&2
}

safe_extract() {
  local archive="$1" destination="$2" archive_kind="$3" node="$4"
  command -v python3 >/dev/null 2>&1 \
    || die 'python3 is required to inspect validator backup archives safely'
  python3 - "$archive" "$destination" "$archive_kind" "$node" \
    "$MAX_VALIDATOR_BACKUP_ARCHIVE_BYTES" "$MAX_VALIDATOR_BACKUP_TRAILING_BYTES" <<'PY' \
    || die 'validator backup archive structure is invalid or ambiguous'
import os
import re
import shutil
import stat
import sys
import tarfile

archive, destination, archive_kind, node = sys.argv[1:5]
MAX_MEMBERS = 1024
MAX_FILE_SIZE = 8 * 1024 * 1024
MAX_TOTAL_SIZE = 64 * 1024 * 1024
MAX_ARCHIVE_SIZE = int(sys.argv[5])
MAX_TRAILING_PADDING = int(sys.argv[6])
TRAILING_READ_SIZE = 64 * 1024

def reject_name(name):
    if not name or name.startswith('/') or '\\' in name:
        return True
    if re.fullmatch(r'[A-Za-z0-9._/-]+', name) is None:
        return True
    if any(ord(char) < 32 or ord(char) == 127 for char in name):
        return True
    parts = name.rstrip('/').split('/')
    return any(part in ('', '.', '..') for part in parts)

def allowed(path):
    if archive_kind == 'backup':
        exact = {
            'manifest.json', 'manifest.sha256', 'identity.json',
            'mnemonics', f'mnemonics/{node}-cold.mnemonic',
            f'mnemonics/{node}-warm.mnemonic', 'remote-state',
            'remote-state/tmkms', 'remote-state/inference',
            'remote-state/inference/config',
            'remote-state/inference/config/node_key.json',
        }
        return path in exact or path.startswith('remote-state/tmkms/')
    exact = {
        'tmkms', 'inference', 'inference/config',
        'inference/config/node_key.json',
    }
    return path in exact or path.startswith('tmkms/')

try:
    required_dirs = {
        'tmkms', 'tmkms/secrets', 'tmkms/state', 'inference', 'inference/config'
    }
    required_files = {
        'tmkms/tmkms.toml', 'tmkms/secrets/priv_validator_key.softsign',
        'tmkms/secrets/kms-identity.key',
        'tmkms/state/priv_validator_state.json',
        'inference/config/node_key.json',
    }
    if archive_kind == 'backup':
        required_dirs = {'mnemonics', 'remote-state'} | {
            f'remote-state/{path}' for path in required_dirs
        }
        required_files = {
            'manifest.json', 'manifest.sha256', 'identity.json',
            f'mnemonics/{node}-cold.mnemonic',
            f'mnemonics/{node}-warm.mnemonic',
        } | {f'remote-state/{path}' for path in required_files}
    elif archive_kind != 'remote-state':
        raise ValueError('unknown archive kind')

    flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0)
    descriptor = os.open(archive, flags)
    with os.fdopen(descriptor, 'rb') as raw_archive:
      archive_status = os.fstat(raw_archive.fileno())
      archive_size = archive_status.st_size
      if not stat.S_ISREG(archive_status.st_mode):
          raise ValueError('archive type')
      if archive_size < 1024 or archive_size > MAX_ARCHIVE_SIZE:
          raise ValueError('archive size')
      if archive_size % 512 != 0:
          raise ValueError('archive alignment')
      with tarfile.open(fileobj=raw_archive, mode='r:') as source:
        members = []
        for member in source:
            members.append(member)
            if len(members) > MAX_MEMBERS:
                raise ValueError('member count')
        end_offset = source.offset
        if not members:
            raise ValueError('member count')
        seen = {}
        total_size = 0
        for member in members:
            if reject_name(member.name):
                raise ValueError('unsafe name')
            path = member.name.rstrip('/')
            if path in seen or not allowed(path):
                raise ValueError('duplicate or unexpected member')
            if not (member.isdir() or member.isreg()):
                raise ValueError('wrong member type')
            if member.isdir() and path in required_files:
                raise ValueError('file is directory')
            if member.isreg() and path in required_dirs:
                raise ValueError('directory is file')
            if member.size < 0 or member.size > MAX_FILE_SIZE:
                raise ValueError('file size')
            total_size += member.size
            if total_size > MAX_TOTAL_SIZE:
                raise ValueError('total size')
            seen[path] = member
        if not required_dirs.issubset(seen) or not required_files.issubset(seen):
            raise ValueError('missing member')
        if any(not seen[path].isdir() for path in required_dirs):
            raise ValueError('wrong directory type')
        if any(not seen[path].isreg() for path in required_files):
            raise ValueError('wrong file type')
        for path in seen:
            parent = path.rpartition('/')[0]
            if parent and parent not in seen:
                raise ValueError('missing parent member')
            if parent and not seen[parent].isdir():
                raise ValueError('non-directory parent')

        trailing_size = archive_size - end_offset
        if trailing_size < 1024 or trailing_size > MAX_TRAILING_PADDING:
            raise ValueError('trailing padding size')
        raw_archive.seek(end_offset)
        remaining = trailing_size
        while remaining:
            chunk = raw_archive.read(min(TRAILING_READ_SIZE, remaining))
            if not chunk or len(chunk) > remaining or any(chunk):
                raise ValueError('trailing archive payload')
            remaining -= len(chunk)

        os.makedirs(destination, mode=0o700, exist_ok=True)
        for path, member in seen.items():
            target = os.path.join(destination, *path.split('/'))
            if member.isdir():
                os.mkdir(target, mode=0o700)
                continue
            source_file = source.extractfile(member)
            if source_file is None:
                raise ValueError('missing file body')
            descriptor = os.open(
                target,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0),
                0o600,
            )
            with os.fdopen(descriptor, 'wb') as output:
                shutil.copyfileobj(source_file, output)
except Exception:
    sys.exit(1)
PY
}

verify_checksum_manifest() {
  local root="$1"
  python3 - "$root" <<'PY' \
    || die 'validator backup checksum manifest is malformed or inconsistent'
import hashlib
import os
import re
import sys

root = sys.argv[1]
manifest_path = os.path.join(root, 'manifest.sha256')
try:
    data = open(manifest_path, 'rb').read()
    if len(data) > 65536 or not data or b'\x00' in data:
        raise ValueError('manifest size')
    text = data.decode('ascii')
    pattern = re.compile(r'^([0-9a-f]{64})  ([A-Za-z0-9._/-]+)$')
    listed = {}
    for line in text.splitlines():
        match = pattern.fullmatch(line)
        if not match:
            raise ValueError('line')
        digest, path = match.groups()
        parts = path.split('/')
        if path.startswith('/') or any(part in ('', '.', '..') for part in parts):
            raise ValueError('path')
        if path in listed or path == 'manifest.sha256':
            raise ValueError('duplicate')
        listed[path] = digest
    actual = set()
    for directory, directories, files in os.walk(root, followlinks=False):
        if any(os.path.islink(os.path.join(directory, name)) for name in directories + files):
            raise ValueError('link')
        for name in files:
            path = os.path.relpath(os.path.join(directory, name), root)
            if path != 'manifest.sha256':
                actual.add(path)
    if set(listed) != actual:
        raise ValueError('coverage')
    for path, expected in listed.items():
        digest = hashlib.sha256()
        with open(os.path.join(root, *path.split('/')), 'rb') as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b''):
                digest.update(chunk)
        if digest.hexdigest() != expected:
            raise ValueError('digest')
except Exception:
    sys.exit(1)
PY
}

validate_base64_file() {
  local source_file="$1" expected_size="$2" work encoded canonical
  work="$(mktemp -d)"
  if ! base64 -d "$source_file" >"$work/value.raw" 2>/dev/null; then
    rm -rf -- "$work"
    die 'validator backup contains malformed key material'
  fi
  [[ "$(wc -c <"$work/value.raw" | tr -d ' ')" == "$expected_size" ]] \
    || { rm -rf -- "$work"; die 'validator backup contains malformed key material'; }
  encoded="$(tr -d '\r\n' <"$source_file")"
  canonical="$(base64 <"$work/value.raw" | tr -d '\n')"
  rm -rf -- "$work"
  [[ "$encoded" == "$canonical" ]] \
    || die 'validator backup contains non-canonical key material'
}

validate_expanded_ed25519_key() {
  local key_file="$1" derived_public="$2" work key_size embedded_public
  work="$(mktemp -d)"
  base64 -d "$key_file" >"$work/key.raw" 2>/dev/null \
    || { rm -rf -- "$work"; die 'validator backup contains malformed Ed25519 key material'; }
  key_size="$(wc -c <"$work/key.raw" | tr -d ' ')"
  [[ "$key_size" == 32 || "$key_size" == 64 ]] \
    || { rm -rf -- "$work"; die 'validator backup contains malformed Ed25519 key material'; }
  [[ "$(tr -d '\r\n' <"$key_file")" == "$(base64 <"$work/key.raw" | tr -d '\n')" ]] \
    || { rm -rf -- "$work"; die 'validator backup contains non-canonical Ed25519 key material'; }
  if [[ "$key_size" == 64 ]]; then
    embedded_public="$(tail -c 32 "$work/key.raw" | base64 | tr -d '\n')"
    [[ "$embedded_public" == "$derived_public" ]] \
      || { rm -rf -- "$work"; die 'validator backup contains an inconsistent expanded Ed25519 key'; }
  fi
  rm -rf -- "$work"
}

validate_mnemonic_file() {
  local mnemonic_file="$1"
  [[ -f "$mnemonic_file" && ! -L "$mnemonic_file" \
    && "$(wc -c <"$mnemonic_file" | tr -d ' ')" -le 512 ]] \
    || die 'validator backup contains malformed account recovery material'
  awk '
    NR == 1 && NF == 24 {
      for (i = 1; i <= NF; i++) {
        if ($i !~ /^[a-z]+$/) exit 1
      }
      valid = 1
      next
    }
    { exit 1 }
    END { if (!valid) exit 1 }
  ' "$mnemonic_file" >/dev/null 2>&1 \
    || die 'validator backup contains malformed account recovery material'
}

validate_identity_json() {
  local identity="$1" node="$2" expected_consensus_key warm_public_key
  jq -e --arg node "$node" '
    type == "object"
    and (keys | sort) == ["consensus_pubkey","node_id","node_name","warm_address","warm_pubkey_b64"]
    and .node_name == $node
    and (.node_id | type == "string" and test("^[0-9a-f]{40}$"))
    and (.consensus_pubkey | type == "string" and test("^[A-Za-z0-9+/]{43}=$"))
    and (.warm_address | type == "string" and test("^gonka1[0-9a-z]{20,90}$"))
    and (.warm_pubkey_b64 | type == "string" and test("^[A-Za-z0-9+/]{44}$"))
  ' "$identity" >/dev/null 2>&1 \
    || die 'validator backup identity metadata is malformed'
  expected_consensus_key="$(jq -er .consensus_pubkey "$identity" 2>/dev/null)" \
    || die 'validator backup identity metadata is malformed'
  warm_public_key="$(jq -er .warm_pubkey_b64 "$identity" 2>/dev/null)" \
    || die 'validator backup identity metadata is malformed'
  printf '%s\n' "$expected_consensus_key" >"$identity.consensus.tmp"
  printf '%s\n' "$warm_public_key" >"$identity.warm.tmp"
  validate_base64_file "$identity.consensus.tmp" 32
  validate_base64_file "$identity.warm.tmp" 33
  rm -f -- "$identity.consensus.tmp" "$identity.warm.tmp"
}

validate_manifest_json() {
  local manifest="$1" identity="$2" node="$3"
  jq -e --arg node "$node" --slurpfile identity "$identity" '
    def base_keys:
      ["chain_id","created_at","genesis_sha256","identity","node_name","participant_address","schema_version"];
    def split_keys:
      ["chain_id","created_at","genesis_sha256","identity","ml_host","node_name","participant_address","schema_version"];
    type == "object"
    and (((keys | sort) == base_keys) or ((keys | sort) == split_keys))
    and .schema_version == 1
    and .node_name == $node
    and (.created_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and (.chain_id | type == "string" and test("^[A-Za-z0-9._-]+$"))
    and (.genesis_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    and (.participant_address | type == "string" and test("^gonka1[0-9a-z]{20,90}$"))
    and (if has("ml_host") then
      (.ml_host == null or (.ml_host | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")))
    else true end)
    and .identity == $identity[0]
  ' "$manifest" >/dev/null 2>&1 \
    || die 'validator backup manifest metadata is malformed or inconsistent'
}

validate_tmkms_config() {
  local config="$1" expected_chain="$2"
  python3 - "$config" "$expected_chain" <<'PY' \
    || die 'validator backup contains a malformed or inconsistent TMKMS configuration'
import sys
import tomllib

path, expected_chain = sys.argv[1:]
try:
    with open(path, 'rb') as source:
        config = tomllib.load(source)
    chains = config.get('chain')
    softsign = config.get('providers', {}).get('softsign')
    validators = config.get('validator')
    if not isinstance(chains, list) or len(chains) != 1:
        raise ValueError('chain')
    if not isinstance(softsign, list) or len(softsign) != 1:
        raise ValueError('softsign')
    if not isinstance(validators, list) or len(validators) != 1:
        raise ValueError('validator')
    if chains[0].get('id') != expected_chain:
        raise ValueError('chain id')
    if chains[0].get('state_file') != '/root/.tmkms/state/priv_validator_state.json':
        raise ValueError('state path')
    if softsign[0].get('chain_ids') != [expected_chain]:
        raise ValueError('softsign chain')
    if softsign[0].get('key_type') != 'consensus':
        raise ValueError('key type')
    if softsign[0].get('path') != '/root/.tmkms/secrets/priv_validator_key.softsign':
        raise ValueError('key path')
    if validators[0].get('chain_id') != expected_chain:
        raise ValueError('validator chain')
    if validators[0].get('secret_key') != '/root/.tmkms/secrets/kms-identity.key':
        raise ValueError('identity path')
    if validators[0].get('protocol_version') != 'v0.34':
        raise ValueError('protocol')
except Exception:
    sys.exit(1)
PY
}

validate_tmkms_state() {
  local state_file="$1"
  jq -e '
    type == "object"
    and (keys | sort) == ["block_id","height","round","step"]
    and (.height | type == "string" and test("^[0-9]+$"))
    and (.round | type == "string" and test("^[0-9]+$"))
    and (.step | type == "number" and . == floor and . >= -128 and . <= 127)
    and (.block_id == null or (
      (.block_id | type == "object")
      and (.block_id.hash | type == "string" and test("^[0-9A-Fa-f]{64}$"))
      and ((.block_id.parts // .block_id.part_set_header) as $parts
        | ($parts | type == "object")
        and ($parts.total | type == "number" and . == floor and . >= 0 and . <= 4294967295)
        and ($parts.hash | type == "string" and test("^[0-9A-Fa-f]{64}$")))
    ))
  ' "$state_file" >/dev/null 2>&1 \
    || die 'validator backup contains malformed TMKMS signing state'
}

validate_node_key() {
  local node_key="$1" expected_node_id="$2" work node_public embedded_public actual_node_id
  [[ "$expected_node_id" =~ ^[0-9a-f]{40}$ ]] \
    || die 'validator backup identity metadata is malformed'
  jq -e '
    type == "object" and (keys == ["priv_key"])
    and (.priv_key | type == "object" and (keys | sort) == ["type","value"])
    and .priv_key.type == "tendermint/PrivKeyEd25519"
    and (.priv_key.value | type == "string")
  ' "$node_key" >/dev/null 2>&1 \
    || die 'validator backup contains a malformed P2P node key'
  work="$(mktemp -d)"
  jq -er .priv_key.value "$node_key" >"$work/node-key.base64" 2>/dev/null \
    || { rm -rf -- "$work"; die 'validator backup contains a malformed P2P node key'; }
  validate_base64_file "$work/node-key.base64" 64
  node_public="$("$ROOT/scripts/tmkms-softsign-public-key.sh" "$work/node-key.base64" 2>/dev/null)" \
    || { rm -rf -- "$work"; die 'validator backup P2P node key cannot be verified'; }
  base64 -d "$work/node-key.base64" >"$work/node-key.raw" 2>/dev/null
  tail -c 32 "$work/node-key.raw" >"$work/node-public.raw"
  embedded_public="$(base64 <"$work/node-public.raw" | tr -d '\n')"
  # Tendermint/CometBFT P2P node ID: lowercase hex of the first 20 SHA-256 bytes.
  actual_node_id="$(sha256sum "$work/node-public.raw" | awk '{print substr($1, 1, 40)}')"
  rm -rf -- "$work"
  [[ "$node_public" == "$embedded_public" ]] \
    || die 'validator backup P2P node key is cryptographically inconsistent'
  [[ "$actual_node_id" == "$expected_node_id" ]] \
    || die 'validator backup P2P node key does not match its recorded node identity'
}

validate_recovery_material() {
  local root="$1" identity="$2" node="$3" chain_id="$4"
  local expected_consensus_key expected_node_id actual_consensus_key softsign kms_identity
  validate_identity_json "$identity" "$node"
  expected_consensus_key="$(jq -er .consensus_pubkey "$identity" 2>/dev/null)" \
    || die 'validator backup identity metadata is malformed'
  expected_node_id="$(jq -er .node_id "$identity" 2>/dev/null)" \
    || die 'validator backup identity metadata is malformed'
  softsign="$root/tmkms/secrets/priv_validator_key.softsign"
  kms_identity="$root/tmkms/secrets/kms-identity.key"
  actual_consensus_key="$("$ROOT/scripts/tmkms-softsign-public-key.sh" "$softsign" 2>/dev/null)" \
    || die 'validator backup TMKMS consensus key cannot be verified'
  validate_expanded_ed25519_key "$softsign" "$actual_consensus_key"
  [[ "$actual_consensus_key" == "$expected_consensus_key" ]] \
    || die 'validator backup TMKMS key does not match its recorded consensus identity'
  validate_base64_file "$kms_identity" 32
  validate_tmkms_config "$root/tmkms/tmkms.toml" "$chain_id"
  validate_tmkms_state "$root/tmkms/state/priv_validator_state.json"
  validate_node_key "$root/inference/config/node_key.json" "$expected_node_id"
}

identity_tree_digest() {
  local root="$1"
  (
    cd "$root"
    find . -xdev -type f -print0 \
      | LC_ALL=C sort -z \
      | xargs -0 -r sha256sum
  ) | sha256sum | awk '{print $1}'
}

create_backup() (
  local node="$1" archive archive_tmp stage configured_gpu chain_id
  archive="$GDC_DATA_ROOT/$node-validator-backup.tar"
  local cold="$GDC_HOME/mnemonics/$node-cold.mnemonic"
  local warm="$GDC_HOME/mnemonics/$node-warm.mnemonic"
  local identity="$IDENTITIES/$node.json"
  local account="$ACCOUNTS/$node-cold.json"
  [[ -s "$cold" && -s "$warm" && -s "$identity" && -s "$account" ]] || {
    die "cannot create validator backup for $node: local account or identity material is missing"
  }
  configured_gpu="$(node_ml_host "$node" || true)"
  chain_id="$(jq -er .chain_id "$GENESIS/genesis.json" 2>/dev/null)" \
    || die 'cannot create validator backup: local Genesis chain ID is malformed'
  stage="$(mktemp -d)"
  trap 'rm -rf "$stage"' EXIT
  umask 077
  mkdir -p "$stage/mnemonics" "$stage/remote-state"
  install -m 0600 "$cold" "$stage/mnemonics/$node-cold.mnemonic"
  install -m 0600 "$warm" "$stage/mnemonics/$node-warm.mnemonic"
  install -m 0600 "$identity" "$stage/identity.json"
  if ! ssh -T "$node" "set +x
    set -Eeuo pipefail
    state='/srv/dai/$node'
    test -d \"\$state/tmkms\"
    test -s \"\$state/inference/config/node_key.json\"
    sudo tar -C \"\$state\" -cf - tmkms inference/config/node_key.json 2>/dev/null" \
    >"$stage/remote-state.tar" 2>/dev/null; then
    die "cannot create validator backup for $node: remote validator identity is unavailable"
  fi
  mkdir -p "$stage/remote-state"
  safe_extract "$stage/remote-state.tar" "$stage/remote-state" remote-state "$node"
  rm -f "$stage/remote-state.tar"
  validate_recovery_material "$stage/remote-state" "$stage/identity.json" "$node" "$chain_id"
  jq -n \
    --argjson schema_version 1 \
    --arg node_name "$node" \
    --arg created_at "$(date -u +%FT%TZ)" \
    --arg chain_id "$chain_id" \
    --arg genesis_sha256 "$(genesis_sha256 "$GENESIS/genesis.json")" \
    --arg participant_address "$(jq -er .address "$account")" \
    --arg ml_host "$configured_gpu" \
    --slurpfile identity "$identity" \
    '{schema_version:$schema_version,node_name:$node_name,created_at:$created_at,chain_id:$chain_id,genesis_sha256:$genesis_sha256,participant_address:$participant_address,ml_host:(if $ml_host == "" then null else $ml_host end),identity:$identity[0]}' \
    >"$stage/manifest.json"
  (
    cd "$stage"
    find manifest.json identity.json mnemonics remote-state -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum >manifest.sha256
    archive_tmp="$(mktemp "$archive.tmp.XXXXXX")"
    if ! tar -cf "$archive_tmp" manifest.json manifest.sha256 identity.json mnemonics remote-state \
      >/dev/null 2>&1; then
      rm -f -- "$archive_tmp"
      die 'cannot assemble validator backup archive'
    fi
    [[ "$(stat -c %s -- "$archive_tmp" 2>/dev/null)" -le "$MAX_VALIDATOR_BACKUP_ARCHIVE_BYTES" ]] \
      || { rm -f -- "$archive_tmp"; die 'validator backup archive exceeds the strict byte limit'; }
    chmod 600 "$archive_tmp"
    mv "$archive_tmp" "$archive"
  )
  trap - EXIT
  rm -rf "$stage"
  printf 'BACKUP validator recovery archive created: %s\n' "$archive"
)

restore_backup() (
  local node="$1" archive="$2" stage extracted manifest remote remote_state restore_mode
  local expected_consensus_key remote_restore_command bundle_sha256 chain_id
  [[ -f "$archive" && -r "$archive" ]] || die "validator backup archive is not readable: $archive"
  archive="$(realpath -e -- "$archive")"
  stage="$(mktemp -d)"
  remote=''
  cleanup_restore() {
    local rc=$?
    trap - EXIT INT TERM
    if [[ -n "$remote" ]]; then
      ssh -T "$node" "set +x; rm -rf '$remote'" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$stage"
    return "$rc"
  }
  trap cleanup_restore EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  umask 077
  extracted="$stage/extracted"
  safe_extract "$archive" "$extracted" backup "$node"
  verify_checksum_manifest "$extracted"
  manifest="$extracted/manifest.json"
  validate_identity_json "$extracted/identity.json" "$node"
  validate_manifest_json "$manifest" "$extracted/identity.json" "$node"
  chain_id="$(jq -er .chain_id "$GENESIS/genesis.json" 2>/dev/null)" \
    || die 'local Genesis chain ID is malformed'
  [[ "$(jq -er .chain_id "$manifest" 2>/dev/null)" == "$chain_id" ]] \
    || die "validator backup archive belongs to a different chain"
  [[ "$(jq -er .genesis_sha256 "$manifest")" == "$(genesis_sha256 "$GENESIS/genesis.json")" ]] || die "validator backup archive belongs to a different Genesis"
  validate_mnemonic_file "$extracted/mnemonics/$node-cold.mnemonic"
  validate_mnemonic_file "$extracted/mnemonics/$node-warm.mnemonic"
  validate_recovery_material "$extracted/remote-state" "$extracted/identity.json" "$node" "$chain_id"
  for mnemonic in cold warm; do
    target="$GDC_HOME/mnemonics/$node-$mnemonic.mnemonic"
    source_file="$extracted/mnemonics/$node-$mnemonic.mnemonic"
    if [[ -e "$target" ]] && ! cmp -s "$target" "$source_file"; then
      die "local $mnemonic mnemonic conflicts with validator backup; use an empty GDC_HOME for restore"
    fi
  done
  remote="$(ssh -T "$node" "set +x; umask 077; mktemp -d '/tmp/gdc-$node-validator-restore-XXXXXX'" \
    2>/dev/null)" || die "cannot stage validator identity material on $node"
  [[ "$remote" =~ ^/tmp/gdc-${node}-validator-restore-[A-Za-z0-9]+$ ]] \
    || die "cannot validate validator identity staging path on $node"
  if ! scp -qr "$extracted/remote-state/." "$node:$remote/" >/dev/null 2>&1; then
    ssh -T "$node" "set +x; rm -rf '$remote'" >/dev/null 2>&1 || true
    die "cannot stage validator identity material on $node"
  fi
  expected_consensus_key="$(jq -er .consensus_pubkey "$extracted/identity.json" 2>/dev/null)"
  bundle_sha256="$(identity_tree_digest "$extracted/remote-state")"
  remote_restore_command="$("$ROOT/scripts/build-validator-identity-restore-command.sh" \
    "/srv/dai/$node" "$remote" "$expected_consensus_key" "/srv/dai/deploy/$node/.env" \
    "$bundle_sha256")" \
    || die 'validator backup contains invalid protected identity metadata'
  if ! remote_state="$(ssh -T "$node" \
    "$remote_restore_command" \
    <"$ROOT/scripts/build-validator-identity-restore-command.sh")"; then
    ssh -T "$node" "set +x; rm -rf '$remote'" >/dev/null 2>&1 || true
    die "validator backup restore refused protected identity state on $node"
  fi
  case "$remote_state" in
    existing)
      restore_mode=existing
      ;;
    installed)
      restore_mode=installed
      ;;
    *)
      die "cannot classify validator identity state on $node"
      ;;
  esac
  mkdir -p "$GDC_HOME/mnemonics" "$STATE/restore/$node"
  for mnemonic in cold warm; do
    install -m 0600 "$extracted/mnemonics/$node-$mnemonic.mnemonic" \
      "$GDC_HOME/mnemonics/$node-$mnemonic.mnemonic"
  done
  install -m 0600 "$manifest" "$STATE/restore/$node/manifest.json"
  install -m 0600 "$extracted/identity.json" "$STATE/restore/$node/identity.json"
  printf '%s\n' "$restore_mode" >"$STATE/restore/$node/mode"
  chmod 0600 "$STATE/restore/$node/mode"
  export GDC_RESTORE_VALIDATOR_BACKUP=true
  export GDC_RESTORE_IDENTITY_FILE="$STATE/restore/$node/identity.json"
  remote=''
  trap - EXIT INT TERM
  rm -rf "$stage"
  if [[ "$restore_mode" == existing ]]; then
    printf 'READY validator backup matches existing immutable identity on %s; remote state was not changed\n' "$node"
  else
    printf 'READY validator recovery material restored for %s from %s\n' "$node" "$archive"
  fi
)

if [[ "${GDC_VALIDATOR_BACKUP_TEST_MODE:-false}" == true ]]; then
  case "${1:-}" in
    inspect-archive)
      [[ $# == 5 ]] || die 'validator backup archive test requires KIND ARCHIVE DESTINATION NODE'
      safe_extract "$3" "$4" "$2" "$5"
      [[ "$2" != backup ]] || verify_checksum_manifest "$4"
      exit 0
      ;;
    validate-material)
      [[ $# == 5 ]] || die 'validator backup material test requires ROOT IDENTITY NODE CHAIN_ID'
      validate_recovery_material "$2" "$3" "$4" "$5"
      exit 0
      ;;
    validate-manifest)
      [[ $# == 4 ]] || die 'validator backup manifest test requires MANIFEST IDENTITY NODE'
      validate_identity_json "$3" "$4"
      validate_manifest_json "$2" "$3" "$4"
      exit 0
      ;;
    validate-mnemonic)
      [[ $# == 2 ]] || die 'validator backup mnemonic test requires MNEMONIC'
      validate_mnemonic_file "$2"
      exit 0
      ;;
    *) die 'unknown validator backup test operation' ;;
  esac
fi

load_project
[[ $# -ge 2 ]] || { usage; exit 2; }
case "$1" in
  create)
    [[ $# -eq 2 ]] || { usage; exit 2; }
    topology_contains_node "$2" || die "unknown SSH alias: $2"
    create_backup "$2"
    ;;
  restore)
    [[ $# -eq 3 ]] || { usage; exit 2; }
    restore_backup "$(node_name "$2")" "$3"
    ;;
  *) usage; exit 2 ;;
esac
