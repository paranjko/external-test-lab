#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bootstrap.json" <<'EOF'
{"$schema":"https://gonka-dev.net/v1.bootstrap.schema.json","chain_id":"gonka-devnet-community","genesis":{"sha256":"93c32ec403d59af6337c0d79c3ee16010c99394f8ecd9aee4fc72a898f64a9a6"},"seeds":[{"node_id":"0123456789abcdef0123456789abcdef01234567","rpc":"https://node0.example.test/chain-rpc","p2p":"tcp://node0.example.test:5000","api":"https://node0.example.test"},{"node_id":"89abcdef0123456789abcdef0123456789abcdef","rpc":"https://node1.example.test/chain-rpc","p2p":"tcp://node1.example.test:5000","api":"https://node1.example.test"}],"brokers":[]}
EOF
printf 'word one two three four five six seven eight nine ten eleven\n' >"$tmp/cold.mnemonic"
chmod 0600 "$tmp/cold.mnemonic"

cat >"$tmp/bin/fake-inferenced" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
args=("$@")
for i in "${!args[@]}"; do
  if [[ "${args[$i]}" == --home ]]; then
    unset "args[$i]" "args[$((i + 1))]"
    break
  fi
done
mode=''; show_addr=false
for arg in "${args[@]}"; do
  case "$arg" in
    keys) mode=keys ;;
    add) mode=add ;;
    show) mode=show ;;
    -a) show_addr=true ;;
  esac
done
case "$mode" in
  add) cat >/dev/null; exit 0 ;;
  show)
    [[ "$show_addr" == true ]] || { echo 'unexpected key display mode' >&2; exit 1; }
    printf '%s\n' "$FIXTURE_BLOCKED_ADDRESS"
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
case "$url" in
  https://node0.example.test/chain-api/productscience/inference/inference/params)
    printf '%s\n' "$BLOCKLIST_PARAMS_JSON"
    ;;
  *) echo "unexpected fixture curl URL: $url" >&2; exit 90 ;;
esac
EOF
chmod 0755 "$tmp/bin/curl"

cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SSH_CALLS"
echo "unexpected SSH during a blocked-mnemonic refusal: $*" >&2
exit 97
EOF
chmod 0755 "$tmp/bin/ssh"

blocked_address='gonka1blockedblockedblockedblockedblockedblockedb'
params="$(jq -cn --arg address "$blocked_address" \
  '{params:{participant_access_params:{blocked_participant_addresses:[$address]}}}')"
launcher_home="$tmp/operator"
ssh_calls="$tmp/ssh.calls"
set +e
BLOCKLIST_PARAMS_JSON="$params" FIXTURE_BLOCKED_ADDRESS="$blocked_address" \
  GDC_BLOCKLIST_INFERENCED_BIN="$tmp/bin/fake-inferenced" PATH="$tmp/bin:$PATH" \
  SSH_CALLS="$ssh_calls" GDC_HOME="$launcher_home" \
  "$ROOT/gdc.sh" host join --mnemonic-file "$tmp/cold.mnemonic" \
    --bootstrap-file "$tmp/bootstrap.json" --public-host node-c.example.test node-c \
    >"$tmp/join.out" 2>"$tmp/join.err"
rc=$?
set -e

if [[ "$rc" != 65 ]]; then
  sed -n '1,120p' "$tmp/join.err" >&2
  echo "blocked mnemonic returned $rc instead of 65" >&2
  exit 1
fi
expected='REFUSED the supplied mnemonic derives a participant address currently blocked from operating a validator; use a new eligible cold mnemonic and do not retry this one'
mapfile -t errors <"$tmp/join.err"
if [[ "${#errors[@]}" != 1 || "${errors[0]:-}" != "$expected" ]]; then
  sed -n '1,120p' "$tmp/join.err" >&2
  echo 'blocked mnemonic refusal did not produce the exact single expected line' >&2
  exit 1
fi
! grep -Eiq 'gdc report github|reporting/|latest-failure|/home/|/tmp/' "$tmp/join.out" "$tmp/join.err"
[[ ! -e "$ssh_calls" ]]
[[ ! -e "$launcher_home/reporting/failures/latest-failure" ]]

result="$(find "$launcher_home/node-c/runs" -type f -name join-result.v1.json -print -quit)"
receipt="$(find "$launcher_home/node-c/runs" -type f -name blocklist-refusal.v1.json -print -quit)"
[[ -n "$result" && -n "$receipt" ]]
jq -e '.outcome == "refused" and .reason == "mnemonic_participant_blocked" and .mutation == "none" and .signer_state == "absent"' "$result" >/dev/null
jq -e --arg address "$blocked_address" '
  .kind == "gdc-join-blocklist-refusal" and .reason == "mnemonic_participant_blocked" and
  ([.. | strings] | join(" ") | contains($address) | not)
' "$receipt" >/dev/null

# Prompt input follows the same fail-closed path; feed it through a PTY as the
# production prompt reader requires and assert the identical single sentence.
prompt_home="$tmp/prompt-operator"
prompt_ssh_calls="$tmp/prompt-ssh.calls"
set +e
BLOCKLIST_PARAMS_JSON="$params" FIXTURE_BLOCKED_ADDRESS="$blocked_address" \
  GDC_BLOCKLIST_INFERENCED_BIN="$tmp/bin/fake-inferenced" PATH="$tmp/bin:$PATH" \
  SSH_CALLS="$prompt_ssh_calls" GDC_HOME="$prompt_home" \
  FIXTURE_MNEMONIC='word one two three four five six seven eight nine ten eleven' \
  python3 - "$ROOT/gdc.sh" "$tmp/prompt.out" "$tmp/prompt.err" \
    --mnemonic-prompt --bootstrap-file "$tmp/bootstrap.json" \
    --public-host node-prompt.example.test node-prompt <<'PY'
import os
import pty
import subprocess
import sys

launcher, stdout_path, stderr_path, *arguments = sys.argv[1:]
master_fd, slave_fd = pty.openpty()
try:
    with open(stdout_path, "wb") as stdout, open(stderr_path, "wb") as stderr:
        process = subprocess.Popen(
            [launcher, "host", "join", *arguments],
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
prompt_rc=$?
set -e
[[ "$prompt_rc" == 65 ]]
if [[ "$(grep -Fxc "$expected" "$tmp/prompt.err")" != 1 || "$(grep -c '^REFUSED ' "$tmp/prompt.err")" != 1 ]]; then
  sed -n '1,20p' "$tmp/prompt.err" >&2
  echo 'mnemonic prompt refusal did not produce exactly one expected refusal sentence' >&2
  exit 1
fi
! grep -Eiq 'gdc report github|reporting/|latest-failure|/home/|/tmp/' "$tmp/prompt.out" "$tmp/prompt.err"
! grep -Fq 'END host join REFUSED' "$tmp/prompt.err"
[[ ! -e "$prompt_ssh_calls" ]]
[[ ! -e "$prompt_home/reporting/failures/latest-failure" ]]
prompt_result="$(find "$prompt_home/node-prompt/runs" -type f -name join-result.v1.json -print -quit)"
[[ -n "$prompt_result" ]]
jq -e '.outcome == "refused" and .reason == "mnemonic_participant_blocked" and .mutation == "none" and .signer_state == "absent"' "$prompt_result" >/dev/null
prompt_retained_mnemonic="$prompt_home/node-prompt/mnemonics/node-prompt-cold.mnemonic"
[[ -f "$prompt_retained_mnemonic" && ! -L "$prompt_retained_mnemonic" ]]
[[ "$(stat -c %a "$prompt_retained_mnemonic")" == 600 ]]

printf 'PASS blocked mnemonic file and prompt refusals are one line, non-reportable, and before SSH\n'
