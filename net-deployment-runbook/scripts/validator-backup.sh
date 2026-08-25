#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_project

usage() {
  echo "Usage: $0 create SSH_ALIAS | restore SSH_ALIAS ARCHIVE" >&2
}

safe_extract() {
  local archive="$1" destination="$2" listing
  listing="$(tar -tf "$archive")"
  [[ -n "$listing" ]] || die "validator backup archive is empty: $archive"
  while IFS= read -r entry; do
    [[ "$entry" != /* && "$entry" != *'..'* ]] || die "validator backup archive has an unsafe path: $entry"
    case "$entry" in
      manifest.json|manifest.sha256|identity.json|mnemonics/|mnemonics/*|remote-state/|remote-state/tmkms/|remote-state/tmkms/*|remote-state/inference/|remote-state/inference/config/|remote-state/inference/config/node_key.json) ;;
      *) die "validator backup archive has an unexpected entry: $entry" ;;
    esac
  done <<<"$listing"
  while IFS= read -r type; do
    [[ "$type" == '-' || "$type" == 'd' ]] || die 'validator backup archive may not contain links or special files'
  done < <(tar -tvf "$archive" | cut -c1)
  tar -xf "$archive" -C "$destination" --no-same-owner --no-same-permissions
}

safe_extract_remote_state() {
  local archive="$1" destination="$2" listing
  listing="$(tar -tf "$archive")"
  [[ -n "$listing" ]] || die 'remote validator identity archive is empty'
  while IFS= read -r entry; do
    [[ "$entry" != /* && "$entry" != *'..'* ]] || die "remote validator identity archive has an unsafe path: $entry"
    case "$entry" in
      tmkms/|tmkms/*|inference/|inference/config/|inference/config/node_key.json) ;;
      *) die "remote validator identity archive has an unexpected entry: $entry" ;;
    esac
  done <<<"$listing"
  while IFS= read -r type; do
    [[ "$type" == '-' || "$type" == 'd' ]] || die 'remote validator identity archive may not contain links or special files'
  done < <(tar -tvf "$archive" | cut -c1)
  tar -xf "$archive" -C "$destination" --no-same-owner --no-same-permissions
}

create_backup() {
  local node="$1" archive stage remote_archive configured_gpu
  archive="$GDC_DATA_ROOT/$node-validator-backup.tar"
  local cold="$GDC_HOME/mnemonics/$node-cold.mnemonic"
  local warm="$GDC_HOME/mnemonics/$node-warm.mnemonic"
  local identity="$IDENTITIES/$node.json"
  local account="$ACCOUNTS/$node-cold.json"
  [[ -s "$cold" && -s "$warm" && -s "$identity" && -s "$account" ]] || {
    die "cannot create validator backup for $node: local account or identity material is missing"
  }
  configured_gpu="$(node_ml_host "$node" || true)"
  stage="$(mktemp -d)"
  trap 'rm -rf "$stage"' RETURN
  umask 077
  mkdir -p "$stage/mnemonics" "$stage/remote-state"
  install -m 0600 "$cold" "$stage/mnemonics/$node-cold.mnemonic"
  install -m 0600 "$warm" "$stage/mnemonics/$node-warm.mnemonic"
  install -m 0600 "$identity" "$stage/identity.json"
  remote_archive="/tmp/gdc-$node-validator-backup-$$.tar"
  if ! ssh -T "$node" "set -Eeuo pipefail
    state='/srv/dai/$node'
    test -d \"\$state/tmkms\"
    test -s \"\$state/inference/config/node_key.json\"
    sudo tar -C \"\$state\" -cf '$remote_archive' tmkms inference/config/node_key.json
    sudo chmod 0600 '$remote_archive'"; then
    die "cannot create validator backup for $node: remote validator identity is unavailable"
  fi
  if ! scp -q "$node:$remote_archive" "$stage/remote-state.tar"; then
    ssh -T "$node" "sudo rm -f '$remote_archive'" || true
    die "cannot download validator backup material for $node"
  fi
  ssh -T "$node" "sudo rm -f '$remote_archive'"
  mkdir -p "$stage/remote-state"
  safe_extract_remote_state "$stage/remote-state.tar" "$stage/remote-state"
  rm -f "$stage/remote-state.tar"
  [[ -d "$stage/remote-state/tmkms" && -s "$stage/remote-state/inference/config/node_key.json" ]] || {
    die "validator backup for $node is missing TMKMS or P2P identity"
  }
  jq -n \
    --argjson schema_version 1 \
    --arg node_name "$node" \
    --arg created_at "$(date -u +%FT%TZ)" \
    --arg chain_id "$(jq -er .chain_id "$GENESIS/genesis.json")" \
    --arg genesis_sha256 "$(genesis_sha256 "$GENESIS/genesis.json")" \
    --arg participant_address "$(jq -er .address "$account")" \
    --arg ml_host "$configured_gpu" \
    --slurpfile identity "$identity" \
    '{schema_version:$schema_version,node_name:$node_name,created_at:$created_at,chain_id:$chain_id,genesis_sha256:$genesis_sha256,participant_address:$participant_address,ml_host:(if $ml_host == "" then null else $ml_host end),identity:$identity[0]}' \
    >"$stage/manifest.json"
  (
    cd "$stage"
    find manifest.json identity.json mnemonics remote-state -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum >manifest.sha256
    tar -cf "$archive.tmp" manifest.json manifest.sha256 identity.json mnemonics remote-state
    chmod 600 "$archive.tmp"
    mv "$archive.tmp" "$archive"
  )
  trap - RETURN
  rm -rf "$stage"
  printf 'BACKUP validator recovery archive created: %s\n' "$archive"
}

restore_backup() {
  local node="$1" archive="$2" stage manifest remote
  [[ -f "$archive" && -r "$archive" ]] || die "validator backup archive is not readable: $archive"
  archive="$(realpath -e -- "$archive")"
  stage="$(mktemp -d)"
  trap 'rm -rf "$stage"' RETURN
  umask 077
  safe_extract "$archive" "$stage"
  [[ -s "$stage/manifest.json" && -s "$stage/manifest.sha256" && -s "$stage/identity.json" ]] || {
    die "validator backup archive is incomplete: $archive"
  }
  (cd "$stage" && sha256sum -c manifest.sha256 >/dev/null) || die "validator backup archive checksum verification failed: $archive"
  manifest="$stage/manifest.json"
  [[ "$(jq -er .schema_version "$manifest")" == 1 ]] || die "validator backup archive format is unsupported: $archive"
  [[ "$(jq -er .node_name "$manifest")" == "$node" ]] || die "validator backup archive belongs to $(jq -r .node_name "$manifest"), not $node"
  [[ "$(jq -er .chain_id "$manifest")" == "$(jq -er .chain_id "$GENESIS/genesis.json")" ]] || die "validator backup archive belongs to a different chain"
  [[ "$(jq -er .genesis_sha256 "$manifest")" == "$(genesis_sha256 "$GENESIS/genesis.json")" ]] || die "validator backup archive belongs to a different Genesis"
  jq -e --slurpfile identity "$stage/identity.json" '.identity == $identity[0]' "$manifest" >/dev/null \
    || die 'validator backup archive identity metadata is inconsistent'
  [[ -s "$stage/mnemonics/$node-cold.mnemonic" && -s "$stage/mnemonics/$node-warm.mnemonic" ]] || die "validator backup archive is missing account recovery material"
  [[ -d "$stage/remote-state/tmkms" && -s "$stage/remote-state/inference/config/node_key.json" ]] || die "validator backup archive is missing validator identity material"
  mkdir -p "$GDC_HOME/mnemonics" "$STATE/restore/$node"
  for mnemonic in cold warm; do
    target="$GDC_HOME/mnemonics/$node-$mnemonic.mnemonic"
    source_file="$stage/mnemonics/$node-$mnemonic.mnemonic"
    if [[ -e "$target" ]] && ! cmp -s "$target" "$source_file"; then
      die "local $mnemonic mnemonic conflicts with validator backup; use an empty GDC_HOME for restore"
    fi
    install -m 0600 "$source_file" "$target"
  done
  install -m 0600 "$manifest" "$STATE/restore/$node/manifest.json"
  install -m 0600 "$stage/identity.json" "$STATE/restore/$node/identity.json"
  remote="/tmp/gdc-$node-validator-restore-$$"
  ssh -T "$node" "mkdir -p '$remote'"
  scp -qr "$stage/remote-state/." "$node:$remote/"
  if ! ssh -T "$node" "set -Eeuo pipefail
    state='/srv/dai/$node'
    test ! -e \"\$state/tmkms\"
    test ! -e \"\$state/inference/config/node_key.json\"
    sudo install -d -m 0700 \"\$state/tmkms\" \"\$state/inference/config\"
    sudo cp -a '$remote/tmkms/.' \"\$state/tmkms/\"
    sudo install -m 0600 '$remote/inference/config/node_key.json' \"\$state/inference/config/node_key.json\"
    sudo chown -R root:root \"\$state/tmkms\" \"\$state/inference/config/node_key.json\"
    rm -rf '$remote'"; then
    ssh -T "$node" "rm -rf '$remote'" || true
    die "validator backup restore could not install identity material on $node"
  fi
  export GDC_RESTORE_VALIDATOR_BACKUP=true
  export GDC_RESTORE_IDENTITY_FILE="$STATE/restore/$node/identity.json"
  trap - RETURN
  rm -rf "$stage"
  printf 'READY validator recovery material restored for %s from %s\n' "$node" "$archive"
}

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
