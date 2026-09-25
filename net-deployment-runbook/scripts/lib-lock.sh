#!/usr/bin/env bash
# Directory locks use only POSIX filesystem primitives.  The caller owns the
# EXIT trap and must release the directory returned in GDC_LOCK_DIR.

gdc_lock_acquire() {
  local timeout_seconds="${2:-0}" busy_message="${3:-another operation is already running}"
  local lock_dir="${1}.d" pid_file pid entries

  [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || {
    printf 'invalid lock timeout: %s\n' "$timeout_seconds" >&2
    return 2
  }

  while ! mkdir -m 0700 -- "$lock_dir" 2>/dev/null; do
    [[ -d "$lock_dir" && ! -L "$lock_dir" ]] || {
      printf 'lock path is unsafe: %s\n' "$lock_dir" >&2
      return 2
    }
    entries="$(find "$lock_dir" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null || true)"
    pid_file="$lock_dir/pid"
    if [[ -z "$entries" ]]; then
      # mkdir(2) and creating pid are separate operations. A concurrent caller
      # can observe this short initialization interval; wait rather than
      # misclassifying a valid lock as corruption.
      if (( timeout_seconds == 0 || SECONDS >= timeout_seconds )); then
        printf '%s\n' "$busy_message" >&2
        return 1
      fi
      sleep 1
      continue
    fi
    [[ "$entries" == pid && -f "$pid_file" && ! -L "$pid_file" ]] || {
      printf 'lock directory is incomplete or unsafe: %s\n' "$lock_dir" >&2
      return 2
    }
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
      if (( timeout_seconds == 0 || SECONDS >= timeout_seconds )); then
        printf '%s\n' "$busy_message" >&2
        return 1
      fi
      sleep 1
      continue
    fi

    [[ "$entries" == pid ]] || {
      printf 'stale lock directory has unsafe contents: %s\n' "$lock_dir" >&2
      return 2
    }
    rm -f -- "$pid_file"
    rmdir -- "$lock_dir" 2>/dev/null || continue
  done

  pid_file="$lock_dir/pid"
  if ! printf '%s\n' "$$" >"$pid_file"; then
    rmdir -- "$lock_dir" 2>/dev/null || true
    printf 'could not initialize lock: %s\n' "$lock_dir" >&2
    return 2
  fi
  # shellcheck disable=SC2034 # The caller reads this result after acquiring the lock.
  GDC_LOCK_DIR="$lock_dir"
}

gdc_lock_release() {
  local lock_dir="${1:-}" pid_file pid
  [[ -n "$lock_dir" && -d "$lock_dir" && ! -L "$lock_dir" ]] || return 0
  pid_file="$lock_dir/pid"
  [[ -f "$pid_file" && ! -L "$pid_file" ]] || return 0
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  [[ "$pid" == "$$" ]] || return 0
  rm -f -- "$pid_file"
  rmdir -- "$lock_dir" 2>/dev/null || true
}
