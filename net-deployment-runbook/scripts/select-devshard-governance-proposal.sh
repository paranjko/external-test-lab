#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -ge 2 && $# -le 3 ]] || {
  echo 'usage: select-devshard-governance-proposal.sh DESIRED_PROPOSAL.json PROPOSALS.json [active|verify]' >&2
  exit 2
}

desired="$1"
proposals="$2"
mode="${3:-active}"
[[ -s "$desired" ]] || { echo "desired proposal is missing or empty: $desired" >&2; exit 2; }
[[ -s "$proposals" ]] || { echo "proposal list is missing or empty: $proposals" >&2; exit 2; }
[[ "$mode" == active || "$mode" == verify ]] || { echo "invalid proposal selection mode: $mode" >&2; exit 2; }

jq -er --arg mode "$mode" --slurpfile desired "$desired" '
  ($desired[0].metadata) as $metadata
  | ($desired[0].messages) as $messages
  | [.proposals[]?
      | select(
          .status == "PROPOSAL_STATUS_VOTING_PERIOD"
          or ($mode == "verify" and .status == "PROPOSAL_STATUS_PASSED")
        )
      | select(.metadata == $metadata)
      | select(.messages == $messages)
      | (.id | tonumber)]
  | if length == 0 then "" else max | tostring end
' "$proposals"
