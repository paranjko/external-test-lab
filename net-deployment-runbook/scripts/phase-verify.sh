#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
record_phase_profile verify
CHAIN_BASE="${GDC_CHAIN_PUBLIC_BASE:-https://$PUBLIC_EDGE_HOST}"
CHAIN_BASE="${CHAIN_BASE%/}"
BOOTSTRAP_DESCRIPTOR="$ROOT/bootstrap/release/${CHAIN_ID}.json"
RUN="$GDC_HOME/runs/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$RUN"
VERDICT_WRITTEN=false
on_exit() {
  local rc=$?
  if (( rc != 0 )) && [[ "$VERDICT_WRITTEN" == false ]]; then
    cat >"$RUN/verdict.md" <<EOF
# DevNet verification: INCONCLUSIVE

Verification stopped with exit code $rc. Inspect the phase output and evidence
bundle; no successful verdict is implied.
EOF
  fi
}
trap on_exit EXIT

step 'Record environment and topology'
capture_canonical_genesis "$CHAIN_BASE/chain-rpc/genesis" "$RUN/genesis.json"
genesis_sha256="$(genesis_sha256 "$RUN/genesis.json")"
{
  echo "timestamp=$(date -u +%FT%TZ)"
  echo "chain_id=$CHAIN_ID"
  echo "genesis_sha256=$genesis_sha256"
  echo "gonka_commit=$GONKA_COMMIT"
  echo "release_profile=$GDC_RELEASE_PROFILE"
  echo "model_profile=$GDC_MODEL_PROFILE"
  echo "profile_hash=$(profile_hash)"
  echo "model=$MODEL_ID@$MODEL_REVISION"
} >"$RUN/environment.txt"

fetch_broker_models() {
  local endpoint evidence status curl_status response_validation broker_list index=0
  local -a endpoints=() roles=()
  if [[ -r "$BOOTSTRAP_DESCRIPTOR" ]]; then
    broker_list="$RUN/bootstrap-broker-endpoints.txt"
    python3 "$ROOT/scripts/network-bootstrap.py" broker-urls "$BOOTSTRAP_DESCRIPTOR" >"$broker_list" \
      || die "Bootstrap descriptor is invalid: $BOOTSTRAP_DESCRIPTOR"
    mapfile -t endpoints <"$broker_list"
    (( ${#endpoints[@]} > 0 )) || die "Bootstrap descriptor has no broker endpoints: $BOOTSTRAP_DESCRIPTOR"
    roles=("bootstrap-broker")
  else
    endpoints=("https://$API_HOST")
    roles=("managed-genesis-api-fallback")
  fi
  for endpoint in "${endpoints[@]}"; do
    ((index += 1))
    evidence="$RUN/models-broker-$index.json"
    set +e
    status="$(curl -sS --connect-timeout 5 --max-time 15 -o "$evidence" -w '%{http_code}' "$endpoint/v1/models")"
    curl_status=$?
    set -e
    response_validation=UNAVAILABLE
    if (( curl_status == 0 )) && [[ "$status" =~ ^2[0-9][0-9]$ ]]; then
      if ! jq -e '.data | type == "array"' "$evidence" >/dev/null 2>&1; then
        response_validation=MALFORMED_MODEL_LIST
      elif ! jq -e --arg model "$MODEL_ID" '.data[] | select(.id == $model)' "$evidence" >/dev/null 2>&1; then
        response_validation=MISSING_CONFIGURED_MODEL
      else
        response_validation=PASS
      fi
    elif (( curl_status == 0 )); then
      response_validation=NON_2XX
    else
      response_validation=TRANSPORT_FAILURE
    fi
    printf 'BROKER_MODEL_ATTEMPT role=%s url=%s http_status=%s curl_status=%s response_validation=%s evidence=%s\n' \
      "${roles[0]}" "$endpoint/v1/models" "$status" "$curl_status" "$response_validation" "$evidence"
    [[ "$response_validation" == PASS ]] && { cp "$evidence" "$RUN/models-broker.json"; return 0; }
  done
  die 'canonical Bootstrap broker model discovery failed'
}

step 'Prove block progress with two state observations'
deadline=$((SECONDS + 120))
curl -fsS "$CHAIN_BASE/chain-rpc/status" >"$RUN/chain-status-first.json"
first="$(jq -er .result.sync_info.latest_block_height "$RUN/chain-status-first.json")"
while (( SECONDS < deadline )); do
  status="$(curl -fsS "$CHAIN_BASE/chain-rpc/status")"
  current="$(jq -r .result.sync_info.latest_block_height <<<"$status")"
  if (( current > first )); then
    jq . <<<"$status" >"$RUN/chain-status-second.json"
    break
  fi
  sleep 2
done
(( current > first )) || die "block height did not advance from $first"

mapfile -t nodes < <(printf '%s\n' "${GDC_NODES[@]}")
expected=${#nodes[@]}
(( expected > 0 )) || die 'canonical operator inventory has no Hosts'

# Fail before the full-epoch wait when local operator state omits an ACTIVE
# chain participant. Otherwise a reset runtime could disappear from the
# evidence set merely because its local joined marker was removed.
step 'Resolve the complete canonical Host inventory into public participant identities'
TOPOLOGY="$STATE/lineage/current-topology.json"
ssh "$GENESIS_NODE" 'curl -fsS http://127.0.0.1:1317/productscience/inference/inference/participant' \
  >"$RUN/participants-chain.json"
resolve_expected_network_participants "$RUN/expected-participants.json" "$CHAIN_ID" "$genesis_sha256" "$TOPOLOGY" "$RUN/participants-chain.json"
mapfile -t participant_records < <(jq -c '.participants[]' "$RUN/expected-participants.json")

step 'Reconcile the complete ACTIVE chain participant set with expected identities'
jq -e --slurpfile expected "$RUN/expected-participants.json" '
  ([.participant[]
    | select(.status == "ACTIVE" or .status == "PARTICIPANT_STATUS_ACTIVE" or .status == "1" or .status == 1)
    | {address, validator_key, public_host:(.inference_url | sub("^https://"; "") | sub("/$"; ""))}]
    | sort_by(.address))
  == ([$expected[0].participants[]
    | {address, validator_key, public_host}]
    | sort_by(.address))
' "$RUN/participants-chain.json" >/dev/null \
  || die 'ACTIVE chain participants differ from the complete expected identity set'

epoch_blocks="${GDC_VERIFY_EPOCH_BLOCKS:-$GENESIS_EPOCH_LENGTH}"
epoch_timeout="${GDC_EPOCH_WAIT_TIMEOUT_SECONDS:-2400}"
[[ "$epoch_blocks" =~ ^[1-9][0-9]*$ && "$epoch_timeout" =~ ^[1-9][0-9]*$ ]] || die 'epoch wait settings must be positive integers'
# A block-count interval alone is not enough: epoch groups become effective at
# a chain-scheduled height, which can be later than `first + epoch_blocks`.
# Anchor the evidence window to the next live group activation too.
ssh "$GENESIS_NODE" 'curl -fsS http://127.0.0.1:1317/productscience/inference/inference/current_epoch_group_data' >"$RUN/current-epoch-group-initial.json"
initial_group_epoch="$(jq -er '.epoch_group_data.epoch_index | tonumber' "$RUN/current-epoch-group-initial.json")"
initial_group_effective="$(jq -er '.epoch_group_data.effective_block_height | tonumber' "$RUN/current-epoch-group-initial.json")"
epoch_target=$((first + epoch_blocks))
group_target=$((initial_group_effective + epoch_blocks))
(( group_target > epoch_target )) && epoch_target=$group_target
step "Prove a complete $epoch_blocks-block interval and the next epoch-group activation from height $first to $epoch_target"
deadline=$((SECONDS + epoch_timeout))
while (( SECONDS < deadline )); do
  status="$(curl -fsS "$CHAIN_BASE/chain-rpc/status")"
  current="$(jq -r .result.sync_info.latest_block_height <<<"$status")"
  if (( current >= epoch_target )); then
    jq . <<<"$status" >"$RUN/chain-status-epoch.json"
    break
  fi
  printf 'WAIT  epoch height=%s target=%s\n' "$current" "$epoch_target"
  sleep 5
done
(( current >= epoch_target )) || die "chain did not reach the next epoch-group activation from $first"

step "Prove exactly $expected ACTIVE participants"
printf '[]' >"$RUN/participants.json"
for participant in "${participant_records[@]}"; do
  node="$(jq -er .node <<<"$participant")"
  address="$(jq -er .address <<<"$participant")"
  body="$(curl -fsS "$CHAIN_BASE/v2/participants/$address")"
  status="$(jq -r '.participant.status // empty' <<<"$body")"
  [[ "$status" =~ ^(ACTIVE|PARTICIPANT_STATUS_ACTIVE|1)$ ]] || die "$node is not ACTIVE: $status"
  jq --argjson item "$body" '. + [$item]' "$RUN/participants.json" >"$RUN/participants.tmp"
  mv "$RUN/participants.tmp" "$RUN/participants.json"
done
[[ "$(jq length "$RUN/participants.json")" -eq "$expected" ]] || die "participant count is not $expected"

step 'Prove synchronization, common-height hashes, model membership, and validation weights'
lag_threshold="${GDC_MAX_NODE_LAG_BLOCKS:-5}"
[[ "$lag_threshold" =~ ^[0-9]+$ ]] || die 'GDC_MAX_NODE_LAG_BLOCKS must be a non-negative integer'
printf '[]' >"$RUN/node-sync.json"
common_height="$current"
for node in "${nodes[@]}"; do
  node_status="$(curl -fsS "$(node_url "$node")/chain-rpc/status")"
  node_height="$(jq -er .result.sync_info.latest_block_height <<<"$node_status")"
  lag=$((current - node_height)); (( lag >= 0 )) || lag=0
  (( lag <= lag_threshold )) || die "$node lag $lag exceeds threshold $lag_threshold"
  (( node_height < common_height )) && common_height="$node_height"
  jq --arg node "$node" --argjson height "$node_height" --argjson lag "$lag" \
    '. + [{node:$node,height:$height,lag:$lag}]' "$RUN/node-sync.json" >"$RUN/node-sync.tmp"
  mv "$RUN/node-sync.tmp" "$RUN/node-sync.json"
done
for node in "${nodes[@]}"; do
  hash="$(curl -fsS "$(node_url "$node")/chain-rpc/block?height=$common_height" | jq -er .result.block_id.hash)"
  jq --arg node "$node" --arg hash "$hash" \
    'map(if .node == $node then . + {common_height_hash:$hash} else . end)' \
    "$RUN/node-sync.json" >"$RUN/node-sync.tmp"
  mv "$RUN/node-sync.tmp" "$RUN/node-sync.json"
done
jq -e '[.[].common_height_hash] | unique | length == 1' "$RUN/node-sync.json" >/dev/null || die 'nodes disagree on common-height block hash'
fetch_broker_models
# The 0.2.14 decentralized API intentionally exposes the model catalog at
# /v1/models, while current epoch group and committed weights are chain REST
# queries. Keep the latter on the Genesis participant loopback rather than treating a nonexistent
# public /v2/models aggregate as evidence.
ssh "$GENESIS_NODE" 'curl -fsS http://127.0.0.1:1317/productscience/inference/inference/current_epoch_group_data' >"$RUN/current-epoch-group.json"
final_group_epoch="$(jq -er '.epoch_group_data.epoch_index | tonumber' "$RUN/current-epoch-group.json")"
(( final_group_epoch > initial_group_epoch )) || die "live epoch group did not advance beyond epoch $initial_group_epoch"
jq -e --arg model "$MODEL_ID" '.epoch_group_data.sub_group_models | index($model) != null' "$RUN/current-epoch-group.json" >/dev/null || die "model group $MODEL_ID is absent from the live epoch group"
jq -e '.epoch_group_data.validation_weights | type == "array" and length > 0' "$RUN/current-epoch-group.json" >/dev/null || die 'non-empty validation weights were not observed'
jq -e '(.epoch_group_data.validation_weights | map(.weight | tonumber) | add) as $committed
  | (.epoch_group_data.total_weight | tonumber) as $total
  | $committed > 0 and $committed == $total' "$RUN/current-epoch-group.json" >/dev/null || die 'committed validation-weight total is absent or differs from the epoch total'
for participant in "${participant_records[@]}"; do
  node="$(jq -er .node <<<"$participant")"
  address="$(jq -er .address <<<"$participant")"
  jq -e --arg address "$address" '
    [(.epoch_group_data.validation_weights[]?.member_address),
     (.epoch_group_data.member_seed_signatures[]?.member_address)]
    | index($address) != null
  ' "$RUN/current-epoch-group.json" >/dev/null || die "$node is absent from the live epoch group"
done

step 'Record direct evidence from each deployed ML runtime'
ml_hosts=()
for node in "${nodes[@]}"; do
  host="$(node_ml_host "$node" || printf '%s' "$node")"
  ml_hosts+=("$host")
done
"$ROOT/scripts/capture-deployed-ml-evidence.sh" "$RUN/ml-runtime" "$MODEL_ID" "${ml_hosts[@]}"

step 'Assess operator-record style in the complete rehearsal log'
STYLE="$RUN/style-consistency.md"
if [[ -n "${GDC_RUN_LOG:-}" && -s "$GDC_RUN_LOG" ]]; then
  awk '
    /^(WAIT|READY|PASS|SKIP|BLOCKED|FAILED|PROFILE|BEGIN|END)[[:space:]]/ { counts[$1]++ }
    END {
      print "# Rehearsal output style assessment"
      print ""
      print "Source run log: " ENVIRON["GDC_RUN_LOG"]
      print ""
      for (kind in counts) printf "- %s records: %d\n", kind, counts[kind]
      if (counts["BEGIN"] > 0 && counts["PROFILE"] > 0) {
        print ""
        print "PASS: phase boundaries and machine-readable operational records are present."
      } else {
        print ""
        print "INCONCLUSIVE: the run log lacks phase boundaries or profile records."
        exit 1
      }
    }
  ' "$GDC_RUN_LOG" >"$STYLE"
else
  cat >"$STYLE" <<EOF
# Rehearsal output style assessment

INCONCLUSIVE: no complete operator run log was provided. Run phases through
\`./gdc.sh\` so their output is appended to the active rehearsal log.
EOF
  die 'no complete operator run log; invoke phases through ./gdc.sh'
fi

cat >"$RUN/verdict.md" <<EOF
# DevNet verification: PASS

- $expected configured logical participants are ACTIVE;
- block height advanced from $first to $current, crossing one complete $epoch_blocks-block epoch;
- every joined node is within $lag_threshold blocks and shares the block hash at height $common_height;
- $MODEL_ID has a live group with non-empty validation weights;
- deployed ML model/completion evidence is retained separately and is not treated
  as chain-accounted inference;
- output style assessment: $STYLE.
EOF
VERDICT_WRITTEN=true
printf '\nPASS evidence: %s\n' "$RUN"
