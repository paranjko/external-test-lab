#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fake_bin="$tmp/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$GDC_TEST_SSH_LOG"
if [[ "$*" == *"--remote capture"* ]]; then
  cat >/dev/null
  exit 0
fi
if [[ "$*" == *gdc-identity-layout* ]]; then
  cat >/dev/null
  printf 'gdc-identity-layout=%s\n' "${GDC_TEST_IDENTITY_LAYOUT:-v2}"
  exit 0
fi
if [[ "$*" == *"bash -s"* ]]; then
  cat >"$GDC_TEST_REMOTE_SCRIPT"
fi
exit 0
EOF
chmod +x "$fake_bin/ssh"

# Host reset asks the chain whether the validator key is still bound to a
# participant before it destroys anything. These fixtures are unregistered.
cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
out=''; url=''
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == -o ]]; then j=$((i + 1)); out="${!j}"; fi
  [[ "${!i}" == http*://* ]] && url="${!i}"
  true
done
# Reset reads each seed's tip before it trusts a 404 about the participant.
if [[ "$url" == */status ]]; then
  case "$url" in
    *seed-b*) node_id=89abcdef0123456789abcdef0123456789abcdef ;;
    *) node_id=0123456789abcdef0123456789abcdef01234567 ;;
  esac
  printf '{"result":{"node_info":{"id":"%s","network":"gonka-devnet-community"},"sync_info":{"latest_block_height":"1000","catching_up":false}}}\n' "$node_id"
  exit 0
fi
if [[ "${GDC_TEST_PARTICIPANT_MODE:-absent}" == registered ]]; then
  printf '{"participant":{"address":"%s","status":1}}\n' "${url##*/}" >"${out:-/dev/null}"
  printf 200
else
  [[ -z "$out" ]] || : >"$out"
  printf 404
fi
EOF
chmod +x "$fake_bin/curl"

address='gonka1fixture0000000000000000000000000000000'
seed_chain_lookup() {
  local state="$1"
  mkdir -p "$state"
  printf '%s\n' '{"chain_id":"gonka-devnet-community","seeds":[{"node_id":"0123456789abcdef0123456789abcdef01234567","rpc":"https://seed-a.invalid/chain-rpc"},{"node_id":"89abcdef0123456789abcdef0123456789abcdef","rpc":"https://seed-b.invalid/chain-rpc"}]}' \
    >"$state/network-bootstrap.json"
}

run_reset() {
  local home="$1" alias="$2" remote_script="$3" participant="${4:-absent}"
  env -u GDC_ENV -u GDC_NODE_ALIASES GDC_HOME="$home" \
    GDC_TEST_REMOTE_SCRIPT="$remote_script" GDC_TEST_SSH_LOG="$tmp/ssh.log" \
    GDC_TEST_PARTICIPANT_MODE="$participant" PATH="$fake_bin:$PATH" \
    "$ROOT/gdc.sh" host reset "$alias"
}

alias=partial-node
partial_home="$tmp/partial-home"
partial_node_home="$partial_home/$alias"
mkdir -p "$partial_node_home/state/identities" "$partial_node_home/accounts" \
  "$partial_node_home/runs/retained" "$partial_home/mnemonics"
printf '{}\n' >"$partial_node_home/state/identities/$alias.json"
printf '{"address":"%s"}\n' "$address" >"$partial_node_home/accounts/$alias-cold.json"
seed_chain_lookup "$partial_node_home/state"
printf 'immutable evidence\n' >"$partial_node_home/runs/retained/result.json"
printf 'secret mnemonic canary\n' >"$partial_home/mnemonics/$alias-cold.mnemonic"

before="$("$ROOT/scripts/classify-join-state.sh" \
  "$partial_node_home/state/identities/$alias.json" \
  "$partial_node_home/accounts/$alias-cold.json" \
  "$partial_node_home/state/joined/$alias" '')"
jq -e '.classification == "partial_identity"' <<<"$before" >/dev/null
run_reset "$partial_home" "$alias" "$tmp/partial-remote.sh" >"$tmp/partial.out"

after="$("$ROOT/scripts/classify-join-state.sh" \
  "$partial_node_home/state/identities/$alias.json" \
  "$partial_node_home/accounts/$alias-cold.json" \
  "$partial_node_home/state/joined/$alias" '')"
jq -e '.classification == "new"' <<<"$after" >/dev/null
grep -Fq 'READY removed incomplete local and remote identity state for partial-node' "$tmp/partial.out"
grep -Fq "GDC_RESET_PARTIAL_IDENTITY='true' bash -s" "$tmp/ssh.log"
[[ -f "$partial_node_home/runs/retained/result.json" ]]
[[ "$(<"$partial_home/mnemonics/$alias-cold.mnemonic")" == 'secret mnemonic canary' ]]
# These are literal assertions against the captured remote program.
# shellcheck disable=SC2016
grep -Fq '[[ -z "$(docker ps -q --filter "label=com.docker.compose.project=$NODE" --filter label=com.docker.compose.service=tmkms)" ]]' "$tmp/partial-remote.sh"
# shellcheck disable=SC2016
grep -Fq 'rm -rf -- "/srv/dai/identity/$NODE" "/srv/dai/signer/$NODE"' "$tmp/partial-remote.sh"
# shellcheck disable=SC2016
grep -Fq 'rm -f -- "/srv/dai/identity-bootstrap/$NODE.json"' "$tmp/partial-remote.sh"
# shellcheck disable=SC2016
teardown_line="$(grep -n 'remove_compose_project "$NODE"' "$tmp/partial-remote.sh" | cut -d: -f1)"
# shellcheck disable=SC2016
identity_line="$(grep -n 'rm -rf -- "/srv/dai/identity/$NODE"' "$tmp/partial-remote.sh" | cut -d: -f1)"
[[ "$identity_line" -gt "$teardown_line" ]]
if grep -Eq '(/srv/dai/(genesis|edge)(/|"|$)|/srv/dai/identity-bootstrap/bootstrap\.env)' "$tmp/partial-remote.sh"; then
  echo 'partial identity cleanup escaped its alias-scoped remote paths' >&2
  exit 1
fi

alias=complete-node
complete_home="$tmp/complete-home"
complete_node_home="$complete_home/$alias"
mkdir -p "$complete_node_home/state/identities" "$complete_node_home/state/joined" \
  "$complete_node_home/accounts" "$complete_home/mnemonics"
printf '{"participant_address":"%s"}\n' "$address" >"$complete_node_home/state/identities/$alias.json"
printf '{"address":"%s"}\n' "$address" >"$complete_node_home/accounts/$alias-cold.json"
seed_chain_lookup "$complete_node_home/state"
: >"$complete_node_home/state/joined/$alias"
printf 'completed mnemonic canary\n' >"$complete_home/mnemonics/$alias-cold.mnemonic"
printf 'archive\n' >"$tmp/restore.tar"

run_reset "$complete_home" "$alias" "$tmp/complete-remote.sh" registered >"$tmp/complete.out"
[[ -s "$complete_node_home/state/identities/$alias.json" ]]
[[ -s "$complete_node_home/accounts/$alias-cold.json" ]]
[[ "$(<"$complete_home/mnemonics/$alias-cold.mnemonic")" == 'completed mnemonic canary' ]]
restore_classification="$("$ROOT/scripts/classify-join-state.sh" \
  "$complete_node_home/state/identities/$alias.json" \
  "$complete_node_home/accounts/$alias-cold.json" \
  "$complete_node_home/state/joined/$alias" "$tmp/restore.tar")"
jq -e '.classification == "running_matched"' <<<"$restore_classification" >/dev/null
if grep -Fq 'READY removed incomplete local and remote identity state' "$tmp/complete.out"; then
  echo 'completed identity was treated as partial identity' >&2
  exit 1
fi
grep -Fq "GDC_RESET_PARTIAL_IDENTITY='false' bash -s" "$tmp/ssh.log"

# A pre-signer failure has all three local identity files, because the joined
# marker is deliberately written before the signer starts. Its terminal
# result, rather than that marker alone, is the authority for a fresh reset.
alias=failed-join-node
failed_home="$tmp/failed-home"
failed_node_home="$failed_home/$alias"
failed_run_id=20260918T010101Z-fixture
mkdir -p "$failed_node_home/state/identities" "$failed_node_home/state/joined" \
  "$failed_node_home/accounts" "$failed_node_home/runs/$failed_run_id/join-$alias" "$failed_home/mnemonics"
printf '{"participant_address":"%s"}\n' "$address" >"$failed_node_home/state/identities/$alias.json"
printf '{"address":"%s"}\n' "$address" >"$failed_node_home/accounts/$alias-cold.json"
seed_chain_lookup "$failed_node_home/state"
: >"$failed_node_home/state/joined/$alias"
printf '%s\n' "$failed_run_id" >"$failed_node_home/state/active-run-id"
printf '{"outcome":"manual_recovery_required"}\n' >"$failed_node_home/runs/$failed_run_id/join-$alias/join-result.v1.json"
run_reset "$failed_home" "$alias" "$tmp/failed-remote.sh" >"$tmp/failed.out"
failed_classification="$("$ROOT/scripts/classify-join-state.sh" \
  "$failed_node_home/state/identities/$alias.json" \
  "$failed_node_home/accounts/$alias-cold.json" \
  "$failed_node_home/state/joined/$alias" '')"
jq -e '.classification == "new"' <<<"$failed_classification" >/dev/null
grep -Fq 'retained identity belongs to an incomplete JOIN run' "$tmp/failed.out"
grep -Fq "GDC_RESET_PARTIAL_IDENTITY='true' bash -s" "$tmp/ssh.log"

printf 'PASS Host reset clears only partial JOIN identity state and preserves completed restore identity\n'
