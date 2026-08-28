#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/page-one.json" <<'JSON'
{"proposals":[{"id":"1","status":"PROPOSAL_STATUS_PASSED"}],"pagination":{"next_key":"page-two"}}
JSON
cat >"$tmp/page-two.json" <<'JSON'
{"proposals":[{"id":"101","status":"PROPOSAL_STATUS_VOTING_PERIOD","metadata":"target","messages":[{"@type":"/test.Msg"}]}],"pagination":{"next_key":null}}
JSON
cat >"$tmp/desired.json" <<'JSON'
{"metadata":"target","messages":[{"@type":"/test.Msg"}]}
JSON
cat >"$tmp/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
command_text="${2:-}"
if [[ "${PAGINATION_SCENARIO:-complete}" == cycle ]]; then
  printf '{"proposals":[],"pagination":{"next_key":"page-two"}}\n'
elif [[ "$command_text" == *'pagination.key=page-two'* ]]; then
  cat "$PAGINATION_FIXTURES/page-two.json"
else
  cat "$PAGINATION_FIXTURES/page-one.json"
fi
SH
chmod +x "$tmp/fake-ssh"

PAGINATION_FIXTURES="$tmp" GDC_SSH_BIN="$tmp/fake-ssh" \
  "$ROOT/scripts/fetch-governance-proposals.sh" gdc-node0 "$tmp/proposals.json"
jq -e '[.proposals[].id] == ["1", "101"]' "$tmp/proposals.json" >/dev/null
[[ "$("$ROOT/scripts/select-devshard-governance-proposal.sh" "$tmp/desired.json" "$tmp/proposals.json")" == 101 ]]

if PAGINATION_SCENARIO=cycle PAGINATION_FIXTURES="$tmp" GDC_SSH_BIN="$tmp/fake-ssh" \
  "$ROOT/scripts/fetch-governance-proposals.sh" gdc-node0 "$tmp/cycle.json" \
  >"$tmp/cycle.out" 2>"$tmp/cycle.err"; then
  echo 'cyclic governance pagination was accepted' >&2
  exit 1
fi
grep -Fq 'repeated a continuation key' "$tmp/cycle.err"

printf 'PASS complete governance proposal pagination\n'
