#!/bin/sh
# Portable local-operator primitives. Keep this file POSIX sh.

gdc_portable_die() {
  printf 'dependency_missing: %s\nmutation=none\n' "$1" >&2
  return 69
}

gdc_require_jq() {
  command -v jq >/dev/null 2>&1 || {
    gdc_portable_die 'jq >= 1.6 is required by the local operator layer'
    return $?
  }
  gdc_jq_version=$(jq --version 2>/dev/null | sed 's/^jq-//')
  case "$gdc_jq_version" in
    1.[6-9]*|[2-9]*) return 0 ;;
    *)
      gdc_portable_die "jq >= 1.6 is required by the local operator layer (found ${gdc_jq_version:-unknown})"
      return $?
      ;;
  esac
}

gdc_sha256() {
  [ "$#" -eq 1 ] || return 64
  gdc_hash_output=$(gdc_mktemp_file) || return $?
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" >"$gdc_hash_output" || { gdc_hash_rc=$?; rm -f "$gdc_hash_output"; return "$gdc_hash_rc"; }
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" >"$gdc_hash_output" || { gdc_hash_rc=$?; rm -f "$gdc_hash_output"; return "$gdc_hash_rc"; }
  else
    rm -f "$gdc_hash_output"
    gdc_portable_die 'SHA-256 backend is unavailable; need sha256sum or shasum -a 256'
    return $?
  fi
  awk '{print $1}' "$gdc_hash_output"
  gdc_hash_rc=$?
  rm -f "$gdc_hash_output"
  return "$gdc_hash_rc"
}

gdc_sha256_stdin() {
  [ "$#" -eq 0 ] || return 64
  gdc_hash_output=$(gdc_mktemp_file) || return $?
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum >"$gdc_hash_output" || { gdc_hash_rc=$?; rm -f "$gdc_hash_output"; return "$gdc_hash_rc"; }
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 >"$gdc_hash_output" || { gdc_hash_rc=$?; rm -f "$gdc_hash_output"; return "$gdc_hash_rc"; }
  else
    rm -f "$gdc_hash_output"
    gdc_portable_die 'SHA-256 backend is unavailable; need sha256sum or shasum -a 256'
    return $?
  fi
  awk '{print $1}' "$gdc_hash_output"
  gdc_hash_rc=$?
  rm -f "$gdc_hash_output"
  return "$gdc_hash_rc"
}

# Hash the conventional checksum listing for an ordered file set without
# depending on GNU sha256sum accepting multiple operands.
gdc_sha256_paths() {
  [ "$#" -gt 0 ] || return 64
  gdc_paths_tmp=$(gdc_mktemp_file) || return $?
  for gdc_paths_file in "$@"; do
    gdc_paths_digest=$(gdc_sha256 "$gdc_paths_file") || { gdc_paths_rc=$?; rm -f "$gdc_paths_tmp"; return "$gdc_paths_rc"; }
    printf '%s  %s\n' "$gdc_paths_digest" "$gdc_paths_file" >>"$gdc_paths_tmp" || { rm -f "$gdc_paths_tmp"; return 1; }
  done
  gdc_sha256 "$gdc_paths_tmp"
  gdc_paths_rc=$?
  rm -f "$gdc_paths_tmp"
  return "$gdc_paths_rc"
}

# Hash the newline-delimited digests of an ordered file set. This preserves
# profile-fingerprint semantics without relying on GNU sha256sum accepting
# multiple operands.
gdc_sha256_digest_list() {
  [ "$#" -gt 0 ] || return 64
  gdc_digest_list_tmp=$(gdc_mktemp_file) || return $?
  for gdc_digest_list_file in "$@"; do
    gdc_digest_list_value=$(gdc_sha256 "$gdc_digest_list_file") || { gdc_digest_list_rc=$?; rm -f "$gdc_digest_list_tmp"; return "$gdc_digest_list_rc"; }
    printf '%s\n' "$gdc_digest_list_value" >>"$gdc_digest_list_tmp" || { rm -f "$gdc_digest_list_tmp"; return 1; }
  done
  gdc_sha256 "$gdc_digest_list_tmp"
  gdc_digest_list_rc=$?
  rm -f "$gdc_digest_list_tmp"
  return "$gdc_digest_list_rc"
}

# `readlink` without options is present in stock macOS and common Linux
# userlands. No GNU realpath option is assumed. Dangling links are rejected.
gdc_realpath_existing() {
  [ "$#" -eq 1 ] || return 64
  gdc_path=$1
  [ -n "$gdc_path" ] || return 1
  case "$gdc_path" in
    /*) ;;
    *) gdc_path=$(pwd -P)/$gdc_path ;;
  esac
  while [ -L "$gdc_path" ]; do
    gdc_link=$(readlink "$gdc_path") || return 1
    case "$gdc_link" in
      /*) gdc_path=$gdc_link ;;
      *) gdc_path=$(dirname "$gdc_path")/$gdc_link ;;
    esac
  done
  [ -e "$gdc_path" ] || return 1
  gdc_dir=$(dirname "$gdc_path")
  gdc_base=$(basename "$gdc_path")
  # POSIX `cd` does not define `--`. The directory is already absolute or
  # derived from an absolute path, so it cannot be mistaken for an option.
  gdc_dir=$(CDPATH='' cd -P "$gdc_dir" 2>/dev/null && pwd -P) || return 1
  if [ "$gdc_dir" = / ] && [ "$gdc_base" = / ]; then
    printf '/\n'
  elif [ "$gdc_dir" = / ]; then
    printf '/%s\n' "$gdc_base"
  else
    printf '%s/%s\n' "$gdc_dir" "$gdc_base"
  fi
}

# Canonicalise an absolute or working-directory-relative path even when its
# final components do not exist yet.  This is intentionally lexical: callers
# creating a state directory must not require GNU `realpath -m`.
gdc_normalize_path() {
  [ "$#" -eq 1 ] || return 64
  gdc_normalize_input=$1
  case "$gdc_normalize_input" in
    *"
"*) return 1 ;;
  esac
  case "$gdc_normalize_input" in
    /*) ;;
    *) gdc_normalize_input=$(pwd -P)/$gdc_normalize_input ;;
  esac
  case "$gdc_normalize_input" in
    */..|*/../*) : ;; # lexical parent traversal must be collapsed first
    *)
      if [ -e "$gdc_normalize_input" ] || [ -L "$gdc_normalize_input" ]; then
        gdc_realpath_existing "$gdc_normalize_input"
        return $?
      fi
      ;;
  esac
  printf '%s\n' "$gdc_normalize_input" | awk -F/ '
    {
      for (i = 1; i <= NF; i++) {
        if ($i == "" || $i == ".") continue
        if ($i == "..") { if (n > 0) n--; continue }
        part[++n] = $i
      }
    }
    END {
      out = "/"
      for (i = 1; i <= n; i++) out = out (i == 1 ? "" : "/") part[i]
      print out
    }'
}

gdc_private_dir() {
  [ "$#" -eq 1 ] || return 64
  (umask 077 && mkdir -p "$1") || return $?
  chmod 0700 "$1"
}

# shellcheck disable=SC2120 # Optional prefix is part of the public helper API.
gdc_mktemp_dir() {
  [ "$#" -le 1 ] || return 64
  if [ "$#" -eq 1 ]; then
    gdc_tmp_prefix=$1
  else
    gdc_tmp_prefix=${TMPDIR:-/tmp}/gdc
  fi
  gdc_tmp_parent=$(dirname "$gdc_tmp_prefix")
  [ -d "$gdc_tmp_parent" ] || return 1
  mktemp -d "${gdc_tmp_prefix}.XXXXXXXX"
}

# shellcheck disable=SC2120 # Optional prefix is part of the public helper API.
gdc_mktemp_file() {
  [ "$#" -le 1 ] || return 64
  if [ "$#" -eq 1 ]; then
    gdc_tmp_prefix=$1
  else
    gdc_tmp_prefix=${TMPDIR:-/tmp}/gdc
  fi
  gdc_tmp_parent=$(dirname "$gdc_tmp_prefix")
  [ -d "$gdc_tmp_parent" ] || return 1
  mktemp "${gdc_tmp_prefix}.XXXXXXXX"
}

gdc_utc_after_seconds() {
  [ "$#" -eq 1 ] || return 64
  case "$1" in ''|*[!0-9]*) return 64 ;; esac
  if date -u -d "+$1 seconds" +%FT%TZ >/dev/null 2>&1; then
    date -u -d "+$1 seconds" +%FT%TZ
  elif date -u -v"+$1"S +%FT%TZ >/dev/null 2>&1; then
    date -u -v"+$1"S +%FT%TZ
  else
    gdc_portable_die 'UTC date arithmetic is unavailable; need a POSIX-compatible date backend'
  fi
}

gdc_utc_epoch() {
  [ "$#" -eq 1 ] || return 64
  if date -u -d "$1" +%s >/dev/null 2>&1; then
    date -u -d "$1" +%s
  elif date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s >/dev/null 2>&1; then
    date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s
  else
    return 1
  fi
}

# Stock macOS and Linux ping resolve a hostname before attempting ICMP.  We
# use its first banner line only, so an ICMP policy failure still yields the
# resolver result and no GNU `getent` dependency is introduced.
gdc_resolve_ipv4() {
  [ "$#" -eq 1 ] || return 64
  case "$1" in
    *[!0-9.]*|'') ;;
    *)
      # A numeric-looking value is an IPv4 literal, not a hostname. Validate
      # every decimal octet before returning it; passing malformed literals to
      # ping would otherwise turn input errors into resolver-dependent state.
      printf '%s\n' "$1" | awk -F. '
        NF != 4 { exit 1 }
        {
          for (i = 1; i <= 4; i++)
            if ($i !~ /^[0-9]+$/ || ($i + 0) > 255) exit 1
        }
      ' || return 1
      printf '%s\n' "$1"
      return 0
      ;;
  esac
  command -v ping >/dev/null 2>&1 || return 69
  # ICMP rejection is not a DNS failure. Capture the resolver banner while
  # deliberately discarding ping's status, otherwise Bash callers running
  # with pipefail turn a valid extracted address into an error.
  gdc_ping_output=$(ping -c 1 "$1" 2>/dev/null || true)
  printf '%s\n' "$gdc_ping_output" | sed -n '1{s/.*(\([0-9][0-9.]*\)).*/\1/p;}' | awk '
    $0 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print; exit }
  '
}

# Accept only canonical, dotted-decimal public IPv4 literals.  In particular,
# do not let libc/curl reinterpret octal-looking octets, bracketed hosts,
# ports, userinfo, IPv6 literals, whitespace, or other URL syntax as an IP.
gdc_is_public_ipv4() {
  [ "$#" -eq 1 ] || return 64
  printf '%s\n' "$1" | awk -F. '
    NR != 1 || $0 !~ /^[0-9]+(\.[0-9]+){3}$/ { bad = 1; next }
    {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^(0|[1-9][0-9]*)$/ || ($i + 0) > 255) { bad = 1; next }
        octet[i] = $i + 0
      }
      a = octet[1]; b = octet[2]; c = octet[3]
      # Unicast public space only.  Keep special-use, private, link-local,
      # documentation, benchmarking, and deprecated ranges out of probes.
      if (a < 1 || a > 223 || a == 10 || a == 127 ||
          (a == 100 && b >= 64 && b <= 127) ||
          (a == 169 && b == 254) ||
          (a == 172 && b >= 16 && b <= 31) ||
          (a == 192 && (b == 0 || b == 168 || (b == 88 && c == 99))) ||
          (a == 198 && (b == 18 || b == 19 || b == 51)) ||
          (a == 203 && b == 0)) bad = 1
    }
    END { exit bad ? 1 : 0 }
  '
}

# Run one local probe with a bounded wall clock without GNU `timeout`.
# The caller remains responsible for collecting and sanitizing stdout/stderr.
gdc_run_with_timeout() {
  [ "$#" -ge 2 ] || return 64
  gdc_timeout_seconds=$1
  shift
  case "$gdc_timeout_seconds" in ''|*[!0-9]*) return 64 ;; esac
  "$@" &
  gdc_timeout_pid=$!
  (
    sleep "$gdc_timeout_seconds"
    kill -TERM "$gdc_timeout_pid" 2>/dev/null || true
  ) >/dev/null 2>&1 &
  gdc_timeout_watchdog=$!
  if wait "$gdc_timeout_pid"; then
    gdc_timeout_rc=0
  else
    gdc_timeout_rc=$?
  fi
  kill -TERM "$gdc_timeout_watchdog" 2>/dev/null || true
  wait "$gdc_timeout_watchdog" 2>/dev/null || true
  return "$gdc_timeout_rc"
}

gdc_base64_decode() {
  [ "$#" -eq 1 ] || return 64
  if base64 -d <"$1" 2>/dev/null; then
    return 0
  fi
  base64 -D -i "$1"
}

gdc_file_size() {
  [ "$#" -eq 1 ] || return 64
  wc -c <"$1" | tr -d ' '
}

gdc_file_mode() {
  [ "$#" -eq 1 ] || return 64
  if stat -c %a "$1" >/dev/null 2>&1; then
    stat -c %a "$1"
  elif stat -f %Lp "$1" >/dev/null 2>&1; then
    stat -f %Lp "$1"
  else
    gdc_portable_die 'file-mode inspection is unavailable; need a POSIX-compatible stat backend'
  fi
}

# GNU sync accepts a path; BSD sync flushes all pending writes. Both provide
# the required durability boundary after an atomic receipt rename.
gdc_sync() {
  [ "$#" -eq 1 ] || return 64
  if sync -f "$1" >/dev/null 2>&1; then
    return 0
  fi
  sync
}

gdc_sed_inplace() {
  [ "$#" -eq 2 ] || return 64
  gdc_sed_expression=$1
  gdc_sed_file=$2
  gdc_sed_dir=$(dirname "$gdc_sed_file")
  gdc_sed_mode=$(gdc_file_mode "$gdc_sed_file") || return $?
  gdc_sed_tmp=$(mktemp "$gdc_sed_dir/.${gdc_sed_file##*/}.XXXXXX") || return $?
  if ! sed "$gdc_sed_expression" "$gdc_sed_file" >"$gdc_sed_tmp"; then
    rm -f "$gdc_sed_tmp"
    return 1
  fi
  chmod "$gdc_sed_mode" "$gdc_sed_tmp"
  mv "$gdc_sed_tmp" "$gdc_sed_file"
}

# JOIN receipt names are deliberately restricted by the recorder. Keeping the
# validation here lets callers use portable globbing without turning arbitrary
# filenames into a newline-delimited protocol.
gdc_latest_join_receipt_name() {
  [ "$#" -eq 1 ] || return 64
  gdc_receipt_dir=$1
  gdc_receipt_tmp=$(gdc_mktemp_dir) || return $?
  : >"$gdc_receipt_tmp/names"
  for gdc_receipt_path in "$gdc_receipt_dir"/[0-9][0-9][0-9][0-9]-*.json; do
    [ -f "$gdc_receipt_path" ] || continue
    gdc_receipt_name=${gdc_receipt_path##*/}
    if ! printf '%s\n' "$gdc_receipt_name" | grep -Eq '^[0-9]{4}-[a-z_]+\.json$'; then
      rm -rf "$gdc_receipt_tmp"
      return 65
    fi
    printf '%s\n' "$gdc_receipt_name" >>"$gdc_receipt_tmp/names"
  done
  [ -s "$gdc_receipt_tmp/names" ] || { rm -rf "$gdc_receipt_tmp"; return 1; }
  LC_ALL=C sort "$gdc_receipt_tmp/names" | tail -n 1
  gdc_receipt_rc=$?
  rm -rf "$gdc_receipt_tmp"
  return "$gdc_receipt_rc"
}

gdc_count_join_receipts() {
  [ "$#" -eq 1 ] || return 64
  gdc_receipt_count=0
  for gdc_receipt_path in "$1"/[0-9][0-9][0-9][0-9]-*.json; do
    [ -f "$gdc_receipt_path" ] || continue
    gdc_receipt_name=${gdc_receipt_path##*/}
    printf '%s\n' "$gdc_receipt_name" | grep -Eq '^[0-9]{4}-[a-z_]+\.json$' || return 65
    gdc_receipt_count=$((gdc_receipt_count + 1))
  done
  printf '%s\n' "$gdc_receipt_count"
}

# Enumerate a fixed filename no more than two directories below a trusted root
# without GNU find's -maxdepth. Symlinked files or directories are excluded.
gdc_find_regular_beneath_depth2() {
  [ "$#" -eq 2 ] || return 64
  gdc_find_root=$1
  gdc_find_name=$2
  [ -d "$gdc_find_root" ] && [ ! -L "$gdc_find_root" ] || return 1
  gdc_find_root=$(gdc_realpath_existing "$gdc_find_root") || return 1
  for gdc_find_candidate in \
    "$gdc_find_root/$gdc_find_name" \
    "$gdc_find_root"/*/"$gdc_find_name" \
    "$gdc_find_root"/*/*/"$gdc_find_name"; do
    [ -f "$gdc_find_candidate" ] && [ ! -L "$gdc_find_candidate" ] || continue
    gdc_find_resolved=$(gdc_realpath_existing "$gdc_find_candidate") || continue
    case "$gdc_find_resolved" in "$gdc_find_root"/*) ;; *) continue ;; esac
    gdc_find_parent=$gdc_find_candidate
    while [ "$gdc_find_parent" != "$gdc_find_root" ]; do
      [ ! -L "$gdc_find_parent" ] || break
      gdc_find_parent=$(dirname "$gdc_find_parent")
    done
    [ "$gdc_find_parent" = "$gdc_find_root" ] || continue
    printf '%s\n' "$gdc_find_candidate"
  done | LC_ALL=C sort
}

# Atomic mkdir is the cross-platform lifecycle lock. An existing directory is
# never removed automatically: it may belong to a live or interrupted process.
gdc_lock_acquire() {
  [ "$#" -eq 3 ] || return 64
  gdc_lock_state=$1
  gdc_lock_invocation=$2
  gdc_lock_command=$3
  gdc_lock_dir=$gdc_lock_state/.lifecycle.lock
  gdc_private_dir "$gdc_lock_state" || {
    printf 'lock_io_error: cannot create operator state directory\nmutation=none\n' >&2
    return 73
  }
  # Older operators used a regular file and advisory flock.  A probe followed
  # by unlink is inherently racy: an old process can acquire the file after
  # the probe, while its descriptor still refers to the inode being removed.
  # Fail closed until an operator has performed a separately verified,
  # quiescent migration. This preserves exclusion for every old descriptor.
  if [ -f "$gdc_lock_dir" ] && [ ! -L "$gdc_lock_dir" ]; then
    printf 'lock_contended: legacy lifecycle lock requires quiescent migration; inspect %s and retry after all legacy operators stop\nmutation=none\n' "$gdc_lock_dir" >&2
    return 75
  fi
  if mkdir "$gdc_lock_dir" 2>/dev/null; then
    GDC_LOCK_DIR=$gdc_lock_dir
    # mktemp supplies an ownership capability that is not predictable from a
    # PID and timestamp. Only the process holding this token may remove the
    # directory it created.
    gdc_lock_token_dir=$(gdc_mktemp_dir) || {
      rmdir "$GDC_LOCK_DIR" 2>/dev/null || true
      printf 'lock_io_error: cannot create lifecycle ownership token\nmutation=none\n' >&2
      return 73
    }
    GDC_LOCK_TOKEN=$(basename "$gdc_lock_token_dir")
    rmdir "$gdc_lock_token_dir" 2>/dev/null || true
    export GDC_LOCK_DIR GDC_LOCK_TOKEN
    {
      printf 'pid=%s\n' "$$"
      printf 'created_at=%s\n' "$(date -u +%FT%TZ)"
      printf 'invocation=%s\n' "$gdc_lock_invocation"
      printf 'command=%s\n' "$gdc_lock_command"
      printf 'token=%s\n' "$GDC_LOCK_TOKEN"
    } >"$GDC_LOCK_DIR/owner"
    chmod 0600 "$GDC_LOCK_DIR/owner"
    return 0
  fi
  if [ -d "$gdc_lock_dir" ]; then
    printf 'lock_contended: another lifecycle phase owns %s; inspect it before retrying\nmutation=none\n' "$gdc_lock_dir" >&2
    return 75
  fi
  printf 'lock_io_error: cannot create lifecycle lock\nmutation=none\n' >&2
  return 73
}

gdc_lock_release() {
  [ -n "${GDC_LOCK_DIR:-}" ] && [ -n "${GDC_LOCK_TOKEN:-}" ] || return 0
  [ -r "$GDC_LOCK_DIR/owner" ] || return 0
  gdc_lock_owner=$(sed -n 's/^token=//p' "$GDC_LOCK_DIR/owner")
  [ "$gdc_lock_owner" = "$GDC_LOCK_TOKEN" ] || return 0
  rm -f "$GDC_LOCK_DIR/owner"
  rmdir "$GDC_LOCK_DIR" 2>/dev/null || true
  unset GDC_LOCK_DIR GDC_LOCK_TOKEN
}

gdc_lock_inspect() {
  [ "$#" -eq 1 ] || return 64
  gdc_lock_dir=$1/.lifecycle.lock
  if [ -r "$gdc_lock_dir/owner" ]; then
    cat "$gdc_lock_dir/owner"
  elif [ -d "$gdc_lock_dir" ]; then
    # A present lock whose owner record cannot be read is still contention
    # evidence.  Never let callers mistake it for an absent lock and proceed
    # with a replacement mutation.
    printf 'lock_io_error: lifecycle lock owner record is missing or unreadable; inspect %s before retrying\nmutation=none\n' "$gdc_lock_dir" >&2
    return 73
  else
    printf 'owner=none\n'
    return 1
  fi
}
