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
if grep -Fq 'params_curl_exit' "$ROOT/scripts/phase-governance-devshard.sh"; then
  echo 'legacy one-shot parameter capture remains in governance phase' >&2
  exit 1
fi
grep -Fq 'capture_public_params "$RUN/params-before.json" params-before' \
  "$ROOT/scripts/phase-governance-devshard.sh"
grep -Fq 'capture_public_params "$RUN/params-after.json" params-after' \
  "$ROOT/scripts/phase-governance-devshard.sh"
grep -Fq '($p.allowed_creator_addresses // []) == $allowed_creators' \
  "$ROOT/scripts/phase-governance-devshard.sh"
jq -e --argjson expected '[]' '
  .params.devshard_escrow_params as $p
  | (($p.allowed_creator_addresses // []) == $expected)
' <<'EOF' >/dev/null
{"params":{"devshard_escrow_params":{}}}
EOF
grep -Fq 'would revoke currently approved protocol' \
  "$ROOT/scripts/validate-devshard-governance-protocols.sh"
grep -Fq '"$supported_protocols" "$governance_candidates" "$current_protocols"' \
  "$ROOT/scripts/phase-governance-devshard.sh"

cat >"$tmp/current-params.json" <<'EOF'
{
  "params": {
    "devshard_escrow_params": {
      "allowed_creator_addresses": [],
      "approved_versions": [
        {"name":"v3","binary":"https://example/v3.zip","sha256":"3333333333333333333333333333333333333333333333333333333333333333"}
      ]
    }
  }
}
EOF
cat >"$tmp/requested-versions.json" <<'EOF'
[
  {"name":"v3","binary":"https://example/v3.zip","sha256":"3333333333333333333333333333333333333333333333333333333333333333"},
  {"name":"v5","binary":"https://example/v5.zip","sha256":"5555555555555555555555555555555555555555555555555555555555555555"}
]
EOF

state="$("$ROOT/scripts/prepare-devshard-governance-state.sh" \
  "$tmp/current-params.json" "$tmp/requested-versions.json" gonka1gateway v5)"
jq -e '
  .allowed_creator_addresses == []
  and (.approved_versions | map(.name)) == ["v3", "v5"]
' <<<"$state" >/dev/null

jq '.params.devshard_escrow_params.allowed_creator_addresses = ["gonka1alpha", "gonka1beta"]' \
  "$tmp/current-params.json" >"$tmp/restricted-params.json"
state="$("$ROOT/scripts/prepare-devshard-governance-state.sh" \
  "$tmp/restricted-params.json" "$tmp/requested-versions.json" gonka1gateway v5)"
jq -e '
  .allowed_creator_addresses == ["gonka1alpha", "gonka1beta", "gonka1gateway"]
' <<<"$state" >/dev/null

jq '.[0].sha256 = ("9" * 64)' "$tmp/requested-versions.json" >"$tmp/rebound-versions.json"
if "$ROOT/scripts/prepare-devshard-governance-state.sh" \
  "$tmp/current-params.json" "$tmp/rebound-versions.json" gonka1gateway v5 \
  >"$tmp/out" 2>"$tmp/err"; then
  echo 'same-name approved DevShard tuple rebinding was accepted' >&2
  exit 1
fi
grep -Fq 'would rebind or omit a protected DevShard protocol tuple' "$tmp/err"

jq '.params.devshard_escrow_params.approved_versions = $versions' \
  --argjson versions "$(jq -c . "$tmp/requested-versions.json")" \
  "$tmp/current-params.json" >"$tmp/current-v3-v5.json"
jq 'map(if .name == "v5" then .sha256 = ("8" * 64) else . end)' \
  "$tmp/requested-versions.json" >"$tmp/rebound-v5.json"
state="$("$ROOT/scripts/prepare-devshard-governance-state.sh" \
  "$tmp/current-v3-v5.json" "$tmp/rebound-v5.json" gonka1gateway v5)"
jq -e '
  (.approved_versions | map(select(.name == "v3"))[0].sha256) == ("3" * 64)
  and (.approved_versions | map(select(.name == "v5"))[0].sha256) == ("8" * 64)
' <<<"$state" >/dev/null

jq 'map(select(.name != "v3"))' "$tmp/requested-versions.json" >"$tmp/omitted-versions.json"
if "$ROOT/scripts/prepare-devshard-governance-state.sh" \
  "$tmp/current-params.json" "$tmp/omitted-versions.json" gonka1gateway v5 \
  >"$tmp/out" 2>"$tmp/err"; then
  echo 'approved DevShard tuple omission was accepted' >&2
  exit 1
fi
grep -Fq 'would rebind or omit a protected DevShard protocol tuple' "$tmp/err"

if "$ROOT/scripts/prepare-devshard-governance-state.sh" \
  "$tmp/current-params.json" "$tmp/requested-versions.json" gonka1gateway invalid \
  >"$tmp/out" 2>"$tmp/err"; then
  echo 'invalid mutable DevShard protocol was accepted' >&2
  exit 1
fi
grep -Fq 'mutable DevShard protocol must be none or v5' "$tmp/err"

if "$ROOT/scripts/prepare-devshard-governance-state.sh" \
  "$tmp/current-params.json" "$tmp/rebound-versions.json" gonka1gateway none \
  >"$tmp/out" 2>"$tmp/err"; then
  echo 'unscoped governance accepted a protected tuple replacement' >&2
  exit 1
fi
grep -Fq 'would rebind or omit a protected DevShard protocol tuple' "$tmp/err"

grep -Fq 'mutable_protocol=v5' \
  "$ROOT/scripts/phase-governance-devshard.sh"
grep -Fq 'DevShard tuple replacement requires a verified v5 candidate composition' \
  "$ROOT/scripts/phase-governance-devshard.sh"
grep -Fq 'live inference parameters changed after proposal rendering' \
  "$ROOT/scripts/phase-governance-devshard.sh"
grep -Fq 'passed proposal did not produce the exact rendered inference parameters' \
  "$ROOT/scripts/phase-governance-devshard.sh"
grep -Fq 'proposal $supplied_proposal_id does not match the exact effective state' \
  "$ROOT/scripts/phase-governance-devshard.sh"
grep -Fq 'proposal $proposal_id changes DevShard parameters without state-binding metadata' \
  "$ROOT/scripts/phase-vote-proposal.sh"
grep -Fq '.["@type"] == "/inference.inference.MsgUpdateParams"' \
  "$ROOT/scripts/phase-vote-proposal.sh"
grep -Fq 'proposal $proposal_id is stale or malformed and will not be accepted' \
  "$ROOT/scripts/phase-vote-proposal.sh"

cat >"$tmp/snapshot-before.json" <<'EOF'
{"params":{"devshard_escrow_params":{"approved_versions":[{"name":"v5","binary":"https://example/old-v5.zip","sha256":"5555555555555555555555555555555555555555555555555555555555555555"}]},"fee_params":{"base_denom":"ngonka"}}}
EOF
before_hash="$(jq -cS '(.params // .)' "$tmp/snapshot-before.json" | sha256sum | awk '{print $1}')"
jq -n --arg before "$before_hash" '{
  messages:[{"@type":"/inference.inference.MsgUpdateParams",authority:"gonka1authority",params:{devshard_escrow_params:{approved_versions:[{name:"v5",binary:"https://example/new-v5.zip",sha256:("8" * 64)}]},fee_params:{base_denom:"ngonka"}}}],
  metadata:""
}' >"$tmp/snapshot-proposal.json"
snapshot_message_hash="$(jq -cS '.messages' "$tmp/snapshot-proposal.json" | sha256sum | awk '{print $1}')"
jq --arg metadata "gdc-devshard-v1:mutable=v5;before-sha256=$before_hash;message-sha256=$snapshot_message_hash" \
  '.metadata = $metadata' "$tmp/snapshot-proposal.json" >"$tmp/snapshot-proposal.bound.json"
"$ROOT/scripts/verify-devshard-governance-snapshot.sh" before \
  "$tmp/snapshot-proposal.bound.json" "$tmp/snapshot-before.json" v5 >/dev/null
jq '{params:.messages[0].params}' "$tmp/snapshot-proposal.bound.json" >"$tmp/snapshot-after.json"
"$ROOT/scripts/verify-devshard-governance-snapshot.sh" after \
  "$tmp/snapshot-proposal.bound.json" "$tmp/snapshot-after.json" v5 >/dev/null
jq '.params.fee_params.base_denom = "changed"' "$tmp/snapshot-before.json" >"$tmp/snapshot-stale.json"
if "$ROOT/scripts/verify-devshard-governance-snapshot.sh" before \
  "$tmp/snapshot-proposal.bound.json" "$tmp/snapshot-stale.json" v5 \
  >"$tmp/out" 2>"$tmp/err"; then
  echo 'stale full-parameter snapshot was accepted before voting' >&2
  exit 1
fi
grep -Fq 'DevShard governance snapshot mismatch mode=before' "$tmp/err"

if "$ROOT/scripts/verify-devshard-governance-snapshot.sh" before \
  "$tmp/snapshot-proposal.bound.json" "$tmp/snapshot-before.json" none \
  >"$tmp/out" 2>"$tmp/err"; then
  echo 'proposal mutable scope mismatch was accepted' >&2
  exit 1
fi
grep -Fq 'mutable scope does not match the verified local composition' "$tmp/err"

jq '.params.devshard_escrow_params.approved_versions[0].unexpected = true' \
  "$tmp/current-params.json" >"$tmp/current-extra-key.json"
if "$ROOT/scripts/prepare-devshard-governance-state.sh" \
  "$tmp/current-extra-key.json" "$tmp/requested-versions.json" gonka1gateway v5 \
  >"$tmp/out" 2>"$tmp/err"; then
  echo 'current protected tuple with an unexpected field was accepted' >&2
  exit 1
fi
grep -Fq 'current DevShard governance state is malformed' "$tmp/err"

cat >"$tmp/transition-before.json" <<'EOF'
{
  "params": {
    "devshard_escrow_params": {
      "allowed_creator_addresses": [],
      "approved_versions": [
        {"name":"v3","binary":"https://example/v3.zip","sha256":"3333333333333333333333333333333333333333333333333333333333333333"},
        {"name":"v5","binary":"https://example/old-v5.zip","sha256":"5555555555555555555555555555555555555555555555555555555555555555"}
      ],
      "devshard_requests_enabled": false,
      "max_nonce": "100"
    },
    "epoch_params": {
      "poc_exchange_duration": "8",
      "poc_validation_delay": "10",
      "poc_slot_allocation": {"value":"5","exponent":-1}
    },
    "fee_params": {"base_denom":"ngonka"}
  }
}
EOF
jq '
  (.params // .)
  | .devshard_escrow_params.approved_versions |= map(
      if .name == "v5" then
        .binary = "https://example/new-v5.zip" | .sha256 = ("8" * 64)
      else . end)
  | .devshard_escrow_params.devshard_requests_enabled = true
  | {messages:[{"@type":"/inference.inference.MsgUpdateParams",authority:"gonka1authority",params:.}],metadata:""}
' "$tmp/transition-before.json" >"$tmp/transition-proposal.json"
transition_before_hash="$(jq -cS '(.params // .)' "$tmp/transition-before.json" | sha256sum | awk '{print $1}')"
transition_message_hash="$(jq -cS '.messages' "$tmp/transition-proposal.json" | sha256sum | awk '{print $1}')"
jq --arg metadata "gdc-devshard-v1:mutable=v5;before-sha256=$transition_before_hash;message-sha256=$transition_message_hash" \
  '.metadata = $metadata' "$tmp/transition-proposal.json" >"$tmp/transition-proposal.bound.json"
"$ROOT/scripts/verify-devshard-governance-transition.sh" before \
  "$tmp/transition-before.json" "$tmp/transition-proposal.bound.json" gonka1gateway v5 \
  https://example/new-v5.zip "$(printf '8%.0s' $(seq 1 64))" 8 >/dev/null
jq '{params:.messages[0].params}' "$tmp/transition-proposal.bound.json" >"$tmp/transition-after.json"
"$ROOT/scripts/verify-devshard-governance-transition.sh" after \
  "$tmp/transition-after.json" "$tmp/transition-proposal.bound.json" gonka1gateway v5 \
  https://example/new-v5.zip "$(printf '8%.0s' $(seq 1 64))" 8 >/dev/null

jq '.messages[0].params.devshard_escrow_params.approved_versions |= map(
  if .name == "v3" then .sha256 = ("9" * 64) else . end)' \
  "$tmp/transition-proposal.bound.json" >"$tmp/transition-forged.json"
if "$ROOT/scripts/verify-devshard-governance-transition.sh" before \
  "$tmp/transition-before.json" "$tmp/transition-forged.json" gonka1gateway v5 \
  https://example/new-v5.zip "$(printf '8%.0s' $(seq 1 64))" 8 \
  >"$tmp/out" 2>"$tmp/err"; then
  echo 'self-authored metadata authorized a protected tuple replacement' >&2
  exit 1
fi

mkdir -p "$tmp/runs/20260831T000000Z-governance-devshard"
cp "$tmp/transition-before.json" \
  "$tmp/runs/20260831T000000Z-governance-devshard/params-before.json"
cp "$tmp/transition-proposal.bound.json" \
  "$tmp/runs/20260831T000000Z-governance-devshard/proposal.json"
printf '42\n' >"$tmp/runs/20260831T000000Z-governance-devshard/proposal-id.txt"
trusted_prestate="$("$ROOT/scripts/find-devshard-governance-prestate.sh" \
  "$tmp/runs" 42 "$tmp/transition-proposal.bound.json" "$transition_before_hash")"
[[ "$trusted_prestate" == "$tmp/runs/20260831T000000Z-governance-devshard/params-before.json" ]]
if "$ROOT/scripts/find-devshard-governance-prestate.sh" \
  "$tmp/runs" 42 "$tmp/transition-proposal.bound.json" \
  "$(printf '0%.0s' $(seq 1 64))" >"$tmp/out" 2>"$tmp/err"; then
  echo 'missing trusted DevShard pre-state was accepted' >&2
  exit 1
fi
grep -Fq 'trusted DevShard governance pre-state was not found' "$tmp/err"

mkdir -p "$tmp/runs/20260831T000001Z-governance-devshard"
cp "$tmp/transition-after.json" \
  "$tmp/runs/20260831T000001Z-governance-devshard/params-before.json"
cp "$tmp/transition-proposal.bound.json" \
  "$tmp/runs/20260831T000001Z-governance-devshard/proposal.json"
printf '43\n' >"$tmp/runs/20260831T000001Z-governance-devshard/proposal-id.txt"
after_hash="$(jq -cS '(.params // .)' "$tmp/transition-after.json" | sha256sum | awk '{print $1}')"
if "$ROOT/scripts/find-devshard-governance-prestate.sh" \
  "$tmp/runs" 42 "$tmp/transition-proposal.bound.json" "$after_hash" \
  >"$tmp/out" 2>"$tmp/err"; then
  echo 'post-pass snapshot from another proposal lifecycle was trusted' >&2
  exit 1
fi
grep -Fq 'trusted DevShard governance pre-state was not found' "$tmp/err"
grep -Fq 'passed DevShard proposal $proposal_id lacks trusted local pre-state evidence' \
  "$ROOT/scripts/phase-vote-proposal.sh"

printf 'PASS DevShard governance proposal selection\n'
