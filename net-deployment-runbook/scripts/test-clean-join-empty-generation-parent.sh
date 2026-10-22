#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
sed -n '/^# BEGIN check-empty-generation-parent$/,/^# END check-empty-generation-parent$/p' \
  "$ROOT/00-host-prep/check-join-target-clean.sh" | sed '1d;$d' >"$tmp/check-function.sh"
source "$tmp/check-function.sh"
grep -Fq 'check_empty_generation_parent /srv/dai/data.generations || exit $?' \
  "$ROOT/00-host-prep/check-join-target-clean.sh"

check_empty_generation_parent "$tmp/absent"
mkdir -p "$tmp/empty"
check_empty_generation_parent "$tmp/empty"

mkdir -p "$tmp/nonempty/nested"
printf 'retained state\n' >"$tmp/nonempty/nested/state"
if check_empty_generation_parent "$tmp/nonempty" >"$tmp/nonempty.out"; then
  echo 'clean-target accepted a non-empty data.generations parent' >&2; exit 1
fi
grep -Fq "retained_node_state=$tmp/nonempty/nested" "$tmp/nonempty.out"

mkdir -p "$tmp/symlink-target"
ln -s "$tmp/symlink-target" "$tmp/symlink"
if check_empty_generation_parent "$tmp/symlink" >"$tmp/symlink.out"; then
  echo 'clean-target accepted a symlinked data.generations parent' >&2; exit 1
fi
grep -Fq "retained_node_state=$tmp/symlink" "$tmp/symlink.out"

printf 'not a directory\n' >"$tmp/not-directory"
if check_empty_generation_parent "$tmp/not-directory" >"$tmp/not-directory.out"; then
  echo 'clean-target accepted a non-directory data.generations path' >&2; exit 1
fi

stat() {
  if [[ "${*: -1}" == "$tmp/mounted" ]]; then printf '%s\n' "$tmp/mounted"; else command stat "$@"; fi
}
mkdir -p "$tmp/mounted"
if check_empty_generation_parent "$tmp/mounted" >"$tmp/mounted.out"; then
  echo 'clean-target accepted a mounted data.generations parent' >&2; exit 1
fi
grep -Fq "mounted_generation_parent=$tmp/mounted" "$tmp/mounted.out"

printf 'PASS empty generation parent clean-target boundary\n'
