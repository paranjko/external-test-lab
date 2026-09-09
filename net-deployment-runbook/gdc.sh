#!/bin/sh
# POSIX bootstrap for the supported local Host-operator commands.  The
# implementation deliberately requires Bash >= 5; macOS /bin/bash is 3.2.
set -eu

launcher=$0
case "$launcher" in
  /*) ;;
  *) launcher=$(pwd -P)/$launcher ;;
esac
while [ -L "$launcher" ]; do
  link=$(readlink "$launcher") || {
    printf 'path_resolution_failed: gdc launcher path must exist\nmutation=none\n' >&2
    exit 66
  }
  case "$link" in
    /*) launcher=$link ;;
    *) launcher=$(dirname "$launcher")/$link ;;
  esac
done
root=$(CDPATH='' cd -P "$(dirname "$launcher")" && pwd -P)
. "$root/scripts/portable.sh"
gdc_require_jq || exit $?

is_bash5() {
  "$1" -c 'case ${BASH_VERSINFO[0]:-0} in [5-9]|[1-9][0-9]*) exit 0;; *) exit 1;; esac' >/dev/null 2>&1
}

path_bash=$(command -v bash 2>/dev/null || true)
bash_bin=$path_bash
if [ -n "$bash_bin" ] && ! is_bash5 "$bash_bin"; then
  bash_bin=
fi
if [ -z "$bash_bin" ]; then
  for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [ -x "$candidate" ] && is_bash5 "$candidate"; then
      bash_bin=$candidate
      break
    fi
  done
fi
if [ -z "$bash_bin" ]; then
  printf 'dependency_missing: Bash >= 5 is required by the local Host-operator layer; install with brew install bash jq\nmutation=none\n' >&2
  exit 69
fi

case "${0##*/}" in
  gdc.sh) export GDC_USAGE_COMMAND='./gdc.sh' ;;
  *) export GDC_USAGE_COMMAND="${0##*/}" ;;
esac
# Child scripts use #!/usr/bin/env bash. When the PATH Bash was rejected and
# a fixed fallback was selected, put that fallback first for nested phases.
# Preserve the caller's PATH ordering when its Bash already passed validation;
# callers commonly provide hermetic helper commands (for example curl).
if [ "$bash_bin" != "$path_bash" ]; then
  bash_dir=$(dirname "$bash_bin")
  PATH="$bash_dir:$PATH"
  export PATH
fi
exec "$bash_bin" "$root/gdc-bash.sh" "$@"
