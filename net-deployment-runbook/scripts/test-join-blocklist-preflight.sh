#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
GUARD="$ROOT/scripts/preflight-join-blocklist.sh"

cat >"$tmp/bootstrap.json" <<'EOF'
{"$schema":"https://gonka-dev.net/v1.bootstrap.schema.json","chain_id":"gonka-devnet-community","genesis":{"sha256":"93c32ec403d59af6337c0d79c3ee16010c99394f8ecd9aee4fc72a898f64a9a6"},"seeds":[{"node_id":"0123456789abcdef0123456789abcdef01234567","rpc":"https://node0.example.test/chain-rpc","p2p":"tcp://node0.example.test:5000","api":"https://node0.example.test"},{"node_id":"89abcdef0123456789abcdef0123456789abcdef","rpc":"https://node1.example.test/chain-rpc","p2p":"tcp://node1.example.test:5000","api":"https://node1.example.test"}],"brokers":[]}
EOF
printf 'word one two three four five six seven eight nine ten eleven\n' >"$tmp/cold.mnemonic"
chmod 0600 "$tmp/cold.mnemonic"
mkdir -p "$tmp/bin"

cat >"$tmp/bin/fake-inferenced" <<'EOF'
#!/usr/bin/env bash
[[ "${FAKE_DERIVED_ADDRESS:-}" =~ ^gonka1[0-9a-z]{20,90}$ ]] || { echo 'fixture misconfigured: FAKE_DERIVED_ADDRESS' >&2; exit 1; }
[[ "${FAKE_DERIVE_FAILS:-false}" == true ]] && exit 1
mode=''; show_addr=false
args=("$@")
for i in "${!args[@]}"; do
  if [[ "${args[$i]}" == --home ]]; then
    unset "args[$i]"
    unset "args[$((i + 1))]"
    break
  fi
done
for a in "${args[@]}"; do
  case "$a" in
    keys) mode=keys ;;
    add) mode=add ;;
    show) mode=show ;;
    -a) show_addr=true ;;
  esac
done
case "$mode" in
  add) cat >/dev/null; exit 0 ;;
  show)
    if [[ "$show_addr" == true ]]; then
      printf '%s\n' "$FAKE_DERIVED_ADDRESS"
    else
      printf '%s\n' '{"key":"fixture-not-an-address-key"}'
    fi
    exit 0
    ;;
esac
echo "unexpected fixture CLI invocation: $*" >&2
exit 1
EOF
chmod 0755 "$tmp/bin/fake-inferenced"

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${!#}"
[[ -n "${BLOCKLIST_PARAMS_JSON:-}" ]] || exit 2
case "$url" in
  *'/chain-api/productscience/inference/inference/params') printf '%s\n' "$BLOCKLIST_PARAMS_JSON"; exit 0 ;;
  *) exit 2 ;;
esac
EOF
chmod 0755 "$tmp/bin/curl"

blocked_addr='gonka1blockedblockedblockedblockedblockedblockedb'
healthy_addr='gonka1healthyhealthyyhealthyhealthyhealthyhealthy12'

run_guard() {
  GDC_BLOCKLIST_INFERENCED_BIN="$tmp/bin/fake-inferenced" PATH="$tmp/bin:$PATH" \
    GDC_RUN_ID=fixture-run GDC_JOIN_NODE_NAME=node-c \
    "$GUARD" --mnemonic-file "$tmp/cold.mnemonic" --bootstrap-file "$tmp/bootstrap.json" --output "$@"
}

params() {
  jq -cn --argjson blocked "$1" '{params:{participant_access_params:{blocked_participant_addresses:$blocked}}}'
}

run_prompt_join() {
  local stdout_path="$1" stderr_path="$2"
  shift 2
  python3 - "$ROOT/gdc.sh" "$stdout_path" "$stderr_path" "$@" <<'PY'
import os
import pty
import subprocess
import sys

launcher, stdout_path, stderr_path, *arguments = sys.argv[1:]
master_fd, slave_fd = pty.openpty()
try:
    with open(stdout_path, "wb") as stdout, open(stderr_path, "wb") as stderr:
        process = subprocess.Popen(
            [launcher, *arguments],
            stdin=slave_fd,
            stdout=stdout,
            stderr=stderr,
            close_fds=True,
        )
        os.write(master_fd, (os.environ["FIXTURE_MNEMONIC"] + "\n").encode("utf-8"))
        exit_code = process.wait(timeout=15)
finally:
    os.close(master_fd)
    os.close(slave_fd)
sys.exit(exit_code)
PY
}

# A blocked mnemonic stops the run with a typed refusal receipt that never
# contains the derived address.
set +e
BLOCKLIST_PARAMS_JSON="$(params "[\"$blocked_addr\",\"$healthy_addr\"]")" FAKE_DERIVED_ADDRESS="$blocked_addr" \
  run_guard "$tmp/refusal.json" >"$tmp/blocked.out" 2>"$tmp/blocked.err"
rc=$?
set -e
[[ "$rc" == 65 ]]
[[ "$(stat -c %a "$tmp/refusal.json")" == 600 ]]
jq -e '
  .kind == "gdc-join-blocklist-refusal" and .reason == "mnemonic_participant_blocked" and
  .run_id == "fixture-run" and .node_name == "node-c" and (.summary | type == "string" and length > 0)
' "$tmp/refusal.json" >/dev/null
jq -e --arg address "$blocked_addr" '
  ([.. | strings] | join(" ") | contains($address) | not) and
  ([.. | strings] | join(" ") | contains("gonka1") | not)
' "$tmp/refusal.json" >/dev/null

# A clean mnemonic passes without writing a receipt.
rm -f "$tmp/refusal.json"
BLOCKLIST_PARAMS_JSON="$(params "[\"$blocked_addr\"]")" FAKE_DERIVED_ADDRESS="$healthy_addr" \
  run_guard "$tmp/refusal2.json" >"$tmp/clean.out" 2>"$tmp/clean.err"
[[ ! -e "$tmp/refusal2.json" ]]
[[ "$(<"$tmp/clean.out")" != *"$healthy_addr"* && "$(<"$tmp/clean.err")" != *"$healthy_addr"* ]]

# An empty blocked list is a valid answer.
BLOCKLIST_PARAMS_JSON="$(params "[]")" FAKE_DERIVED_ADDRESS="$healthy_addr" \
  run_guard "$tmp/refusal3.json" >/dev/null 2>&1

# Fail closed: no endpoint, an invalid response, and an unusable CLI each stop
# the run without a refusal receipt.
rm -f "$tmp/refusal4.json"
if BLOCKLIST_PARAMS_JSON='' FAKE_DERIVED_ADDRESS="$healthy_addr" \
  run_guard "$tmp/refusal4.json" >"$tmp/unreadable.out" 2>"$tmp/unreadable.err"; then
  echo 'the guard passed without a readable blocklist' >&2; exit 1
fi
[[ ! -e "$tmp/refusal4.json" ]]
if BLOCKLIST_PARAMS_JSON='{"params":{}}' FAKE_DERIVED_ADDRESS="$healthy_addr" \
  run_guard "$tmp/refusal5.json" >/dev/null 2>"$tmp/invalid.err"; then
  echo 'the guard passed with an invalid blocklist response' >&2; exit 1
fi
if BLOCKLIST_PARAMS_JSON="$(params "[]")" FAKE_DERIVE_FAILS=true FAKE_DERIVED_ADDRESS="$healthy_addr" \
  run_guard "$tmp/refusal6.json" >/dev/null 2>"$tmp/derive.err"; then
  echo 'the guard passed with an unusable CLI' >&2; exit 1
fi
[[ ! -e "$tmp/refusal6.json" ]]

# Exercise the launcher, not its source text: a blocked mnemonic must stop
# before either readiness or accelerator SSH could run, and it is not a
# reportable operational failure.
cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SSH_CALLS"
exit 97
EOF
chmod 0755 "$tmp/bin/ssh"
launcher_home="$tmp/launcher-home"
ssh_calls="$tmp/ssh.calls"
set +e
BLOCKLIST_PARAMS_JSON="$(params "[\"$blocked_addr\"]")" FAKE_DERIVED_ADDRESS="$blocked_addr" \
  GDC_BLOCKLIST_INFERENCED_BIN="$tmp/bin/fake-inferenced" PATH="$tmp/bin:$PATH" SSH_CALLS="$ssh_calls" \
  GDC_HOME="$launcher_home" "$ROOT/gdc.sh" host join --mnemonic-file "$tmp/cold.mnemonic" \
    --bootstrap-file "$tmp/bootstrap.json" --public-host node-c.example.test node-c \
    >"$tmp/launcher.out" 2>"$tmp/launcher.err"
launcher_rc=$?
set -e
[[ "$launcher_rc" == 65 ]]
[[ ! -e "$ssh_calls" ]]
[[ ! -e "$launcher_home/reporting/failures/latest-failure" ]]
awk '
  /use a new eligible cold mnemonic/ { replacement=1 }
  /gdc report github/ { report_hint=1 }
  END { exit !(replacement && !report_hint) }
' "$tmp/launcher.err"
result="$(find "$launcher_home/node-c/runs" -type f -name join-result.v1.json -print -quit)"
[[ -n "$result" ]]
jq -e '.outcome == "refused" and .reason == "mnemonic_participant_blocked" and .mutation == "none" and .signer_state == "absent"' "$result" >/dev/null

# In contrast, an unreadable chain blocklist is an operational preflight
# failure. It remains fail-closed before SSH, but it is reportable because an
# operator cannot decide whether the mnemonic is eligible from local input.
unreadable_home="$tmp/unreadable-home"
unreadable_ssh_calls="$tmp/unreadable-ssh.calls"
set +e
BLOCKLIST_PARAMS_JSON='' FAKE_DERIVED_ADDRESS="$healthy_addr" \
  GDC_BLOCKLIST_INFERENCED_BIN="$tmp/bin/fake-inferenced" PATH="$tmp/bin:$PATH" SSH_CALLS="$unreadable_ssh_calls" \
  GDC_HOME="$unreadable_home" "$ROOT/gdc.sh" host join --mnemonic-file "$tmp/cold.mnemonic" \
    --bootstrap-file "$tmp/bootstrap.json" --public-host node-unreadable.example.test node-unreadable \
    >"$tmp/unreadable-launcher.out" 2>"$tmp/unreadable-launcher.err"
unreadable_rc=$?
set -e
[[ "$unreadable_rc" != 0 ]]
[[ ! -e "$unreadable_ssh_calls" ]]
[[ -f "$unreadable_home/reporting/failures/latest-failure" ]]
awk '
  /checkpoint=blocklist-readback/ { checkpoint=1 }
  /gonka1healthy|word one two/ { leaked=1 }
  END { exit !(checkpoint && !leaked) }
' "$tmp/unreadable-launcher.err"
unreadable_result="$(find "$unreadable_home/node-unreadable/runs" -type f -name join-result.v1.json -print -quit)"
[[ -n "$unreadable_result" ]]
jq -e '.outcome == "refused" and .reason == "join_preflight_failed" and .mutation == "none" and .signer_state == "absent"' "$unreadable_result" >/dev/null

# The prompt form reaches exactly the same persisted-mnemonic and blocklist
# guard path.  A pseudo-terminal is required by the production reader; use
# Python's standard-library pty support because python3 is already declared in
# the CI command baseline.  This is a behavioral launcher test, not a source
# text assertion, and it must still stop before SSH or a report candidate.
prompt_home="$tmp/prompt-home"
prompt_ssh_calls="$tmp/prompt-ssh.calls"
set +e
BLOCKLIST_PARAMS_JSON="$(params "[\"$blocked_addr\"]")" FAKE_DERIVED_ADDRESS="$blocked_addr" \
  GDC_BLOCKLIST_INFERENCED_BIN="$tmp/bin/fake-inferenced" PATH="$tmp/bin:$PATH" SSH_CALLS="$prompt_ssh_calls" \
  GDC_HOME="$prompt_home" FIXTURE_MNEMONIC='word one two three four five six seven eight nine ten eleven' \
  run_prompt_join "$tmp/prompt.out" "$tmp/prompt.err" \
    host join --mnemonic-prompt --bootstrap-file "$tmp/bootstrap.json" \
    --public-host node-prompt.example.test node-prompt
prompt_rc=$?
set -e
[[ "$prompt_rc" == 65 ]]
[[ ! -e "$prompt_ssh_calls" ]]
[[ ! -e "$prompt_home/reporting/failures/latest-failure" ]]
awk '
  /use a new eligible cold mnemonic/ { replacement=1 }
  /gdc report github/ { report_hint=1 }
  END { exit !(replacement && !report_hint) }
' "$tmp/prompt.err"
prompt_result="$(find "$prompt_home/node-prompt/runs" -type f -name join-result.v1.json -print -quit)"
[[ -n "$prompt_result" ]]
jq -e '.outcome == "refused" and .reason == "mnemonic_participant_blocked" and .mutation == "none" and .signer_state == "absent"' "$prompt_result" >/dev/null
prompt_retained_mnemonic="$prompt_home/node-prompt/mnemonics/node-prompt-cold.mnemonic"
[[ -f "$prompt_retained_mnemonic" && ! -L "$prompt_retained_mnemonic" ]]
[[ "$(stat -c %a "$prompt_retained_mnemonic")" == 600 ]]
[[ "$(<"$prompt_retained_mnemonic")" == 'word one two three four five six seven eight nine ten eleven' ]]

# The complementary prompt case reaches Host readiness when the derived
# address is absent from the current list.  The fixture's SSH failure is the
# expected stop and proves the blocklist guard did not turn an eligible
# mnemonic into a hidden rejection.
prompt_allowed_home="$tmp/prompt-allowed-home"
prompt_allowed_ssh_calls="$tmp/prompt-allowed-ssh.calls"
set +e
BLOCKLIST_PARAMS_JSON="$(params "[\"$blocked_addr\"]")" FAKE_DERIVED_ADDRESS="$healthy_addr" \
  GDC_BLOCKLIST_INFERENCED_BIN="$tmp/bin/fake-inferenced" PATH="$tmp/bin:$PATH" SSH_CALLS="$prompt_allowed_ssh_calls" \
  GDC_HOME="$prompt_allowed_home" FIXTURE_MNEMONIC='word one two three four five six seven eight nine ten eleven' \
  run_prompt_join "$tmp/prompt-allowed.out" "$tmp/prompt-allowed.err" \
    host join --mnemonic-prompt --bootstrap-file "$tmp/bootstrap.json" \
    --public-host node-prompt-allowed.example.test node-prompt-allowed
prompt_allowed_rc=$?
set -e
[[ "$prompt_allowed_rc" == 97 ]]
[[ -s "$prompt_allowed_ssh_calls" ]]
awk '
  /mnemonic_participant_blocked/ { blocked=1 }
  /checkpoint=host-readiness/ { readiness=1 }
  END { exit !(readiness && !blocked) }
' "$tmp/prompt-allowed.err"

printf 'test-join-blocklist-preflight: PASS\n'
