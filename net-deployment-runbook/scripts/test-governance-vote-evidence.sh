#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/expected.json" <<'EOF'
[
  {"address":"gonka1alpha","option":"VOTE_OPTION_YES"},
  {"address":"gonka1beta","option":"VOTE_OPTION_YES"}
]
EOF
cat >"$tmp/votes.json" <<'EOF'
{
  "votes": [
    {"voter":"gonka1alpha","options":[{"option":"VOTE_OPTION_YES","weight":"1.000000000000000000"}]},
    {"voter":"gonka1beta","options":[{"option":"VOTE_OPTION_NO","weight":"1.000000000000000000"}]},
    {"voter":"gonka1unrelated","options":[{"option":"VOTE_OPTION_YES","weight":"1.000000000000000000"}]}
  ]
}
EOF
[[ "$("$ROOT/scripts/governance-vote-evidence.sh" count "$tmp/expected.json" "$tmp/votes.json")" == 1 ]]
"$ROOT/scripts/governance-vote-evidence.sh" validate "$tmp/expected.json"

jq '.[1].address = .[0].address' "$tmp/expected.json" >"$tmp/duplicate-expected.json"
if "$ROOT/scripts/governance-vote-evidence.sh" validate "$tmp/duplicate-expected.json" \
  >"$tmp/out" 2>"$tmp/err"; then
  echo 'duplicate governance signer addresses were accepted' >&2
  exit 1
fi
grep -Fq 'expected governance voter set is invalid' "$tmp/err"

cat >"$tmp/receipt.json" <<'EOF'
{
  "height": "42",
  "code": 0,
  "tx": {
    "body": {
      "messages": [
        {
          "@type": "/cosmos.gov.v1.MsgVote",
          "proposal_id": "7",
          "voter": "gonka1alpha",
          "option": "VOTE_OPTION_YES"
        }
      ]
    }
  }
}
EOF
"$ROOT/scripts/governance-vote-evidence.sh" receipt gonka1alpha 7 VOTE_OPTION_YES "$tmp/receipt.json"
if "$ROOT/scripts/governance-vote-evidence.sh" receipt gonka1beta 7 VOTE_OPTION_YES "$tmp/receipt.json" \
  >"$tmp/out" 2>"$tmp/err"; then
  echo 'receipt for another voter was accepted' >&2
  exit 1
fi
grep -Fq 'does not match voter=gonka1beta' "$tmp/err"
if "$ROOT/scripts/governance-vote-evidence.sh" receipt gonka1alpha 7 VOTE_OPTION_NO "$tmp/receipt.json" \
  >"$tmp/out" 2>"$tmp/err"; then
  echo 'receipt for another vote option was accepted' >&2
  exit 1
fi
grep -Fq 'option=VOTE_OPTION_NO' "$tmp/err"

printf 'PASS exact governance voter evidence\n'
