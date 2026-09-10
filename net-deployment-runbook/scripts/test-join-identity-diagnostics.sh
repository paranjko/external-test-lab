#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

# The warm key capture holds the mnemonic: report a category, never the output.
grep -Fq 'Cannot create warm key: reason=%s' "$ROOT/02-node/init-identity.sh"
if grep -Fq 'cat "$key_output"' "$ROOT/02-node/init-identity.sh"; then
  echo 'warm-key CLI output must not be relayed' >&2
  exit 1
fi

# Classifiers ignore Cobra usage. Usage lines are verbatim from inferenced 0.2.15.
# shellcheck source=/dev/null
source <(sed -n '/^cli_error_lines()/,/^}/p; /^warm_key_creation_failure_reason()/,/^}/p; /^warm_key_restore_failure_reason()/,/^}/p' "$ROOT/02-node/init-identity.sh")

usage_block() {
  cat <<'EOF'
Usage:
  inferenced keys add <name> [flags]

Flags:
  -i, --interactive              Interactively prompt user for BIP39 passphrase and mnemonic
      --multisig strings         List of key names stored in keyring to construct a public legacy multisig key
      --no-backup                Don't print out seed phrase (if others are watching the terminal)
      --recover                  Provide seed phrase to recover existing key instead of creating
      --source string            Import mnemonic from a file (only usable when recover or interactive is passed)

Global Flags:
      --keyring-backend string   Select keyring's backend (os|file|kwallet|pass|test|memory) (default "test")
      --keyring-dir string       The client Keyring directory; if omitted, the default 'home' directory will be used

EOF
}
cli_fixture() {
  local name="$1"
  shift
  { usage_block; printf '%s\n' "$@"; } >"$tmp/$name"
}
expect_reason() {
  local classifier="$1" fixture="$2" expected="$3" actual
  actual="$("$classifier" "$tmp/$fixture")"
  [[ "$actual" == "$expected" ]] || {
    printf 'FAIL %s on %s: got %s, expected %s\n' "$classifier" "$fixture" "$actual" "$expected" >&2
    exit 1
  }
}

cli_fixture missing-argument 'accepts 1 arg(s), received 0'
cli_fixture unknown-flag 'unknown flag: --no-such-flag'
cli_fixture keyring-path 'open /root/.inference/keyring-file/warm.info: permission denied'
cli_fixture wrong-passphrase 'too many failed passphrase attempts' 'incorrect passphrase' 'EOF' 'EOF'
cli_fixture invalid-mnemonic 'invalid mnemonic'
printf 'SIGILL: illegal instruction\nCaught SIGILL in blst_cgo_init\n' >"$tmp/runtime-abort"

expect_reason warm_key_creation_failure_reason missing-argument inferenced_rejected_key_creation
expect_reason warm_key_creation_failure_reason unknown-flag inferenced_rejected_key_creation
expect_reason warm_key_creation_failure_reason keyring-path inferenced_rejected_key_creation
expect_reason warm_key_creation_failure_reason wrong-passphrase keyring_authentication_failed
expect_reason warm_key_creation_failure_reason runtime-abort inferenced_runtime_aborted
expect_reason warm_key_restore_failure_reason missing-argument inferenced_rejected_recovery
expect_reason warm_key_restore_failure_reason unknown-flag inferenced_rejected_recovery
expect_reason warm_key_restore_failure_reason invalid-mnemonic mnemonic_rejected
expect_reason warm_key_restore_failure_reason wrong-passphrase keyring_authentication_failed

# Lookup retries transport errors and 5xx, stops on other statuses, never waits after the last try.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
count=$(( $(cat "${FAKE_CURL_CALLS:?}") + 1 ))
printf '%s' "$count" >"$FAKE_CURL_CALLS"
reply="$(sed -n "${count}p" "${FAKE_CURL_REPLIES:?}")"
[[ -n "$reply" ]] || reply="$(tail -n1 "$FAKE_CURL_REPLIES")"
body=''
while (($#)); do
  case "$1" in
    -o) body="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$reply" in
  exit:*) printf '000'; exit "${reply#exit:}" ;;
  *) [[ -z "$body" ]] || printf '{}' >"$body"; printf '%s' "$reply" ;;
esac
EOF
chmod +x "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH" FAKE_CURL_CALLS="$tmp/calls" FAKE_CURL_REPLIES="$tmp/replies"

participant_attempt=0
participant_curl_exit=0
participant_http_status=''
sleeps=0
# shellcheck source=/dev/null
source <(sed -n '/^lookup_participant()/,/^}/p' "$ROOT/scripts/phase-join.sh")
sleep() { sleeps=$((sleeps + 1)); }
run_lookup() {
  printf '%s\n' "$@" >"$FAKE_CURL_REPLIES"
  printf 0 >"$FAKE_CURL_CALLS"
  sleeps=0
  lookup_participant https://genesis.example.test/v2/participants/gonka1fixture "$tmp/body" "$tmp/stderr" >"$tmp/lookup.log"
}
expect_lookup() {
  local status="$1" curl_exit="$2" attempts="$3" waits="$4"
  [[ "$participant_http_status" == "$status" && "$participant_curl_exit" == "$curl_exit" && "$participant_attempt" == "$attempts" && "$sleeps" == "$waits" ]] || {
    printf 'FAIL participant lookup: status=%s curl_exit=%s attempts=%s waits=%s, expected %s %s %s %s\n' \
      "$participant_http_status" "$participant_curl_exit" "$participant_attempt" "$sleeps" "$status" "$curl_exit" "$attempts" "$waits" >&2
    exit 1
  }
  [[ "$(grep -c '^WAIT' "$tmp/lookup.log" || true)" == "$waits" ]] || {
    echo 'FAIL participant lookup: every wait must be announced, and only waits' >&2
    exit 1
  }
}

run_lookup 404
expect_lookup 404 0 1 0
run_lookup 200
expect_lookup 200 0 1 0
run_lookup 502 503 200
expect_lookup 200 0 3 2
run_lookup exit:28 exit:6 404
expect_lookup 404 0 3 2
run_lookup 403
expect_lookup 403 0 1 0
run_lookup 504
expect_lookup 504 0 6 5
run_lookup exit:28
expect_lookup 000 28 6 5

printf 'PASS JOIN identity bootstrap and participant lookup diagnostics\n'
