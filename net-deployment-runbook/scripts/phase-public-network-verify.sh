#!/usr/bin/env bash
set -Eeuo pipefail

# Gate B observes only public chain/Host state plus sanitized receipts staged
# under this observer's GDC_HOME. It does not read another operator's keys,
# account files, joined markers, or SSH configuration.
source "$(dirname "$0")/lib.sh"

CHAIN_BASE="${GDC_CHAIN_PUBLIC_BASE:-}"
[[ "$CHAIN_BASE" =~ ^https://[A-Za-z0-9.-]+$ ]] \
  || die 'GDC_CHAIN_PUBLIC_BASE must be an HTTPS public chain endpoint'
CHAIN_BASE="${CHAIN_BASE%/}"
RELEASE_PROFILE="${GDC_RELEASE_PROFILE:-v2026.07.23}"
PROFILE_FILE="$ROOT/profiles/releases/$RELEASE_PROFILE.lock"
[[ -s "$PROFILE_FILE" ]] || die "unknown release profile: $RELEASE_PROFILE"
profile_value() { awk -F= -v key="$1" '$1 == key { print $2; exit }' "$PROFILE_FILE"; }
MODEL_ID="${GDC_VERIFY_MODEL_ID:-Qwen/Qwen3-0.6B}"
LAG_THRESHOLD="$(profile_value GDC_MAX_NODE_LAG_BLOCKS)"
PROGRESS_TIMEOUT="$(profile_value GDC_GATE_B_PROGRESS_TIMEOUT_SECONDS)"
PROGRESS_POLL="$(profile_value GDC_GATE_B_PROGRESS_POLL_SECONDS)"
[[ "$LAG_THRESHOLD" =~ ^[0-9]+$ && "$PROGRESS_TIMEOUT" =~ ^[1-9][0-9]*$ && "$PROGRESS_POLL" =~ ^[1-9][0-9]*$ ]] \
  || die 'release profile must define valid Gate B convergence bounds'
EXPECTED_COUNT=5
TOPOLOGY="$STATE/lineage/current-topology.json"
GATE_A="$GDC_HOME/receipts/gate-a"
RUN="$GDC_HOME/runs/${GDC_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-manual}/public-network-verify"
export EVIDENCE_PHASE_NAME=public-network-verify
mkdir -p "$RUN"
GENESIS_SHA256=UNAVAILABLE
ACTIVE_PARTICIPANT_COUNT=0
EFFECTIVE_VALIDATOR_COUNT=0
VERDICT_WRITTEN=false

write_verdict() {
  local verdict="$1" reason="$2"
  jq -n --arg verdict "$verdict" --arg reason "$reason" --arg run_id "${GDC_RUN_ID:-manual}" \
    --arg genesis_sha256 "$GENESIS_SHA256" --arg chain_id "${CHAIN_ID:-UNAVAILABLE}" --arg chain_base "$CHAIN_BASE" \
    --arg release_profile "$RELEASE_PROFILE" --arg release_profile_sha256 "${RELEASE_PROFILE_SHA256:-UNAVAILABLE}" \
    --arg topology "$TOPOLOGY" \
    --arg gate_a "$GATE_A" --argjson active_participant_count "$ACTIVE_PARTICIPANT_COUNT" \
    --argjson effective_validator_count "$EFFECTIVE_VALIDATOR_COUNT" \
    '{schema_version:1,verdict:$verdict,reason:$reason,run_id:$run_id,chain_id:$chain_id,
      genesis_sha256:$genesis_sha256,chain_base:$chain_base,release_profile:$release_profile,
      release_profile_sha256:$release_profile_sha256,
      topology:$topology,gate_a:$gate_a,active_participant_count:$active_participant_count,
      effective_validator_count:$effective_validator_count}' >"$RUN/receipt.json"
  cat >"$RUN/verdict.md" <<EOF
# Public network verification: $verdict

$reason
EOF
  VERDICT_WRITTEN=true
}
on_exit() { local rc=$?; if (( rc != 0 )) && [[ "$VERDICT_WRITTEN" == false ]]; then write_verdict INCONCLUSIVE "public Gate B observer stopped with exit code $rc"; fi; }
trap on_exit EXIT
blocked() { write_verdict BLOCKED "$1"; printf 'BLOCKED %s; evidence: %s\n' "$1" "$RUN" >&2; exit 3; }
failed() { write_verdict FAIL "$1"; printf 'FAIL %s; evidence: %s\n' "$1" "$RUN" >&2; exit 1; }
inconclusive() { write_verdict INCONCLUSIVE "$1"; printf 'INCONCLUSIVE %s; evidence: %s\n' "$1" "$RUN" >&2; exit 2; }

step 'Render and bind current-lineage sanitized topology'
GDC_CHAIN_PUBLIC_BASE="$CHAIN_BASE" "$ROOT/scripts/render-current-lineage-topology.sh" \
  || blocked 'current-lineage topology cannot be rendered from sanitized JOIN receipts'
capture_canonical_genesis "$CHAIN_BASE/chain-rpc/genesis" "$RUN/genesis.json" \
  || inconclusive 'cannot capture canonical public Genesis'
GENESIS_SHA256="$(genesis_sha256 "$RUN/genesis.json")"
CHAIN_ID="$(jq -er .chain_id "$RUN/genesis.json")"
write_phase_lineage "$RUN" "$CHAIN_ID" "$GENESIS_SHA256"
RELEASE_PROFILE_SHA256="$(awk -F= '$1 == "release_profile_sha256" {print $2; exit}' "$(run_manifest_path)")"
jq -e --arg hash "$GENESIS_SHA256" --arg chain "$CHAIN_ID" --argjson expected "$EXPECTED_COUNT" '
  .genesis_sha256 == $hash and .chain_id == $chain and (.participants | length == $expected)
  and (([.participants[].address] | length) == ([.participants[].address] | unique | length))
  and (([.participants[].validator_key] | length) == ([.participants[].validator_key] | unique | length))
  and (([.participants[].runtime_id] | length) == ([.participants[].runtime_id] | unique | length))
  and all(.participants[]; .runtime_id == ("qwen3-0.6b:" + .address)
    and (.poc_participant_weight | tonumber) > 0
    and (.poc_accepted_weight_sum | tonumber) == (.poc_committed_total | tonumber)
    and (.poc_distribution_tx_code | tonumber) == 0)
' "$TOPOLOGY" >/dev/null || blocked 'topology is incomplete, contains duplicate identities, stale lineage, or non-canonical JOIN evidence'
cp "$TOPOLOGY" "$RUN/expected-topology.json"

step 'Require authentic external Gate A evidence before evaluating Gate B'
[[ -s "$GATE_A/receipt.json" && -s "$GATE_A/verdict.md" ]] \
  || blocked 'Gate B requires the externally attested Gate A receipt from issue #28; it is not present in the managed receipt inbox'
grep -qx '# JOIN acceptance: PASS' "$GATE_A/verdict.md" \
  || blocked 'Gate A evidence does not declare an independent JOIN_PASS'
jq -e --arg hash "$GENESIS_SHA256" '
  .verdict == "PASS" and .genesis_sha256 == $hash
  and (.participant_address | type == "string" and length > 0)
  and (.validator_key | type == "string" and length > 0)
  and (.runtime_id == ("qwen3-0.6b:" + .participant_address))
  and .poc_accepted_once == true
  and (.poc_participant_weight | tonumber) > 0
  and (.poc_accepted_weight_sum | tonumber) == (.poc_committed_total | tonumber)
  and (.poc_distribution_tx_code | tonumber) == 0
' "$GATE_A/receipt.json" >/dev/null || blocked 'Gate A receipt is stale or does not prove an accepted independent JOIN'
receipt_sha256="$(sha256sum "$GATE_A/receipt.json" | awk '{print $1}')"
curl -fsS --connect-timeout 5 --max-time 15 \
  'https://api.github.com/repos/paranjko/external-test-lab/issues/28/comments?per_page=100' \
  >"$RUN/issue-28-comments.json" \
  || inconclusive 'cannot retrieve public issue #28 operator evidence'
jq -e --arg receipt_sha256 "$receipt_sha256" '
  any(.[]; .user.login == "akamitch" and (.body | contains($receipt_sha256)))
' "$RUN/issue-28-comments.json" >/dev/null \
  || blocked 'issue #28 external JOIN receipt is not authenticated by an akamitch comment containing its SHA-256'
jq --slurpfile gate_a "$GATE_A/receipt.json" '
  any(.participants[]; .address == $gate_a[0].participant_address
    and .validator_key == $gate_a[0].validator_key and .runtime_id == $gate_a[0].runtime_id)
' "$TOPOLOGY" >/dev/null || blocked 'Gate A external JOIN receipt is not part of the current-lineage topology'

step 'Capture exactly five ACTIVE participants and live consensus validators'
curl -fsS --connect-timeout 5 --max-time 15 "$CHAIN_BASE/chain-api/productscience/inference/inference/participant" >"$RUN/participants-chain.json" \
  || inconclusive 'cannot read public participant state'
curl -fsS --connect-timeout 5 --max-time 15 "$CHAIN_BASE/chain-rpc/validators?per_page=100" >"$RUN/validators.json" \
  || inconclusive 'cannot read public consensus validator set'
jq '[.participant[] | select(.status == "ACTIVE" or .status == "PARTICIPANT_STATUS_ACTIVE" or .status == "1" or .status == 1)
  | {address,validator_key,inference_url,status}] | sort_by(.address)' "$RUN/participants-chain.json" >"$RUN/active-participants.json"
ACTIVE_PARTICIPANT_COUNT="$(jq length "$RUN/active-participants.json")"
(( ACTIVE_PARTICIPANT_COUNT == EXPECTED_COUNT )) || failed "expected five ACTIVE participants, observed $ACTIVE_PARTICIPANT_COUNT"
jq -e --slurpfile expected "$TOPOLOGY" '
  ([.[] | {address,validator_key,public_host:(.inference_url | sub("^https://"; ""))}] | sort_by(.address))
  == ([$expected[0].participants[] | {address,validator_key,public_host}] | sort_by(.address))
' "$RUN/active-participants.json" >/dev/null || failed 'ACTIVE participant identities do not match the current-lineage topology'

step 'Prove block progress and public endpoint convergence'
curl -fsS --connect-timeout 5 --max-time 15 "$CHAIN_BASE/chain-rpc/status" >"$RUN/status-first.json" || inconclusive 'cannot read initial chain status'
first_height="$(jq -er '.result.sync_info.latest_block_height | tonumber' "$RUN/status-first.json")"
deadline=$((SECONDS + PROGRESS_TIMEOUT))
current_height=0
while (( SECONDS < deadline )); do
  curl -fsS --connect-timeout 5 --max-time 15 "$CHAIN_BASE/chain-rpc/status" >"$RUN/status-second.json" || true
  current_height="$(jq -r '.result.sync_info.latest_block_height // 0 | tonumber' "$RUN/status-second.json" 2>/dev/null || printf 0)"
  (( current_height > first_height )) && break
  printf 'WAIT  Gate B height=%s initial=%s deadline_seconds=%s\n' "$current_height" "$first_height" "$((deadline - SECONDS))"
  sleep "$PROGRESS_POLL"
done
(( current_height > first_height )) || inconclusive "public chain did not advance beyond height $first_height"

printf '[]' >"$RUN/participant-observations.json"
common_height="$current_height"
while IFS= read -r participant; do
  address="$(jq -er .address <<<"$participant")"
  validator_key="$(jq -er .validator_key <<<"$participant")"
  endpoint="$(jq -er .inference_url <<<"$participant")"
  status="$(curl -fsS --connect-timeout 5 --max-time 15 "$endpoint/chain-rpc/status" 2>/dev/null || true)"
  node_height="$(jq -r '.result.sync_info.latest_block_height // 0 | tonumber' <<<"$status" 2>/dev/null || printf 0)"
  catching_up="$(jq -r '.result.sync_info.catching_up // true' <<<"$status" 2>/dev/null || printf true)"
  lag=$((current_height - node_height)); (( lag >= 0 )) || lag=0
  [[ "$catching_up" == false && "$lag" -le "$LAG_THRESHOLD" ]] \
    || failed "$address is not synchronized (height=$node_height lag=$lag catching_up=$catching_up)"
  (( node_height < common_height )) && common_height="$node_height"
  curl -fsS --connect-timeout 5 --max-time 15 "$CHAIN_BASE/chain-api/productscience/inference/inference/hardware_nodes/$address" >"$RUN/hardware-$address.json" \
    || inconclusive "cannot read runtime state for $address"
  runtime="qwen3-0.6b:$address"
  jq -e --arg runtime "$runtime" --arg model "$MODEL_ID" '
    .nodes.hardware_nodes | any(.[]; .local_id == $runtime and (.models | index($model) != null)
      and (.status == "INFERENCE" or .status == "POC"))
  ' "$RUN/hardware-$address.json" >/dev/null || failed "$address lacks its exact public runtime identity"
  jq -e --arg key "$validator_key" '.result.validators | any(.[]; .pub_key.value == $key and (.voting_power | tonumber) > 0)' "$RUN/validators.json" >/dev/null \
    || failed "$address is ACTIVE but not an effective consensus validator with positive voting power"
  EFFECTIVE_VALIDATOR_COUNT=$((EFFECTIVE_VALIDATOR_COUNT + 1))
  jq --argjson participant "$participant" --arg runtime_id "$runtime" --argjson height "$node_height" --argjson lag "$lag" \
    '. + [$participant + {runtime_id:$runtime_id,height:$height,lag:$lag}]' "$RUN/participant-observations.json" >"$RUN/participant-observations.tmp"
  mv "$RUN/participant-observations.tmp" "$RUN/participant-observations.json"
done < <(jq -c '.[]' "$RUN/active-participants.json")
(( EFFECTIVE_VALIDATOR_COUNT == EXPECTED_COUNT )) || failed 'effective validator count is not five'

step "Compare common-height block and app hashes at $common_height"
printf '[]' >"$RUN/common-height-hashes.json"
while IFS= read -r endpoint; do
  curl -fsS --connect-timeout 5 --max-time 15 "$endpoint/chain-rpc/block?height=$common_height" \
    | jq -c '{block_hash:.result.block_id.hash,app_hash:.result.block.header.app_hash}' >>"$RUN/common-height-hashes.jsonl" \
    || inconclusive 'cannot read a common-height block'
done < <(jq -r '.[].inference_url' "$RUN/active-participants.json")
jq -s . "$RUN/common-height-hashes.jsonl" >"$RUN/common-height-hashes.json"
jq -e '([.[].block_hash] | unique | length == 1) and ([.[].app_hash] | unique | length == 1)' "$RUN/common-height-hashes.json" >/dev/null \
  || failed 'participants disagree on common-height block hash or app hash'

step 'Require complete confirmation-PoC evidence for this five-validator lineage'
set +e
GDC_CHAIN_PUBLIC_BASE="$CHAIN_BASE" GDC_RELEASE_PROFILE="$RELEASE_PROFILE" GDC_RUN_ID="${GDC_RUN_ID:-manual}" \
  "$ROOT/scripts/phase-confirmation-poc.sh"
cpoc_rc=$?
set -e
cpoc_dir="$GDC_HOME/runs/${GDC_RUN_ID:-manual}/confirmation-poc"
[[ -s "$cpoc_dir/receipt.json" ]] || inconclusive 'confirmation-PoC observer did not produce evidence'
cp "$cpoc_dir/receipt.json" "$RUN/confirmation-poc-receipt.json"
[[ "$cpoc_rc" -eq 0 ]] || { write_verdict INCONCLUSIVE 'five-validator topology is healthy so far, but confirmation-PoC is not yet proven'; exit "$cpoc_rc"; }

step 'Run three consecutive authenticated gateway completions'
key_file="$STATE/secrets/gateway.join-client-key"
if [[ ! -s "$key_file" ]]; then
  step 'Import verified scoped gateway credential from the public bootstrap'
  bootstrap_tmp="$(mktemp -d)"
  bootstrap_base="$CHAIN_BASE/join-bootstrap"
  if ! curl -fsS --connect-timeout 5 --max-time 30 "$bootstrap_base/manifest.sha256" >"$bootstrap_tmp/manifest.sha256" \
    || ! curl -fsS --connect-timeout 5 --max-time 30 "$bootstrap_base/gateway/join-client-key" >"$bootstrap_tmp/join-client-key"; then
    rm -rf "$bootstrap_tmp"
    inconclusive 'cannot retrieve the public bootstrap scoped gateway credential'
  fi
  expected_key_sha="$(awk '$2 ~ /(^|\/)gateway\/join-client-key$/ {print $1; exit}' "$bootstrap_tmp/manifest.sha256")"
  if [[ ! "$expected_key_sha" =~ ^[0-9a-f]{64}$ ]] || ! printf '%s  %s\n' "$expected_key_sha" "$bootstrap_tmp/join-client-key" | sha256sum -c - >/dev/null; then
    rm -rf "$bootstrap_tmp"
    blocked 'public bootstrap gateway credential is missing from, or mismatches, its manifest'
  fi
  install -d -m 0700 "$STATE/secrets"
  install -m 0600 "$bootstrap_tmp/join-client-key" "$key_file"
  rm -rf "$bootstrap_tmp"
fi
[[ -s "$key_file" && "$(stat -c %a "$key_file")" == 600 ]] \
  || blocked 'no mode-0600 scoped gateway client credential is available for the required Gate B completions'
gateway_url="${GDC_GATEWAY_PUBLIC_URL:-https://api.gonka-dev.net}"
client_key="$(cut -d, -f1 <"$key_file")"
for attempt in 1 2 3; do
  "$ROOT/04-ops/test-inference-until-ready.sh" "$gateway_url" "$client_key" "$RUN/gateway-$attempt" "$RUN/completion-$attempt.json" 180 \
    || failed "authenticated Gate B completion $attempt/3 did not succeed"
done

write_verdict PASS 'five ACTIVE participants are five effective validators with unique runtimes, accepted canonical PoC receipts, common-height convergence, complete confirmation-PoC, and three authenticated completions'
printf 'PASS Gate B evidence: %s\n' "$RUN"
