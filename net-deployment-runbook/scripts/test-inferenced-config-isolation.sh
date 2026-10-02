#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
umask 077
mkdir -p "$tmp/runbook/scripts" "$tmp/user/.inference/config" "$tmp/bin"
cp "$ROOT/scripts/inferenced.sh" "$tmp/runbook/scripts/"
cp "$ROOT/scripts/lib.sh" "$tmp/runbook/scripts/"
cat >"$tmp/runbook/scripts/profile.sh" <<'SH'
load_profiles() { GONKA_RELEASE=0.2.15; }
SH
cat >"$tmp/runbook/scripts/ensure-inferenced-cli.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$tmp/runbook/scripts/ensure-inferenced-cli.sh"
printf 'output = "json"\n' >"$tmp/user/.inference/config/client.toml"
if [[ -n "${INFERENCED_TEST_BINARY:-}" ]]; then
  cp "$INFERENCED_TEST_BINARY" "$tmp/bin/inferenced"
else
  # Model the early client-context read, before --home is applied.
  cat >"$tmp/bin/inferenced" <<'SH'
#!/usr/bin/env bash
set -eu
[[ "$1" == --home && "$2" == "$INFERENCED_TEST_EXPECTED_HOME" && "$HOME" == "$2" ]]
printf '%s\0' "$@" >"$INFERENCED_TEST_CALL_LOG"
if [[ -f "$HOME/.inference/config/client.toml" ]] && grep -q 'output = "json"' "$HOME/.inference/config/client.toml"; then
  printf '{"mnemonic":"unexpected-json"}\n'
else
  printf 'abandon ability able about above absent absorb abstract absurd abuse access accident abandon ability able about above absent absorb abstract absurd abuse access accident\n'
fi
SH
fi
chmod +x "$tmp/bin/inferenced"
run_case() {
  local operator_home="$1" label="$2" parent_home="$HOME"
  local -a cli_args
  mkdir -p "$operator_home/config"
  printf 'output = "text"\n' >"$operator_home/config/client.toml"
  if [[ "$label" == explicit ]]; then
    export INFERENCED_HOME="$operator_home"
  else
    unset INFERENCED_HOME
  fi
  printf 'fixture-password\nfixture-password\n' |
    HOME="$tmp/user" GDC_HOME="$tmp/data-$label" \
    INFERENCED_TEST_EXPECTED_HOME="$operator_home" INFERENCED_TEST_CALL_LOG="$tmp/$label.args" \
    GDC_INFERENCED_BIN_DIR="$tmp/bin" bash "$tmp/runbook/scripts/inferenced.sh" \
    keys add fixture-cold --keyring-backend file >"$tmp/$label.out" 2>&1
  count="$(awk 'NF == 24 {valid=1; for (i=1; i<=NF; i++) if ($i !~ /^[a-z]+$/) valid=0; if (valid) n++} END {print n+0}' "$tmp/$label.out")"
  [[ "$count" == 1 ]] || { echo "FAIL isolated mnemonic output: $label" >&2; exit 1; }
  grep -Fxq 'output = "json"' "$tmp/user/.inference/config/client.toml"
  [[ "$HOME" == "$parent_home" ]]
  [[ -d "$operator_home" && "$(stat -c %a "$operator_home")" == 700 ]]
  if [[ -z "${INFERENCED_TEST_BINARY:-}" ]]; then
    mapfile -d '' -t cli_args <"$tmp/$label.args"
    [[ ${#cli_args[@]} == 7 && "${cli_args[1]}" == "$operator_home" ]]
    [[ "${cli_args[*]:2}" == 'keys add fixture-cold --keyring-backend file' ]]
  fi
}
run_case "$tmp/operator with spaces" explicit
run_case "$tmp/data-default/state/operator-home" default
printf 'PASS inferenced home override and default isolate user config, preserve parent HOME and CLI arguments, and retain plaintext mnemonic extraction\n'
