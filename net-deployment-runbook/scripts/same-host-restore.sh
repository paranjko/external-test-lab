#!/usr/bin/env bash
# Preserve reset fence evidence outside /srv/dai, which reset removes.
set +x
set -Eeuo pipefail
umask 077

die() { printf 'same-host restore: %s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" == --remote ]]; then
  action="${2:-}"; node="${3:-}"
  [[ $EUID == 0 && "$node" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || die 'invalid Host or sudo authority'
  root=/srv/dai
  backup_root=/srv/backup
  machine="$(sha256sum /etc/machine-id | awk '{print $1}')"

  tree_digest() {
    local path="$1"
    ( cd "$path" && find . -xdev -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum ) | sha256sum | awk '{print $1}'
  }

  safe_tree() {
    local path="$1"
    [[ -d "$path" && ! -L "$path" ]] || return 1
    ! find "$path" -xdev \( -type l -o \( ! -type f ! -type d \) \) -print -quit | grep -q .
  }

  validate_metadata() {
    local metadata="$1" key="$2" chain="$3"
    jq -e --arg machine "$machine" --arg key "$key" --arg chain "$chain" '
      .kind == "gdc-reset-dai-backup" and .schema_version == 1
      and .machine_sha256 == $machine and .key_sha256 == $key and .chain_id == $chain
      and .signer_stopped == true
      and (.signing_state.height | type == "string" and test("^[0-9]+$"))
      and (.archive_path | type == "string" and test("^/srv/backup/reset-[A-Za-z0-9][A-Za-z0-9._-]{0,127}-dai-backup\\.tar$"))
      and (.archive_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    ' "$metadata" >/dev/null
  }

  validate_archive() {
    local archive="$1" metadata="$2" stage embedded identity signer
    [[ -f "$archive" && ! -L "$archive" && "$(stat -c %u "$archive")" == 0 && "$(stat -c %a "$archive")" == 600 ]] \
      || die 'reset archive is not a root-owned 0600 regular file'
    [[ "$(sha256sum "$archive" | awk '{print $1}')" == "$(jq -r .archive_sha256 "$metadata")" ]] \
      || die 'reset archive digest does not match metadata'
    tar -tf "$archive" | awk '
      $0 == "reset-manifest.json" || $0 == "identity/" || $0 == "signer/" || $0 ~ /^(identity|signer)\/[A-Za-z0-9._/-]+$/ { next }
      { exit 1 }
    ' || die 'reset archive contains an unsafe member'
    stage="$(mktemp -d "$backup_root/.reset-verify.XXXXXX")"
    trap 'rm -rf -- "$stage"' RETURN
    tar -C "$stage" -xf "$archive" reset-manifest.json || die 'reset archive manifest is unavailable'
    embedded="$stage/reset-manifest.json"; identity="$stage/identity"; signer="$stage/signer"
    if [[ "$(jq -r '.identity_present' "$embedded")" == true ]]; then
      tar -C "$stage" -xf "$archive" identity signer || die 'reset archive identity material is unavailable'
      safe_tree "$identity" && safe_tree "$signer" || die 'reset archive contains unsafe identity material'
      jq -e --arg identity "$(tree_digest "$identity")" --arg signer "$(tree_digest "$signer")" '
        .kind == "gdc-reset-dai-backup" and .schema_version == 1 and .identity_present == true
        and .identity_sha256 == $identity and .signer_sha256 == $signer
      ' "$embedded" >/dev/null || die 'reset archive contents do not match its manifest'
    else
      jq -e '.kind == "gdc-reset-dai-backup" and .schema_version == 1 and .identity_present == false
        and .identity_sha256 == null and .signer_sha256 == null' "$embedded" >/dev/null \
        || die 'empty reset archive manifest is malformed'
    fi
    trap - RETURN
    rm -rf -- "$stage"
  }

  case "$action" in
    capture)
      run_id="${4:-}"
      [[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die 'invalid reset run ID'
      [[ ! -e "$root" || ( -d "$root" && ! -L "$root" ) ]] || die 'validator root is unsafe'
      install -d -m 0700 "$backup_root"
      [[ -d "$backup_root" && ! -L "$backup_root" && "$(stat -c %u "$backup_root")" == 0 ]] || die 'reset backup root is unsafe'
      archive="$backup_root/reset-$run_id-dai-backup.tar"
      [[ ! -e "$archive" && ! -e "$archive.json" ]] || die 'reset archive already exists; refusing overwrite'

      mapfile -t managed < <(docker ps -aq --filter "label=com.docker.compose.project=$node" | xargs -r docker inspect | jq -r '.[] | select(.Config.Labels["com.docker.compose.service"] | IN("node","tmkms")) | .Id')
      if (( ${#managed[@]} > 0 )); then
        docker update --restart=no "${managed[@]}" >/dev/null
        docker stop --time 30 "${managed[@]}" >/dev/null
        docker inspect "${managed[@]}" | jq -e 'all(.[]; .State.Running == false)' >/dev/null || die 'signer stop not confirmed'
      fi

      flat_identity="$root/identity"; flat_signer="$root/signer"
      legacy_identity="$root/identity/$node"; legacy_signer="$root/signer/$node"
      flat_present=false; legacy_present=false
      # Legacy roots are children of these parent directories, so merely
      # finding /srv/dai/identity or /srv/dai/signer is not a flat-layout
      # signal. Detect a direct flat member instead.
      [[ -e "$flat_identity/p2p" || -e "$flat_identity/warm" || -e "$flat_signer/tmkms" ]] && flat_present=true
      [[ -e "$legacy_identity" || -e "$legacy_signer" ]] && legacy_present=true
      if [[ "$flat_present" == true && "$legacy_present" == true ]]; then
        die 'validator identity layout is mixed or ambiguous'
      fi
      if [[ "$flat_present" == true ]]; then
        identity="$flat_identity"; signer="$flat_signer"; deploy="$root/deploy/.env"
        genesis="$root/data/config/genesis.json"
      elif [[ "$legacy_present" == true ]]; then
        # The pre-flat deployment layout kept per-Host identity roots. Archive
        # only its exact identity pair and normalize the recovery payload to
        # the flat paths expected by a later restore.
        identity="$legacy_identity"; signer="$legacy_signer"; deploy="$root/$node/.env"
        genesis="$root/$node/inference/config/genesis.json"
      else
        identity=''; signer=''; deploy=''; genesis=''
      fi
      stage="$(mktemp -d "$backup_root/.reset-$run_id.XXXXXX")"
      trap 'rm -rf -- "$stage"' EXIT
      if [[ -n "$identity" ]]; then
        safe_tree "$identity" && safe_tree "$signer" || die 'validator identity is partial or unsafe'
        key_file="$signer/tmkms/secrets/priv_validator_key.softsign"
        state_file="$signer/tmkms/state/priv_validator_state.json"
        [[ -s "$key_file" && -s "$state_file" && ! -L "$key_file" && ! -L "$state_file" ]] || die 'validator signer is incomplete'
        chain=''
        if [[ -f "$deploy" && ! -L "$deploy" ]]; then
          chain="$(awk -F= '$1 == "CHAIN_ID" {print $2; exit}' "$deploy")"
        fi
        if [[ -z "$chain" && -f "$genesis" && ! -L "$genesis" ]]; then
          chain="$(jq -r '.chain_id // empty' "$genesis")"
        fi
        [[ "$chain" =~ ^[A-Za-z0-9_-]+$ ]] || die 'validator deployment chain binding is invalid'
        key="$(sha256sum "$key_file" | awk '{print $1}')"
        jq -e '.height | type == "string" and test("^[0-9]+$")' "$state_file" >/dev/null || die 'validator signing state is malformed'
        jq -cn --arg machine "$machine" --arg chain "$chain" --arg key "$key" --arg run_id "$run_id" \
          --arg identity_sha256 "$(tree_digest "$identity")" --arg signer_sha256 "$(tree_digest "$signer")" \
          --slurpfile state "$state_file" --arg time "$(date -u +%FT%TZ)" \
          '{schema_version:1,kind:"gdc-reset-dai-backup",run_id:$run_id,machine_sha256:$machine,chain_id:$chain,key_sha256:$key,signer_stopped:true,identity_present:true,signing_state:$state[0],identity_sha256:$identity_sha256,signer_sha256:$signer_sha256,observed_at:$time}' \
          >"$stage/reset-manifest.json"
        install -d -m 0700 "$stage/payload"
        cp -a "$identity" "$stage/payload/identity"
        cp -a "$signer" "$stage/payload/signer"
        safe_tree "$stage/payload/identity" && safe_tree "$stage/payload/signer" \
          || die 'staged validator identity is partial or unsafe'
        [[ "$(tree_digest "$stage/payload/identity")" == "$(tree_digest "$identity")" \
          && "$(tree_digest "$stage/payload/signer")" == "$(tree_digest "$signer")" ]] \
          || die 'staged validator identity does not match the source layout'
        tar --format=ustar -C "$stage/payload" -cf "$stage/archive.tar" identity signer
      else
        jq -cn --arg machine "$machine" --arg run_id "$run_id" --arg time "$(date -u +%FT%TZ)" \
          '{schema_version:1,kind:"gdc-reset-dai-backup",run_id:$run_id,machine_sha256:$machine,chain_id:null,key_sha256:null,signer_stopped:true,identity_present:false,signing_state:null,identity_sha256:null,signer_sha256:null,observed_at:$time}' \
          >"$stage/reset-manifest.json"
        tar --format=ustar -C "$stage" -cf "$stage/archive.tar" reset-manifest.json
      fi
      if [[ "$(jq -r '.identity_present' "$stage/reset-manifest.json")" == true ]]; then
        tar --format=ustar --append -C "$stage" -f "$stage/archive.tar" reset-manifest.json
      fi
      # Publish neither path by replacement.  A reset archive is recovery
      # authority, so a concurrent or interrupted invocation must never
      # overwrite a previous run's bytes.  Hard-link publication is atomic
      # on this filesystem and fails if the final pathname already exists.
      # Keep both candidates in the private staging directory until their
      # contents validate against the final archive pathname.
      chmod 0600 "$stage/archive.tar"
      archive_sha="$(sha256sum "$stage/archive.tar" | awk '{print $1}')"
      jq --arg path "$archive" --arg sha "$archive_sha" '. + {archive_path:$path,archive_sha256:$sha}' "$stage/reset-manifest.json" >"$stage/archive.json"
      chmod 0600 "$stage/archive.json"
      validate_archive "$stage/archive.tar" "$stage/archive.json"
      archive_inode="$(stat -c '%d:%i' "$stage/archive.tar")"
      metadata_inode="$(stat -c '%d:%i' "$stage/archive.json")"
      ln "$stage/archive.tar" "$archive" || die 'reset archive already exists; refusing overwrite'
      if ! ln "$stage/archive.json" "$archive.json"; then
        [[ "$(stat -c '%d:%i' "$archive" 2>/dev/null || true)" == "$archive_inode" ]] \
          && rm -f -- "$archive"
        die 'reset archive metadata already exists; refusing overwrite'
      fi
      [[ "$(stat -c '%d:%i' "$archive" 2>/dev/null || true)" == "$archive_inode" ]] \
        && [[ "$(stat -c '%d:%i' "$archive.json" 2>/dev/null || true)" == "$metadata_inode" ]] \
        || die 'reset archive publication did not retain its staged bytes'
      validate_archive "$archive" "$archive.json"
      cat "$archive.json"
      trap - EXIT
      rm -rf -- "$stage"
      ;;
    bind)
      expected_chain="${4:-}"; archive="${5:-}"
      [[ "$expected_chain" =~ ^[A-Za-z0-9_-]+$ && "$archive" =~ ^/srv/backup/reset-[A-Za-z0-9][A-Za-z0-9._-]{0,127}-dai-backup\.tar$ ]] || die 'invalid reset archive binding input'
      metadata="$archive.json"
      signer="$root/signer/tmkms"; key_file="$signer/secrets/priv_validator_key.softsign"
      [[ -s "$key_file" ]] || die 'restored signer is incomplete'
      key="$(sha256sum "$key_file" | awk '{print $1}')"
      validate_metadata "$metadata" "$key" "$expected_chain" || die 'reset archive does not match restored machine, chain and key'
      validate_archive "$archive" "$metadata"
      [[ -z "$(docker ps -q --filter "label=com.docker.compose.project=$node" --filter label=com.docker.compose.service=tmkms)" ]] || die 'signer must remain stopped'
      cat "$metadata"
      ;;
    *) die 'unknown remote operation' ;;
  esac
  exit
fi

[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0
action="${1:-}"; node="${2:-}"
[[ "$node" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || die 'invalid SSH alias'
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$action" in
  capture)
    output="${3:-}"; run_id="${GDC_RUN_ID:-}"
    [[ -n "$output" && "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die 'capture requires output and run ID'
    install -d -m 0700 "$(dirname "$output")"
    ssh -T "$node" "sudo -n bash -s -- --remote capture '$node' '$run_id'" <"${BASH_SOURCE[0]}" >"$output"
    chmod 600 "$output"
    jq -e '.kind == "gdc-reset-dai-backup" and (.archive_path | type == "string") and (.archive_sha256 | test("^[0-9a-f]{64}$"))' "$output" >/dev/null || die 'reset archive capture returned invalid metadata'
    ;;
  bind)
    identity="${3:-}"; chain="${4:-}"; metadata="${5:-}"; output="${6:-}"
    [[ -r "$identity" && -r "$metadata" && "$chain" =~ ^[A-Za-z0-9_-]+$ && -n "$output" ]] || die 'invalid restore binding input'
    archive="$(jq -er '.archive_path' "$metadata" 2>/dev/null || true)"
    [[ "$archive" =~ ^/srv/backup/reset-[A-Za-z0-9][A-Za-z0-9._-]{0,127}-dai-backup\.tar$ ]] || die 'reset archive metadata lacks a safe archive path'
    ssh -T "$node" "sudo -n bash -s -- --remote bind '$node' '$chain' '$archive'" <"${BASH_SOURCE[0]}" >"$output"
    jq -e '.kind == "gdc-reset-dai-backup" and .signer_stopped == true' "$output" >/dev/null || die 'invalid reset archive readback'
    jq .signing_state "$output" >"$output.minimum"
    ssh -T "$node" "sudo -n cat '/srv/dai/signer/tmkms/state/priv_validator_state.json'" >"$output.observed"
    if "$ROOT/scripts/verify-tmkms-signing-state.sh" --minimum "$output.minimum" --observed "$output.observed" >/dev/null 2>&1; then
      :
    else
      "$ROOT/scripts/verify-tmkms-signing-state.sh" --minimum "$output.observed" --observed "$output.minimum" >/dev/null || die 'conflicting signing minima'
      ssh -T "$node" "sudo -n tee '/srv/dai/signer/tmkms/state/priv_validator_state.json' >/dev/null" <"$output.minimum"
    fi
    expected_key="$(jq -er .consensus_pubkey "$identity")"
    actual_key="$(ssh -T "$node" "sudo -n bash -s -- '/srv/dai/signer/tmkms/secrets/priv_validator_key.softsign'" <"$ROOT/scripts/tmkms-softsign-public-key.sh")"
    [[ "$expected_key" == "$actual_key" ]] || die 'restored key differs from the archive identity'
    ;;
  *) die 'expected capture or bind' ;;
esac
