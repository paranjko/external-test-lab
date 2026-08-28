#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

desired="$tmp/desired.json"
proposals="$tmp/proposals.json"

jq -n '{
  metadata:"gdc-message-sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  messages:[{
    authority:"gonka1authority",
    params:{
      bitcoin_reward_params:{use_bitcoin_rewards:false},
      confirmation_poc_params:{
        alpha_threshold:{value:"0",exponent:0},
        slash_fraction:{value:"0",exponent:0}
      },
      developer_access_params:{
        allowed_developer_addresses:[],
        until_block_height:"0"
      },
      devshard_escrow_params:{
        allowed_creator_addresses:["gonka1creator"],
        approved_versions:[
          {name:"v3",binary:"https://example/v3.zip",sha256:("3" * 64)},
          {name:"v4",binary:"https://example/v4.zip",sha256:("4" * 64)},
          {name:"v5",binary:"https://example/v5.zip",sha256:("5" * 64)}
        ],
        devshard_requests_enabled:true
      },
      epoch_params:{
        poc_exchange_duration:"8",
        poc_validation_delay:"10",
        poc_slot_allocation:{value:"5",exponent:-1}
      },
      fee_params:null,
      participant_access_params:{
        blocked_participant_addresses:[],
        new_participant_registration_start_height:"0",
        participant_allowlist_until_block_height:"0",
        use_participant_allowlist:false
      }
    }
  }]
}' >"$desired"

jq -n --slurpfile desired "$desired" '{proposals:[
  ($desired[0] | .id="1" | .status="PROPOSAL_STATUS_PASSED" | .title="same title" | .metadata=""),
  ($desired[0] | .id="2" | .status="PROPOSAL_STATUS_PASSED" | .title="same title" | .messages[0].params.devshard_escrow_params.approved_versions |= map(select(.name != "v4"))),
  ($desired[0] | .id="3" | .status="PROPOSAL_STATUS_REJECTED" | .title="same title"),
  ($desired[0] | .id="4" | .status="PROPOSAL_STATUS_VOTING_PERIOD" | .title="different title"),
  ($desired[0] | .id="5" | .status="PROPOSAL_STATUS_PASSED" | .title="different title"),
  ($desired[0] | .id="6" | .status="PROPOSAL_STATUS_PASSED" | .messages[0].params.devshard_escrow_params.max_nonce="1"),
  ($desired[0] | .id="7" | .status="PROPOSAL_STATUS_VOTING_PERIOD" | del(.messages[0].params.fee_params)),
  ($desired[0]
    | .id="8"
    | .status="PROPOSAL_STATUS_VOTING_PERIOD"
    | .messages[0].params.delegation_params.initial_model_id="0")
]}' >"$proposals"

selected="$("$ROOT/scripts/select-devshard-governance-proposal.sh" "$desired" "$proposals")"
[[ "$selected" == 4 ]]

selected="$("$ROOT/scripts/select-devshard-governance-proposal.sh" "$desired" "$proposals" verify)"
[[ "$selected" == 5 ]]

jq '.proposals |= map(select(.id != "4" and .id != "5"))' "$proposals" >"$tmp/no-match.json"
selected="$("$ROOT/scripts/select-devshard-governance-proposal.sh" "$desired" "$tmp/no-match.json")"
[[ -z "$selected" ]]

# A historical exact proposal is valid readback evidence, but is not actionable
# when the effective chain state has since diverged and a new proposal is needed.
jq '.proposals |= map(select(.id == "5"))' "$proposals" >"$tmp/passed-only.json"
selected="$("$ROOT/scripts/select-devshard-governance-proposal.sh" "$desired" "$tmp/passed-only.json")"
[[ -z "$selected" ]]
selected="$("$ROOT/scripts/select-devshard-governance-proposal.sh" "$desired" "$tmp/passed-only.json" verify)"
[[ "$selected" == 5 ]]

if "$ROOT/scripts/select-devshard-governance-proposal.sh" "$desired" "$proposals" invalid \
  >"$tmp/out" 2>"$tmp/err"; then
  echo 'invalid selector mode was accepted' >&2
  exit 1
fi
grep -Fq 'invalid proposal selection mode' "$tmp/err"

grep -Fq 'params_url="${GDC_CHAIN_API_URL:-https://${PUBLIC_EDGE_HOST}/chain-api}"' \
  "$ROOT/scripts/phase-governance-devshard.sh"
grep -Fq 'curl_exit=$params_curl_exit curl_status=$(curl_exit_status "$params_curl_exit")' \
  "$ROOT/scripts/phase-governance-devshard.sh"

printf 'PASS DevShard governance proposal selection\n'
