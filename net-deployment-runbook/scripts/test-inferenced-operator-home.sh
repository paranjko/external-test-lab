#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/runbook/scripts" "$tmp/bin" "$tmp/state"
cp "$ROOT/scripts/inferenced.sh" "$tmp/runbook/scripts/inferenced.sh"
cat >"$tmp/runbook/scripts/lib.sh" <<'SH'
STATE="$GDC_HOME/state"
SH
cat >"$tmp/runbook/scripts/profile.sh" <<'SH'
load_profiles() { GONKA_RELEASE=fixture-release; }
SH
cat >"$tmp/runbook/scripts/ensure-inferenced-cli.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$tmp/bin/inferenced" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == --home && "$3" == --keyring-dir && "$4" == "$2" ]]
[[ -d "$4/keyring-file" ]]
printf '%s\0' "$@" >"$INFERENCED_TEST_ARGS"
SH
chmod 0755 "$tmp/runbook/scripts/ensure-inferenced-cli.sh" "$tmp/bin/inferenced"
mkdir -p "$tmp/operator state/keyring-file" "$tmp/gdc-data/state/operator-home/keyring-file"

INFERENCED_TEST_STATE="$tmp/state" \
  INFERENCED_HOME="$tmp/operator state" \
  INFERENCED_TEST_ARGS="$tmp/args" GDC_HOME="$tmp/gdc-data" \
  GDC_INFERENCED_BIN_DIR="$tmp/bin" GDC_JOIN_PROFILE='' \
  bash "$tmp/runbook/scripts/inferenced.sh" keys show operator -a --keyring-backend file

mapfile -d '' -t args <"$tmp/args"
[[ ${#args[@]} == 10 ]] || { printf 'unexpected CLI argument count: %s\n' "${#args[@]}" >&2; exit 1; }
[[ "${args[0]}" == --home && "${args[1]}" == "$tmp/operator state" ]]
[[ "${args[2]}" == --keyring-dir && "${args[3]}" == "$tmp/operator state" ]]
[[ "${args[*]:4}" == 'keys show operator -a --keyring-backend file' ]]
[[ -d "$tmp/operator state" && "$(stat -c %a "$tmp/operator state")" == 700 ]]
(
  unset INFERENCED_HOME
  INFERENCED_TEST_STATE="$tmp/state" INFERENCED_TEST_ARGS="$tmp/default-args" \
    GDC_HOME="$tmp/gdc-data" GDC_INFERENCED_BIN_DIR="$tmp/bin" GDC_JOIN_PROFILE='' \
    bash "$tmp/runbook/scripts/inferenced.sh" keys show operator -a --keyring-backend file
)
mapfile -d '' -t default_args <"$tmp/default-args"
[[ "${default_args[1]}" == "$tmp/gdc-data/state/operator-home" ]]
[[ "${default_args[3]}" == "$tmp/gdc-data/state/operator-home" ]]
if INFERENCED_TEST_STATE="$tmp/state" \
  INFERENCED_HOME="$tmp/operator state" INFERENCED_TEST_ARGS="$tmp/rejected-args" \
  GDC_HOME="$tmp/gdc-data" GDC_INFERENCED_BIN_DIR="$tmp/bin" GDC_JOIN_PROFILE='' \
  bash "$tmp/runbook/scripts/inferenced.sh" keys show operator --home "$tmp/other" \
  >"$tmp/rejected.out" 2>&1; then
  echo 'wrapper accepted a caller-supplied home override' >&2
  exit 1
fi
grep -Fq 'inferenced home and keyring directory are bound to INFERENCED_HOME' "$tmp/rejected.out"
[[ ! -e "$tmp/rejected-args" ]]
printf 'PASS inferenced uses explicit operator home and keyring paths without rewriting process environment\n'
