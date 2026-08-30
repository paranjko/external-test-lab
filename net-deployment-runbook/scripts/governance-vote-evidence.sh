#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo 'usage: governance-vote-evidence.sh validate EXPECTED.json | count EXPECTED.json VOTES.json | receipt EXPECTED_ADDRESS PROPOSAL_ID OPTION TXHASH RECEIPT.json' >&2
}

validate_expected() {
  local expected="$1"
  jq -e '
    type == "array" and length > 0
    and all(.[];
      (.address | type == "string" and test("^gonka1[0-9a-z]+$"))
      and (.option | type == "string" and test("^VOTE_OPTION_(YES|NO|ABSTAIN|NO_WITH_VETO)$")))
    and ([.[].address] | unique | length) == length
  ' "$expected" >/dev/null || {
    echo "expected governance voter set is invalid: $expected" >&2
    return 2
  }
}

mode="${1:-}"
shift || true
case "$mode" in
  validate)
    [[ $# -eq 1 ]] || { usage; exit 2; }
    validate_expected "$1"
    ;;
  count)
    [[ $# -eq 2 ]] || { usage; exit 2; }
    expected="$1"
    votes="$2"
    validate_expected "$expected"
    jq -er --slurpfile expected "$expected" '
      [
        $expected[0][] as $want
        | .votes[]? as $vote
        | select($vote.voter == $want.address)
        | select(([
            $vote.options[]?
            | select(.option == $want.option and ((.weight | tonumber) == 1))
          ] | length) == 1)
        | $vote.voter
      ]
      | unique
      | length
    ' "$votes"
    ;;
  receipt)
    [[ $# -eq 5 ]] || { usage; exit 2; }
    address="$1"
    proposal_id="$2"
    option="$3"
    txhash="$4"
    receipt="$5"
    [[ "$address" =~ ^gonka1[0-9a-z]+$ ]] || { echo 'invalid expected governance voter address' >&2; exit 2; }
    [[ "$proposal_id" =~ ^[1-9][0-9]*$ ]] || { echo 'invalid expected governance proposal ID' >&2; exit 2; }
    [[ "$option" =~ ^VOTE_OPTION_(YES|NO|ABSTAIN|NO_WITH_VETO)$ ]] || { echo 'invalid expected governance vote option' >&2; exit 2; }
    [[ "$txhash" =~ ^[A-Fa-f0-9]{64}$ ]] || { echo 'invalid expected governance transaction hash' >&2; exit 2; }
    txhash="${txhash^^}"
    jq -e --arg address "$address" --arg proposal_id "$proposal_id" --arg option "$option" --arg txhash "$txhash" '
      ((.code // .tx_response.code // -1) | tonumber) == 0
      and (((.height // .tx_response.height // "0") | tonumber) > 0)
      and (((.txhash // .tx_response.txhash // "") | ascii_upcase) == $txhash)
      and ([
        (.tx // .tx_response.tx // {}).body.messages[]?
        | select(
            .["@type"] == "/cosmos.gov.v1.MsgVote"
            and (.proposal_id | tostring) == $proposal_id
            and .voter == $address
            and .option == $option
          )
      ] | length) == 1
    ' "$receipt" >/dev/null || {
      echo "committed governance vote receipt does not match voter=$address proposal=$proposal_id option=$option txhash=$txhash" >&2
      exit 1
    }
    ;;
  *)
    usage
    exit 2
    ;;
esac
