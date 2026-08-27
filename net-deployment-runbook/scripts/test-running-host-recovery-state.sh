#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/evaluate-running-host-recovery.sh"
RECOVERY="$ROOT/scripts/recover-running-host-state.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

expect_failure() {
  local name="$1" pattern="$2"
  shift 2
  if "$@" >"$tmp/$name.out" 2>"$tmp/$name.err"; then
    printf '%s must fail closed\n' "$name" >&2
    exit 1
  fi
  grep -Fq "$pattern" "$tmp/$name.err"
}

status_fixture() {
  local output="$1" network="$2" node_id="$3" height="$4" catching="$5"
  jq -n --arg network "$network" --arg node_id "$node_id" --arg height "$height" \
    --argjson catching "$catching" \
    '{result:{node_info:{network:$network,id:$node_id},sync_info:{latest_block_height:$height,catching_up:$catching}}}' \
    >"$output"
}

block_fixture() {
  local output="$1" height="$2" block_hash="$3" app_hash="$4" chain_id="${5:-chain-a}"
  jq -n --arg chain_id "$chain_id" --arg height "$height" \
    --arg block_hash "$block_hash" --arg app_hash "$app_hash" \
    '{result:{block_id:{hash:$block_hash},block:{header:{chain_id:$chain_id,height:$height,app_hash:$app_hash}}}}' \
    >"$output"
}

signature_fixture() {
  local output="$1" height="$2" address="$3" flag="$4" canonical="${5:-true}"
  jq -n --arg height "$height" --arg address "$address" --arg signature "$valid_signature" \
    --argjson flag "$flag" --argjson canonical "$canonical" '
    {result:{canonical:$canonical,signed_header:{
      header:{
        version:{block:"11",app:"1"},chain_id:"chain-a",height:$height,
        time:"2020-09-14T16:33:54.21191421Z",
        last_block_id:{
          hash:"D3B2CC7EDAFF87433A5DBCDCDF4077A56AACDE3606034262B0CDB120F62EB40B",
          part_set_header:{total:1,
            hash:"3AB411EAFE9A3B7AC013B0214990E5653112A39909289E3EA9211F07B8CD6EED"}},
        last_commit_hash:"47071B86EFC28BEC17543967975F35191BA9BEC9C2AD77E86F63B149528D71A1",
        data_hash:"E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855",
        validators_hash:"5E20520EC80B84044B64BA0C55B1C06D543BBD57955C27B8A9999EC526BF703C",
        next_validators_hash:"5E20520EC80B84044B64BA0C55B1C06D543BBD57955C27B8A9999EC526BF703C",
        consensus_hash:"048091BC7DDC283F77BFBF91D73C44DA58C3DF8A9CBC867405D8B7F3DAADA22F",
        app_hash:"0000000000000000",
        last_results_hash:"E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855",
        evidence_hash:"E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855",
        proposer_address:"C8657A30D20C3BAD414624A1A963373DD500CCD3"},
      commit:{height:$height,round:0,
        block_id:{hash:"09581DBDED2A8B81149C3AC0D36526896794F4AE25B9B598BE425DB017BF28E4",
          part_set_header:{total:1,
            hash:"3AB411EAFE9A3B7AC013B0214990E5653112A39909289E3EA9211F07B8CD6EED"}},
        signatures:[{validator_address:$address,block_id_flag:$flag,
          timestamp:"2026-08-26T12:00:00Z",signature:$signature}]}}}}
  ' >"$output"
}

genesis_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
genesis_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
"$CHECK" lineage chain-a "$genesis_a" chain-a "$genesis_a" >"$tmp/lineage.json"
jq -e '.matched and .chain_id == "chain-a"' "$tmp/lineage.json" >/dev/null
if "$CHECK" lineage chain-a "$genesis_a" chain-a "$genesis_b" \
  >"$tmp/stale-genesis.out" 2>"$tmp/stale-genesis.err"; then
  echo 'same-chain-ID recovery from another Genesis must fail' >&2
  exit 1
fi
grep -Fq 'different Genesis lineage' "$tmp/stale-genesis.err"
if "$CHECK" lineage chain-a "$genesis_a" chain-b "$genesis_a" \
  >"$tmp/wrong-chain.out" 2>"$tmp/wrong-chain.err"; then
  echo 'recovery from another chain must fail' >&2
  exit 1
fi
grep -Fq 'belongs to another chain' "$tmp/wrong-chain.err"

status_fixture "$tmp/chain.json" chain-a canonical 120 false
status_fixture "$tmp/public.json" chain-a expected-node 119 false
status_fixture "$tmp/local.json" chain-a expected-node 120 false
"$CHECK" status chain-a expected-node 2 110 110 110 \
  "$tmp/chain.json" "$tmp/public.json" "$tmp/local.json" >"$tmp/ready.json"
jq -e '.ready and (.local_catching_up == false) and (.public_lag == 1)' "$tmp/ready.json" >/dev/null

status_fixture "$tmp/chain-catching.json" chain-a canonical 120 true
"$CHECK" status chain-a expected-node 2 110 110 110 \
  "$tmp/chain-catching.json" "$tmp/public.json" "$tmp/local.json" >"$tmp/chain-catching-result.json"
jq -e '(.ready == false) and .chain_catching_up' "$tmp/chain-catching-result.json" >/dev/null

status_fixture "$tmp/local-catching.json" chain-a expected-node 120 true
"$CHECK" status chain-a expected-node 2 110 110 110 \
  "$tmp/chain.json" "$tmp/public.json" "$tmp/local-catching.json" >"$tmp/local-catching-result.json"
jq -e '(.ready == false) and .local_catching_up' "$tmp/local-catching-result.json" >/dev/null

"$CHECK" status chain-a expected-node 2 120 119 120 \
  "$tmp/chain.json" "$tmp/public.json" "$tmp/local.json" >"$tmp/stale.json"
jq -e '.ready == false' "$tmp/stale.json" >/dev/null

status_fixture "$tmp/misrouted.json" chain-a wrong-node 119 false
if "$CHECK" status chain-a expected-node 2 110 110 110 \
  "$tmp/chain.json" "$tmp/misrouted.json" "$tmp/local.json" >"$tmp/misrouted.out" 2>"$tmp/misrouted.err"; then
  echo 'misrouted public Host must fail recovery' >&2
  exit 1
fi
grep -Fq 'public Host endpoint routes to another P2P identity' "$tmp/misrouted.err"

status_fixture "$tmp/public-catching.json" chain-a expected-node 119 true
"$CHECK" status chain-a expected-node 2 110 110 110 \
  "$tmp/chain.json" "$tmp/public-catching.json" "$tmp/local.json" >"$tmp/catching.json"
jq -e '(.ready == false) and .public_catching_up' "$tmp/catching.json" >/dev/null

# Compact malformed/missing/null/wrong-type/negative/non-integer/overflow matrix.
status_cases=(
  'missing-height|del(.result.sync_info.latest_block_height)'
  'null-height|.result.sync_info.latest_block_height = null'
  'number-height|.result.sync_info.latest_block_height = 119'
  'negative-height|.result.sync_info.latest_block_height = "-1"'
  'fractional-height|.result.sync_info.latest_block_height = "1.5"'
  'overflow-height|.result.sync_info.latest_block_height = "9007199254740992"'
  'string-catching|.result.sync_info.catching_up = "false"'
  'null-network|.result.node_info.network = null'
)
for row in "${status_cases[@]}"; do
  name="${row%%|*}"
  mutation="${row#*|}"
  jq "$mutation" "$tmp/public.json" >"$tmp/status-$name.json"
  expect_failure "status-$name" 'recovery status evidence is malformed or unsafe' \
    "$CHECK" status chain-a expected-node 2 110 110 110 \
    "$tmp/chain.json" "$tmp/status-$name.json" "$tmp/local.json"
done
printf '{broken\n' >"$tmp/status-malformed-json.json"
expect_failure status-malformed-json 'recovery status evidence is malformed or unsafe' \
  "$CHECK" status chain-a expected-node 2 110 110 110 \
  "$tmp/chain.json" "$tmp/status-malformed-json.json" "$tmp/local.json"

status_fixture "$tmp/public-ahead.json" chain-a expected-node 121 false
"$CHECK" status chain-a expected-node 2 110 110 110 \
  "$tmp/chain.json" "$tmp/public-ahead.json" "$tmp/local.json" >"$tmp/public-ahead-result.json"
jq -e '.ready and .public_ahead_of_canonical and (.public_lag == 1)' \
  "$tmp/public-ahead-result.json" >/dev/null

status_fixture "$tmp/public-too-far-ahead.json" chain-a expected-node 123 false
"$CHECK" status chain-a expected-node 2 110 110 110 \
  "$tmp/chain.json" "$tmp/public-too-far-ahead.json" "$tmp/local.json" \
  >"$tmp/public-too-far-ahead-result.json"
jq -e '(.ready == false) and .public_ahead_of_canonical and (.public_lag == 3)' \
  "$tmp/public-too-far-ahead-result.json" >/dev/null

status_fixture "$tmp/local-ahead.json" chain-a expected-node 121 false
"$CHECK" status chain-a expected-node 2 110 110 110 \
  "$tmp/chain.json" "$tmp/public.json" "$tmp/local-ahead.json" >"$tmp/local-ahead-result.json"
jq -e '.ready and .local_ahead_of_canonical and (.local_lag == 1)' \
  "$tmp/local-ahead-result.json" >/dev/null

expect_failure status-overflow-bound 'must be a non-negative safe integer' \
  "$CHECK" status chain-a expected-node 9007199254740992 110 110 110 \
  "$tmp/chain.json" "$tmp/public.json" "$tmp/local.json"

previous_chain=100
previous_public=100
previous_local=100
accepted_samples=0
status_fixture "$tmp/stalled-public.json" chain-a expected-node 101 false
status_fixture "$tmp/stalled-local.json" chain-a expected-node 101 false
for chain_height in 101 102 103; do
  status_fixture "$tmp/progress-chain.json" chain-a canonical "$chain_height" false
  "$CHECK" status chain-a expected-node 2 \
    "$previous_chain" "$previous_public" "$previous_local" \
    "$tmp/progress-chain.json" "$tmp/stalled-public.json" "$tmp/stalled-local.json" \
    >"$tmp/progress-$chain_height.json"
  if [[ "$(jq -r .ready "$tmp/progress-$chain_height.json")" == true ]]; then
    accepted_samples=$((accepted_samples + 1))
    previous_chain="$(jq -er .chain_height "$tmp/progress-$chain_height.json")"
    previous_public="$(jq -er .public_height "$tmp/progress-$chain_height.json")"
    previous_local="$(jq -er .local_height "$tmp/progress-$chain_height.json")"
  fi
done
[[ "$accepted_samples" == 1 ]] || {
  echo 'advance-once-then-stall samples must not satisfy recovery progress' >&2
  exit 1
}

for name in chain public local; do
  block_fixture "$tmp/$name-block.json" 115 \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
done
"$CHECK" block chain-a 115 "$tmp/chain-block.json" "$tmp/public-block.json" "$tmp/local-block.json" \
  >"$tmp/block.json"
jq -e '.matched and .height == 115' "$tmp/block.json" >/dev/null
block_fixture "$tmp/local-block.json" 115 \
  cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
if "$CHECK" block chain-a 115 "$tmp/chain-block.json" "$tmp/public-block.json" "$tmp/local-block.json" \
  >"$tmp/block-mismatch.out" 2>"$tmp/block-mismatch.err"; then
  echo 'mismatched common block must fail recovery' >&2
  exit 1
fi
grep -Fq 'block or app state disagree' "$tmp/block-mismatch.err"

jq -n '{result:{block:{header:{chain_id:"chain-a",height:"115",app_hash:
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}}}' \
  >"$tmp/missing-block-hash.json"
if "$CHECK" block chain-a 115 "$tmp/missing-block-hash.json" "$tmp/public-block.json" "$tmp/chain-block.json" \
  >"$tmp/missing-block-hash.out" 2>"$tmp/missing-block-hash.err"; then
  echo 'common-state evidence without a block hash must fail recovery' >&2
  exit 1
fi
grep -Fq 'recovery block evidence is malformed' "$tmp/missing-block-hash.err"

jq -n '{result:{block_id:{hash:
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
  block:{header:{chain_id:"chain-a",height:"115"}}}}' >"$tmp/missing-app-hash.json"
if "$CHECK" block chain-a 115 "$tmp/missing-app-hash.json" "$tmp/public-block.json" "$tmp/chain-block.json" \
  >"$tmp/missing-app-hash.out" 2>"$tmp/missing-app-hash.err"; then
  echo 'common-state evidence without an app hash must fail recovery' >&2
  exit 1
fi
grep -Fq 'recovery block evidence is malformed' "$tmp/missing-app-hash.err"

jq -n '{result:{canonical:true}}' >"$tmp/canonical-commit.json"
[[ "$("$CHECK" commit-canonicality "$tmp/canonical-commit.json")" == true ]]
jq -n '{result:{canonical:false}}' >"$tmp/noncanonical-commit.json"
[[ "$("$CHECK" commit-canonicality "$tmp/noncanonical-commit.json")" == false ]]
jq -n '{result:{canonical:"false"}}' >"$tmp/malformed-canonicality.json"
expect_failure malformed-commit-canonicality \
  'consensus commit canonicality metadata is malformed' \
  "$CHECK" commit-canonicality "$tmp/malformed-canonicality.json"

operator_address=gonka1operator
openssl genpkey -algorithm ED25519 -out "$tmp/expected-private.pem" >/dev/null 2>&1
openssl pkey -in "$tmp/expected-private.pem" -pubout -outform DER \
  -out "$tmp/expected-public.der" >/dev/null 2>&1
expected_key="$(tail -c 32 "$tmp/expected-public.der" | base64 | tr -d '\n')"
expected_consensus="$(printf '%s' "$expected_key" | base64 -d | sha256sum \
  | awk '{print toupper(substr($1,1,40))}')"
openssl genpkey -algorithm ED25519 -out "$tmp/other-private.pem" >/dev/null 2>&1
openssl pkey -in "$tmp/other-private.pem" -pubout -outform DER \
  -out "$tmp/other-public.der" >/dev/null 2>&1
other_key="$(tail -c 32 "$tmp/other-public.der" | base64 | tr -d '\n')"
other_consensus="$(printf '%s' "$other_key" | base64 -d | sha256sum \
  | awk '{print toupper(substr($1,1,40))}')"
printf '%s' \
  'ZggCEYIAAAAAAAAAIkgKIAlYHb3tKouBFJw6wNNlJolnlPSuJbm1mL5CXbAXvyjkEiQIARIgOrQR6v6aO3rAE7AhSZDlZTESo5kJKJ4+qSEfB7jNbu0qBgjAqrvUBjIHY2hhaW4tYQ==' \
  | base64 -d >"$tmp/canonical-precommit-sign-bytes"
openssl pkeyutl -sign -inkey "$tmp/expected-private.pem" -rawin \
  -in "$tmp/canonical-precommit-sign-bytes" -out "$tmp/valid-signature.raw"
valid_signature="$(base64 <"$tmp/valid-signature.raw" | tr -d '\n')"
jq -n --arg address "$operator_address" --arg key "$expected_key" '{participant:{address:$address,
  validator_key:$key,inference_url:"https://node.example/",status:"ACTIVE"}}' \
  >"$tmp/participant.json"
"$CHECK" participant "$operator_address" "$expected_key" https://node.example \
  "$tmp/participant.json" >"$tmp/participant-evaluation.json"
jq -e '.matched and .active and .operator_address == "gonka1operator"
  and (.consensus_key | length) == 44' "$tmp/participant-evaluation.json" >/dev/null

participant_cases=(
  'wrong-operator|.participant.address = "gonka1wrong"'
  'wrong-key|.participant.validator_key = "other-key"'
  'inactive|.participant.status = "INACTIVE"'
  'null-status|.participant.status = null'
  'fractional-status|.participant.status = 1.5'
)
for row in "${participant_cases[@]}"; do
  name="${row%%|*}"
  mutation="${row#*|}"
  jq "$mutation" "$tmp/participant.json" >"$tmp/participant-$name.json"
  expect_failure "participant-$name" 'participant evidence is malformed, inactive, or bound' \
    "$CHECK" participant "$operator_address" "$expected_key" https://node.example \
    "$tmp/participant-$name.json"
done

jq -n '{result:{block_height:"130",count:"100",total:"101",validators:
  [range(0;100) as $n | {
    address:(("0000000000000000000000000000000000000000" + ($n | tostring)) | .[-40:]),
    pub_key:{type:"tendermint/PubKeyEd25519",value:("key-" + ($n | tostring))},voting_power:"1"}]}}' \
  >"$tmp/validators-page-1.json"
jq -n --arg address "$expected_consensus" --arg key "$expected_key" \
  '{result:{block_height:"130",count:"1",total:"101",validators:
  [{address:$address,pub_key:{type:"tendermint/PubKeyEd25519",value:$key},voting_power:"7"}]}}' \
  >"$tmp/validators-page-2.json"
"$CHECK" validator-pages 130 "$tmp/validators-page-1.json" >"$tmp/validator-pages.json"
jq -e '.total == 101 and .page_size == 100 and .pages == 2
  and .max_items == 10000 and .max_pages == 100' "$tmp/validator-pages.json" >/dev/null
paginator_cases=(
  'stale|.result.block_height = "129"'
  'missing-total|del(.result.total)'
  'wrong-count-type|.result.count = 100'
  'inconsistent-count|.result.count = "99"'
  'zero-total|.result.total = "0"'
  'excessive-total|.result.total = "10001"'
  'overflow-total|.result.total = "9007199254740992"'
)
for row in "${paginator_cases[@]}"; do
  name="${row%%|*}"
  mutation="${row#*|}"
  jq "$mutation" "$tmp/validators-page-1.json" >"$tmp/paginator-$name.json"
  expect_failure "paginator-$name" 'first validator page is malformed, stale, unsafe, or inconsistent' \
    "$CHECK" validator-pages 130 "$tmp/paginator-$name.json"
done
"$CHECK" validators 130 "$operator_address" "$expected_key" "$tmp/participant-evaluation.json" \
  "$tmp/validators-page-1.json" "$tmp/validators-page-2.json" >"$tmp/validator-set.json"
jq -e --arg address "$expected_consensus" '.height == 130 and .total == 101 and .returned == 101
  and .match_count == 1 and .voting_power == 7 and .consensus_address == $address
  and .operator_address == "gonka1operator"' "$tmp/validator-set.json" >/dev/null

expect_failure truncated-validators 'validator set pages are malformed, unsafe, duplicated, or incomplete' \
  "$CHECK" validators 130 "$operator_address" "$expected_key" "$tmp/participant-evaluation.json" \
  "$tmp/validators-page-1.json"

jq -n --arg address "$expected_consensus" --arg key "$expected_key" \
  '{result:{block_height:"130",count:"1",total:"1",validators:
  [{address:$address,pub_key:{type:"tendermint/PubKeyEd25519",value:$key},voting_power:"7"}]}}' \
  >"$tmp/validator-base.json"
validator_cases=(
  'missing-key|del(.result.validators[0].pub_key)'
  'stale-height|.result.block_height = "129"'
  'null-count|.result.count = null'
  'number-total|.result.total = 1'
  'negative-power|.result.validators[0].voting_power = "-1"'
  'fractional-power|.result.validators[0].voting_power = "1.5"'
  'overflow-power|.result.validators[0].voting_power = "9007199254740992"'
  'overflow-total|.result.total = "9007199254740992"'
  'wrong-key-type|.result.validators[0].pub_key.type = "tendermint/PubKeySecp256k1"'
  'rebound-key|.result.validators[0].address = "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"'
  'duplicate-address|.result.total = "2" | .result.count = "2" | .result.validators += [(.result.validators[0] | .pub_key.value = "other-key")]'
  'duplicate-key|.result.total = "2" | .result.count = "2" | .result.validators += [(.result.validators[0] | .address = "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC")]'
)
for row in "${validator_cases[@]}"; do
  name="${row%%|*}"
  mutation="${row#*|}"
  jq "$mutation" "$tmp/validator-base.json" >"$tmp/validator-$name.json"
  expect_failure "validator-$name" 'validator set pages are malformed, unsafe, duplicated, or incomplete' \
    "$CHECK" validators 130 "$operator_address" "$expected_key" "$tmp/participant-evaluation.json" \
    "$tmp/validator-$name.json"
done

jq '.consensus_key = "other-key"' "$tmp/participant-evaluation.json" \
  >"$tmp/wrong-participant-evaluation.json"
expect_failure wrong-validator-operator-binding 'not bound to the intended active operator' \
  "$CHECK" validators 130 "$operator_address" "$expected_key" "$tmp/wrong-participant-evaluation.json" \
  "$tmp/validator-base.json"
expect_failure noncanonical-expected-consensus-key 'not canonical Ed25519 public-key material' \
  "$CHECK" validators 130 "$operator_address" expected-key "$tmp/participant-evaluation.json" \
  "$tmp/validator-base.json"

too_many_pages=()
for ((page = 0; page <= 100; page++)); do
  too_many_pages+=("$tmp/validator-base.json")
done
expect_failure excessive-validator-pages 'exceeds the deterministic 100-page limit' \
  "$CHECK" validators 130 "$operator_address" "$expected_key" "$tmp/participant-evaluation.json" \
  "${too_many_pages[@]}"

jq -n --arg address "$other_consensus" --arg key "$other_key" \
  '{result:{block_height:"115",count:"1",total:"1",validators:
  [{address:$address,pub_key:{type:"tendermint/PubKeyEd25519",value:$key},voting_power:"5"}]}}' \
  >"$tmp/common-height-validators.json"
"$CHECK" validators 115 "$operator_address" "$expected_key" "$tmp/participant-evaluation.json" \
  "$tmp/common-height-validators.json" >"$tmp/common-height-validator-set.json"
jq -e '.match_count == 0 and .voting_power == 0 and .consensus_address == null' \
  "$tmp/common-height-validator-set.json" >/dev/null

jq -n '{ready:true,chain_height:116}' >"$tmp/final-decision-116.json"
expect_failure zero-to-positive-validator-transition \
  'validator-set evidence is not bound to the final synchronized decision height' \
  "$CHECK" decision-height "$tmp/final-decision-116.json" \
  "$tmp/common-height-validator-set.json"
jq -n '{ready:true,chain_height:130}' >"$tmp/final-decision-130.json"
"$CHECK" decision-height "$tmp/final-decision-130.json" "$tmp/validator-set.json" \
  >"$tmp/decision-height.json"
jq -e '.matched and .height == 130 and .voting_power == 7' \
  "$tmp/decision-height.json" >/dev/null

signature_fixture "$tmp/signed-commit.json" 130 "$expected_consensus" 2
"$CHECK" signature chain-a 130 "$operator_address" "$expected_key" "$tmp/validator-set.json" \
  "$tmp/signed-commit.json" \
  >"$tmp/signature.json"
jq -e '.canonical and .signed and .signature_required and .commit_height == 130
  and .voting_power == 7 and .operator_address == "gonka1operator"
  and .canonical_header_hash == "09581DBDED2A8B81149C3AC0D36526896794F4AE25B9B598BE425DB017BF28E4"
  and .verified_signature_timestamp == "2026-08-26T12:00:00Z"
  and (.canonical_commit_sha256 | test("^[0-9a-f]{64}$"))' \
  "$tmp/signature.json" >/dev/null

# CometBFT JSON omits the default application protocol version when it is zero.
# This sign-byte vector is bound to the deterministic app-version-zero header
# below and was cross-checked with CometBFT v0.38.21.
printf '%s' \
  'ZggCEYIAAAAAAAAAIkgKICTmLvt/QIW/TWe02NK80jbv4TGKZu+IMO/g8Fmf3LmeEiQIARIgOrQR6v6aO3rAE7AhSZDlZTESo5kJKJ4+qSEfB7jNbu0qBgjAqrvUBjIHY2hhaW4tYQ==' \
  | base64 -d >"$tmp/app-version-zero-sign-bytes"
openssl pkeyutl -sign -inkey "$tmp/expected-private.pem" -rawin \
  -in "$tmp/app-version-zero-sign-bytes" -out "$tmp/app-version-zero-signature.raw"
app_version_zero_signature="$(base64 <"$tmp/app-version-zero-signature.raw" | tr -d '\n')"
app_version_zero_hash=24E62EFB7F4085BF4D67B4D8D2BCD236EFE1318A66EF8830EFE0F0599FDCB99E
jq --arg hash "$app_version_zero_hash" --arg signature "$app_version_zero_signature" '
  del(.result.signed_header.header.version.app)
  | .result.signed_header.commit.block_id.hash = $hash
  | .result.signed_header.commit.signatures[0].signature = $signature
' "$tmp/signed-commit.json" >"$tmp/omitted-zero-app-version.json"
"$CHECK" signature chain-a 130 "$operator_address" "$expected_key" "$tmp/validator-set.json" \
  "$tmp/omitted-zero-app-version.json" >"$tmp/omitted-zero-app-version-result.json"
jq -e --arg hash "$app_version_zero_hash" \
  '.signed and .canonical_header_hash == $hash' \
  "$tmp/omitted-zero-app-version-result.json" >/dev/null

jq '.result.signed_header.header.version.app = "0"' \
  "$tmp/omitted-zero-app-version.json" >"$tmp/explicit-zero-app-version.json"
"$CHECK" signature chain-a 130 "$operator_address" "$expected_key" "$tmp/validator-set.json" \
  "$tmp/explicit-zero-app-version.json" >"$tmp/explicit-zero-app-version-result.json"
jq -e --arg hash "$app_version_zero_hash" \
  '.signed and .canonical_header_hash == $hash' \
  "$tmp/explicit-zero-app-version-result.json" >/dev/null

random_signature="$(openssl rand 64 | base64 | tr -d '\n')"
jq --arg signature "$random_signature" \
  '.result.signed_header.commit.signatures[0].signature = $signature' \
  "$tmp/signed-commit.json" >"$tmp/random-signature.json"
expect_failure random-correctly-shaped-signature \
  'consensus commit evidence is malformed, non-canonical, stale, duplicated, or invalid' \
  "$CHECK" signature chain-a 130 "$operator_address" "$expected_key" \
  "$tmp/validator-set.json" "$tmp/random-signature.json"

jq --arg key "$other_key" --arg address "$other_consensus" \
  '.consensus_key = $key | .consensus_address = $address' \
  "$tmp/validator-set.json" >"$tmp/wrong-key-validator-set.json"
jq --arg address "$other_consensus" \
  '.result.signed_header.commit.signatures[0].validator_address = $address' \
  "$tmp/signed-commit.json" >"$tmp/wrong-key-commit.json"
expect_failure wrong-signature-key \
  'consensus commit evidence is malformed, non-canonical, stale, duplicated, or invalid' \
  "$CHECK" signature chain-a 130 "$operator_address" "$other_key" \
  "$tmp/wrong-key-validator-set.json" "$tmp/wrong-key-commit.json"

jq '.result.signed_header.commit.block_id.hash = ("F" * 64)' \
  "$tmp/signed-commit.json" >"$tmp/wrong-commit-block-hash.json"
expect_failure wrong-commit-block-hash \
  'cryptographic signature and header binding are required' \
  "$CHECK" signature chain-a 130 "$operator_address" "$expected_key" \
  "$tmp/validator-set.json" "$tmp/wrong-commit-block-hash.json"

jq '.result.signed_header.header.app_hash = "0100000000000000"' \
  "$tmp/signed-commit.json" >"$tmp/wrong-header-hash.json"
expect_failure wrong-canonical-header-hash \
  'cryptographic signature and header binding are required' \
  "$CHECK" signature chain-a 130 "$operator_address" "$expected_key" \
  "$tmp/validator-set.json" "$tmp/wrong-header-hash.json"

jq '.result.signed_header.header.height = "131"
  | .result.signed_header.commit.height = "131"' \
  "$tmp/signed-commit.json" >"$tmp/wrong-signed-height.json"
expect_failure wrong-signed-height \
  'cryptographic signature and header binding are required' \
  "$CHECK" signature chain-a 131 "$operator_address" "$expected_key" \
  "$tmp/validator-set.json" "$tmp/wrong-signed-height.json"

jq '.result.signed_header.commit.round = 1' \
  "$tmp/signed-commit.json" >"$tmp/wrong-signed-round.json"
expect_failure wrong-signed-round \
  'cryptographic signature and header binding are required' \
  "$CHECK" signature chain-a 130 "$operator_address" "$expected_key" \
  "$tmp/validator-set.json" "$tmp/wrong-signed-round.json"

jq '.result.signed_header.commit.signatures[0].timestamp = "2026-08-26T12:00:01Z"' \
  "$tmp/signed-commit.json" >"$tmp/wrong-signed-timestamp.json"
expect_failure wrong-signed-timestamp \
  'cryptographic signature and header binding are required' \
  "$CHECK" signature chain-a 130 "$operator_address" "$expected_key" \
  "$tmp/validator-set.json" "$tmp/wrong-signed-timestamp.json"
jq '.consensus_address = "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"' \
  "$tmp/validator-set.json" >"$tmp/rebound-validator-set.json"
expect_failure rebound-signature-address 'not bound to the intended validator-set decision' \
  "$CHECK" signature chain-a 130 "$operator_address" "$expected_key" \
  "$tmp/rebound-validator-set.json" "$tmp/signed-commit.json"

signature_fixture "$tmp/unsigned-commit.json" 130 "$other_consensus" 2
"$CHECK" signature chain-a 130 "$operator_address" "$expected_key" "$tmp/validator-set.json" \
  "$tmp/unsigned-commit.json" \
  >"$tmp/unsigned-signature.json"
jq -e '.canonical and (.signed == false)' "$tmp/unsigned-signature.json" >/dev/null
signature_fixture "$tmp/nil-vote-commit.json" 130 "$expected_consensus" 3
"$CHECK" signature chain-a 130 "$operator_address" "$expected_key" "$tmp/validator-set.json" \
  "$tmp/nil-vote-commit.json" \
  >"$tmp/nil-vote-signature.json"
jq -e '.canonical and (.signed == false)' "$tmp/nil-vote-signature.json" >/dev/null
"$CHECK" signature chain-a 130 "$operator_address" "$expected_key" \
  "$tmp/common-height-validator-set.json" "$tmp/signed-commit.json" \
  >"$tmp/zero-power-signature.json"
jq -e '(.signature_required == false) and (.signed == false) and .voting_power == 0' \
  "$tmp/zero-power-signature.json" >/dev/null

commit_cases=(
  'noncanonical|.result.canonical = false'
  'stale-header|.result.signed_header.header.height = "129"'
  'null-height|.result.signed_header.commit.height = null'
  'wrong-chain|.result.signed_header.header.chain_id = "chain-b"'
  'string-flag|.result.signed_header.commit.signatures[0].block_id_flag = "2"'
  'missing-signature|.result.signed_header.commit.signatures[0].signature = null'
  'bad-signature|.result.signed_header.commit.signatures[0].signature = "not base64!"'
  'duplicate-signature|.result.signed_header.commit.signatures += [.result.signed_header.commit.signatures[0]]'
  'overflow-round|.result.signed_header.commit.round = 9007199254740992'
)
for row in "${commit_cases[@]}"; do
  name="${row%%|*}"
  mutation="${row#*|}"
  jq "$mutation" "$tmp/signed-commit.json" >"$tmp/commit-$name.json"
  expect_failure "commit-$name" 'consensus commit evidence is malformed, non-canonical, stale, duplicated, or invalid' \
    "$CHECK" signature chain-a 130 "$operator_address" "$expected_key" "$tmp/validator-set.json" \
    "$tmp/commit-$name.json"
done
expect_failure stale-commit-height 'consensus commit evidence is malformed, non-canonical, stale, duplicated, or invalid' \
  "$CHECK" signature chain-a 131 "$operator_address" "$expected_key" "$tmp/validator-set.json" \
  "$tmp/signed-commit.json"

printf '%s\n' runtime >"$tmp/runtime-decision.json"
printf '%s\n' decision-boundary >"$tmp/decision-boundary.marker"
touch -d '2 seconds ago' "$tmp/decision-boundary.marker"
touch "$tmp/ready.json" "$tmp/participant-evaluation.json" "$tmp/validator-set.json" \
  "$tmp/signature.json" "$tmp/runtime-decision.json" "$tmp/block.json"
"$CHECK" freshness 30 "$tmp/decision-boundary.marker" "$tmp/ready.json" \
  "$tmp/participant-evaluation.json" "$tmp/validator-set.json" \
  "$tmp/signature.json" "$tmp/runtime-decision.json" "$tmp/block.json" >"$tmp/freshness.json"
jq -e '.matched and (.snapshots | keys | length) == 6' "$tmp/freshness.json" >/dev/null
touch -r "$tmp/decision-boundary.marker" "$tmp/ready.json"
expect_failure stale-decision-status 'status decision snapshot does not postdate the decision boundary' \
  "$CHECK" freshness 30 "$tmp/decision-boundary.marker" "$tmp/ready.json" \
  "$tmp/participant-evaluation.json" "$tmp/validator-set.json" \
  "$tmp/signature.json" "$tmp/runtime-decision.json" "$tmp/block.json"
touch "$tmp/ready.json"
touch -r "$tmp/decision-boundary.marker" "$tmp/signature.json"
expect_failure stale-decision-commit 'commit decision snapshot does not postdate the decision boundary' \
  "$CHECK" freshness 30 "$tmp/decision-boundary.marker" "$tmp/ready.json" \
  "$tmp/participant-evaluation.json" "$tmp/validator-set.json" \
  "$tmp/signature.json" "$tmp/runtime-decision.json" "$tmp/block.json"
touch "$tmp/signature.json"
expect_failure missing-decision-runtime 'runtime decision snapshot is missing, empty, unreadable, or not a regular file' \
  "$CHECK" freshness 30 "$tmp/decision-boundary.marker" "$tmp/participant-evaluation.json" \
  "$tmp/participant-evaluation.json" "$tmp/validator-set.json" \
  "$tmp/signature.json" "$tmp/does-not-exist.json" "$tmp/block.json"
# These are literal source-contract probes, not shell expressions.
# shellcheck disable=SC2016
validator_height_query='evaluate-running-host-recovery.sh" validator-pages'
# shellcheck disable=SC2016
signature_window_expression='commit_height=$((height - offset))'
# shellcheck disable=SC2016
common_height_query='validators?height=$COMMON_HEIGHT'
grep -Fq "$validator_height_query" "$RECOVERY"
grep -Fq "$signature_window_expression" "$RECOVERY"
grep -Fq '/chain-rpc/commit?height=$commit_height' "$RECOVERY"
if grep -Fq "$common_height_query" "$RECOVERY"; then
  echo 'recovery must not infer current voting power from the lagging common height' >&2
  exit 1
fi

cat >"$tmp/split-link.json" <<'EOF'
{"schema_version":1,"validator_alias":"gdc-node4","ml_ssh_alias":"gdc-node4-ml","ml_endpoint":"192.0.2.44"}
EOF
runtime_id='qwen3-0.6b:gonka1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq'
jq -n --arg runtime_id "$runtime_id" '[{id:$runtime_id,host:"192.0.2.44"}]' >"$tmp/split-config.json"
"$CHECK" topology gdc-node4 "$runtime_id" gdc-node4-ml 192.0.2.44 false '' \
  "$tmp/split-link.json" "$tmp/split-config.json" >"$tmp/split-topology.json"
jq -e '.matched and .backup_topology_binding == "live-running-host" and .ml_endpoint == "192.0.2.44"' \
  "$tmp/split-topology.json" >/dev/null

if "$CHECK" topology gdc-node4 "$runtime_id" gdc-node4-ml 192.0.2.45 false '' \
  "$tmp/split-link.json" "$tmp/split-config.json" >"$tmp/remapped.out" 2>"$tmp/remapped.err"; then
  echo 'remapped split-GPU alias must fail recovery' >&2
  exit 1
fi
grep -Fq 'running split-GPU binding disagrees' "$tmp/remapped.err"

if "$CHECK" topology gdc-node4 "$runtime_id" gdc-node4-ml 192.0.2.44 true another-gpu \
  "$tmp/split-link.json" "$tmp/split-config.json" >"$tmp/archive-mismatch.out" 2>"$tmp/archive-mismatch.err"; then
  echo 'backup split-GPU alias mismatch must fail recovery' >&2
  exit 1
fi
grep -Fq 'validator backup split-GPU binding disagrees' "$tmp/archive-mismatch.err"

jq -n --arg runtime_id "$runtime_id" '[{id:$runtime_id,host:"192.0.2.45"}]' >"$tmp/remapped-config.json"
if "$CHECK" topology gdc-node4 "$runtime_id" gdc-node4-ml 192.0.2.44 false '' \
  "$tmp/split-link.json" "$tmp/remapped-config.json" >"$tmp/config-mismatch.out" 2>"$tmp/config-mismatch.err"; then
  echo 'remapped deployed ML endpoint must fail recovery' >&2
  exit 1
fi
grep -Fq 'deployed ML endpoint disagrees' "$tmp/config-mismatch.err"

wrong_runtime_id='qwen3-0.6b:gonka1pppppppppppppppppppppppppppppppppppppp'
jq -n --arg runtime_id "$wrong_runtime_id" '[{id:$runtime_id,host:"192.0.2.44"}]' >"$tmp/wrong-runtime-config.json"
if "$CHECK" topology gdc-node4 "$runtime_id" gdc-node4-ml 192.0.2.44 false '' \
  "$tmp/split-link.json" "$tmp/wrong-runtime-config.json" \
  >"$tmp/wrong-runtime.out" 2>"$tmp/wrong-runtime.err"; then
  echo 'another deployed runtime identity must fail recovery' >&2
  exit 1
fi
grep -Fq 'deployed node configuration has another or malformed runtime identity' "$tmp/wrong-runtime.err"

jq -n --arg runtime_id "$runtime_id" '[
  {id:$runtime_id,host:"192.0.2.44"},
  {id:"qwen3-0.6b:gonka1extra",host:"192.0.2.44"}
]' >"$tmp/extra-runtime-config.json"
if "$CHECK" topology gdc-node4 "$runtime_id" gdc-node4-ml 192.0.2.44 false '' \
  "$tmp/split-link.json" "$tmp/extra-runtime-config.json" \
  >"$tmp/extra-runtime.out" 2>"$tmp/extra-runtime.err"; then
  echo 'an extra deployed runtime identity must fail recovery' >&2
  exit 1
fi
grep -Fq 'deployed node configuration has another or malformed runtime identity' "$tmp/extra-runtime.err"

printf '\n' >"$tmp/colocated-link.json"
jq -n --arg runtime_id "$runtime_id" '[{id:$runtime_id,host:"inference"}]' >"$tmp/colocated-config.json"
"$CHECK" topology gdc-node1 "$runtime_id" '' '' false '' \
  "$tmp/colocated-link.json" "$tmp/colocated-config.json" >"$tmp/colocated-topology.json"
jq -e '.matched and .backup_topology_binding == "live-running-host" and .ml_endpoint == null' \
  "$tmp/colocated-topology.json" >/dev/null

echo 'PASS running Host recovery state predicate'
