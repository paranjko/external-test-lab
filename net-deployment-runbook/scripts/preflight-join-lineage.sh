#!/usr/bin/env bash
# Resolve the cold-JOIN state-acquisition decision before software download or
# any Host operation. Bootstrap v1 deliberately contains no mutable trust or
# snapshot data, so this receipt records only observations made for this run.
set -Eeuo pipefail

usage() { echo "Usage: $0 --bootstrap-file FILE (--observation FILE | --composition-env FILE) --receipt FILE --env FILE" >&2; }
die() {
  if [[ -n "${GDC_JOIN_LINEAGE_FAILURE_FILE:-}" ]]; then
    umask 077
    printf '%s\n' "$1" >"$GDC_JOIN_LINEAGE_FAILURE_FILE"
  fi
  printf 'lineage_%s: %s\n' "$1" "$2" >&2; exit 1
}
BOOTSTRAP=''; OBSERVATION=''; COMPOSITION=''; RECEIPT=''; ENV_FILE=''
while (($#)); do case "$1" in
  --bootstrap-file) BOOTSTRAP="${2:-}"; shift 2 ;;
  --observation) OBSERVATION="${2:-}"; shift 2 ;;
  --composition-env) COMPOSITION="${2:-}"; shift 2 ;;
  --receipt) RECEIPT="${2:-}"; shift 2 ;;
  --env) ENV_FILE="${2:-}"; shift 2 ;;
  *) usage; exit 2 ;;
esac; done
[[ -r "$BOOTSTRAP" && -n "$RECEIPT" && -n "$ENV_FILE" ]] || { usage; exit 2; }
[[ -z "$OBSERVATION" || -z "$COMPOSITION" ]] || { usage; exit 2; }
[[ -n "$OBSERVATION" || -n "$COMPOSITION" ]] || { usage; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v curl >/dev/null || die dependency 'curl is required'
command -v jq >/dev/null || die dependency 'jq is required'
"$ROOT/scripts/network-bootstrap.sh" verify "$BOOTSTRAP" >/dev/null
if [[ -n "$OBSERVATION" ]]; then
  [[ -r "$OBSERVATION" ]] || { usage; exit 2; }
  jq -e '
    .schema_version == 1 and .kind == "gdc-network-observation" and
    .result == {state:"ready",reason:"none"} and
    (.network_state_id | test("^[a-f0-9]{64}$")) and
    (.bootstrap.chain_id | type == "string" and length > 0) and
    (.bootstrap.genesis_sha256 | test("^[a-f0-9]{64}$")) and
    (.runtime.core.version | type == "string" and length > 0) and
    (.runtime.core.commit | test("^[a-f0-9]{40}$")) and
    (.runtime.dapi.version | type == "string" and length > 0) and
    (.runtime.dapi.commit | test("^[a-f0-9]{40}$")) and
    (.runtime_api_origins | type == "array" and length > 0)
  ' "$OBSERVATION" >/dev/null || die configuration 'network observation is not a ready v1 document'
  [[ "$(jq -r .bootstrap.chain_id "$OBSERVATION")" == "$(jq -r .chain_id "$BOOTSTRAP")" ]] \
    || die configuration 'observation and Bootstrap chain IDs differ'
  [[ "$(jq -r .bootstrap.genesis_sha256 "$OBSERVATION")" == "$(jq -r .genesis.sha256 "$BOOTSTRAP")" ]] \
    || die configuration 'observation and Bootstrap Genesis digests differ'
  [[ "$(jq -r .bootstrap.document_sha256 "$OBSERVATION")" == "$(sha256sum "$BOOTSTRAP" | awk '{print $1}')" ]] \
    || die configuration 'observation does not bind this Bootstrap document'
  observation_expiry="$(jq -r .expires_at "$OBSERVATION")"
  observation_expiry_epoch="$(date -u -d "$observation_expiry" +%s 2>/dev/null || true)"
  [[ "$observation_expiry_epoch" =~ ^[0-9]+$ && "$observation_expiry_epoch" -gt "$(date -u +%s)" ]] \
    || die observation_expired 'network observation is no longer fresh'
  GDC_NETWORK_FINGERPRINT="$(jq -r .network_state_id "$OBSERVATION")"
  GDC_NETWORK_CHAIN_ID="$(jq -r .bootstrap.chain_id "$OBSERVATION")"
  GDC_NETWORK_GENESIS_SHA256="$(jq -r .bootstrap.genesis_sha256 "$OBSERVATION")"
  GDC_NETWORK_CORE_VERSION="$(jq -r .runtime.core.version "$OBSERVATION")"
  GDC_NETWORK_CORE_COMMIT="$(jq -r .runtime.core.commit "$OBSERVATION")"
  GDC_NETWORK_DAPI_VERSION="$(jq -r .runtime.dapi.version "$OBSERVATION")"
  GDC_NETWORK_DAPI_COMMIT="$(jq -r .runtime.dapi.commit "$OBSERVATION")"
  OBSERVATION_SHA256="$(sha256sum "$OBSERVATION" | awk '{print $1}')"
  RUNTIME_SOURCE_KIND=network_observation
  RUNTIME_SOURCE_ID="$GDC_NETWORK_FINGERPRINT"
else
  # Compatibility input for the old JOIN dispatcher. New JOIN callers must
  # pass --observation; this branch is retained until that dispatcher moves.
  # shellcheck disable=SC1090
  source "$COMPOSITION"
  [[ "${GDC_NETWORK_FINGERPRINT:-}" =~ ^[0-9a-f]{64}$ ]] || die configuration 'missing network fingerprint'
  [[ "${GDC_NETWORK_CHAIN_ID:-}" == "$(jq -r .chain_id "$BOOTSTRAP")" ]] || die configuration 'composition and Bootstrap chain IDs differ'
  [[ "${GDC_NETWORK_GENESIS_SHA256:-}" == "$(jq -r .genesis.sha256 "$BOOTSTRAP")" ]] || die configuration 'composition and Bootstrap Genesis digests differ'
  # shellcheck disable=SC1091 # ROOT is resolved above.
  source "$ROOT/scripts/profile.sh"
  load_profiles
  OBSERVATION_SHA256=''
  RUNTIME_SOURCE_KIND=legacy_composition
  RUNTIME_SOURCE_ID="$GDC_NETWORK_FINGERPRINT"
fi

period="${GDC_JOIN_TRUSTED_BLOCK_PERIOD:-2000}"
early_height="${GDC_JOIN_EARLY_CHECKPOINT_HEIGHT:-5}"
ttl="${GDC_JOIN_PREFLIGHT_TTL_SECONDS:-600}"
[[ "$period" =~ ^[1-9][0-9]*$ && "$early_height" =~ ^[1-9][0-9]*$ && "$ttl" =~ ^[1-9][0-9]*$ ]] || die configuration 'trust period, early checkpoint and receipt TTL must be positive'
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT

# Tests can supply a closed host=id map. Production always resolves a host to
# its IPv4 address. The map avoids treating two test aliases as independent.
fault_domain() {
  local host="$1" entry
  if [[ -n "${GDC_JOIN_FAULT_DOMAIN_MAP:-}" ]]; then
    IFS=, read -r -a entries <<<"$GDC_JOIN_FAULT_DOMAIN_MAP"
    for entry in "${entries[@]}"; do [[ "$entry" == "$host="* ]] && { printf '%s' "${entry#*=}"; return; }; done
    return 1
  fi
  getent ahostsv4 "$host" 2>/dev/null | awk 'NR == 1 {print $1}'
}

record_from_block() {
  jq -cer '{height:(.result.block.header.height|tonumber),block_id:(.result.block_id.hash|ascii_downcase),app_hash:(.result.block.header.app_hash|ascii_downcase)}'
}
one_record() {
  local label="$1"; shift
  local -a unique=()
  mapfile -t unique < <(printf '%s\n' "$@" | LC_ALL=C sort -u)
  (( ${#unique[@]} == 1 )) || die rpc_quorum_conflict "independent RPCs disagree at $label"
  printf '%s' "${unique[0]}"
}
p2p_for_rpc() {
  local rpc="$1" index node_id p2p
  index="$(jq -r --arg rpc "$rpc" '.seeds | to_entries[] | select(.value.rpc == $rpc) | .key' "$BOOTSTRAP" | head -1)"
  [[ "$index" =~ ^[0-9]+$ ]] || return 1
  node_id="$(jq -r ".seeds[$index].node_id" "$BOOTSTRAP")"
  p2p="$(jq -r ".seeds[$index].p2p" "$BOOTSTRAP")"
  [[ "$node_id" =~ ^[0-9a-f]{40}$ && "$p2p" =~ ^tcp://[A-Za-z0-9.-]+:[0-9]{2,5}$ ]] || return 1
  printf '%s@%s' "$node_id" "$p2p"
}

mapfile -t rpcs < <(jq -r '.seeds[].rpc' "$BOOTSTRAP")
(( ${#rpcs[@]} >= 2 )) || die rpc_quorum_conflict 'Bootstrap has fewer than two RPC seeds'
declare -a good_rpcs=() domains=() heights=()
for rpc in "${rpcs[@]}"; do
  host="${rpc#https://}"; host="${host%%/*}"
  domain="$(fault_domain "$host" || true)"
  [[ "$domain" =~ ^[A-Za-z0-9._:-]+$ ]] || die rpc_quorum_conflict "cannot establish fault domain for $host"
  status="$tmp/status-${#good_rpcs[@]}.json"
  curl -fsS --connect-timeout 5 --max-time 15 "${rpc%/}/status" >"$status" 2>/dev/null || continue
  jq -e --arg chain "$GDC_NETWORK_CHAIN_ID" '.result.node_info.network == $chain and (.result.sync_info.latest_block_height|tonumber) > 0' "$status" >/dev/null || continue
  good_rpcs+=("$rpc"); domains+=("$domain"); heights+=("$(jq -r '.result.sync_info.latest_block_height' "$status")")
done
[[ "$(printf '%s\n' "${domains[@]}" | LC_ALL=C sort -u | wc -l)" -ge 2 ]] || die rpc_fault_domain_alias 'two RPC URLs resolve to one fault domain'
(( ${#good_rpcs[@]} >= 2 )) || die rpc_quorum_conflict 'fewer than two readable RPC observations attest the selected chain'

# Choose the highest attested tip. A status height is only a proposal: two
# independent domains must serve the same header/AppHash there. A failed block
# read is a non-vote, while a malformed successful response is unsafe. One
# outlier is tolerated; A,A,B,C is not.
declare -a quorum_rpcs=() quorum_domains=()
select_tip_quorum() {
  local candidate i file record best='' best_count=0 group_count=0 responding count
  local -a records=() indices=() groups=() candidates=() candidate_domains=()
  mapfile -t candidates < <(printf '%s\n' "${heights[@]}" | LC_ALL=C sort -nr -u)
  for candidate in "${candidates[@]}"; do
    records=(); indices=(); candidate_domains=()
    for i in "${!good_rpcs[@]}"; do
      (( heights[i] >= candidate )) || continue
      [[ " ${candidate_domains[*]} " == *" ${domains[$i]} "* ]] && continue
      file="$tmp/tip-${candidate}-${i}.json"
      curl -fsS --connect-timeout 5 --max-time 15 "${good_rpcs[$i]%/}/block?height=$candidate" >"$file" 2>/dev/null || continue
      record="$(record_from_block <"$file")" || die rpc_quorum_conflict "malformed tip checkpoint from ${good_rpcs[$i]}"
      records+=("$record"); indices+=("$i"); candidate_domains+=("${domains[$i]}")
    done
    (( ${#records[@]} >= 2 )) || continue
    mapfile -t groups < <(printf '%s\n' "${records[@]}" | LC_ALL=C sort | uniq -c)
    best=''; best_count=0; group_count=0
    for group in "${groups[@]}"; do
      count="$(awk '{print $1}' <<<"$group")"
      # shellcheck disable=SC2001 # preserve the JSON record after uniq's count
      record="$(sed 's/^[[:space:]]*[0-9][0-9]*[[:space:]]*//' <<<"$group")"
      if (( count >= 2 )); then
        group_count=$((group_count + 1))
        if (( count > best_count )); then best="$record"; best_count="$count"; fi
      fi
    done
    responding="${#records[@]}"
    (( group_count == 1 && best_count >= 2 && responding - best_count <= 1 )) || continue
    quorum_rpcs=(); quorum_domains=()
    for i in "${!records[@]}"; do
      [[ "${records[$i]}" == "$best" ]] || continue
      quorum_rpcs+=("${good_rpcs[${indices[$i]}]}")
      quorum_domains+=("${domains[${indices[$i]}]}")
    done
    tip="$candidate"
    return 0
  done
  return 1
}
select_tip_quorum || die rpc_quorum_conflict 'no unique 2-of-3 RPC header/AppHash quorum exists at a common tip'
(( tip > period )) || die trust_expired 'quorum-attested network tip is below the configured trust window'
trust_height=$((tip - period))

declare -a early_records=() trust_records=()
for rpc in "${quorum_rpcs[@]}"; do
  for checkpoint in "early:$early_height" "trust:$trust_height"; do
    IFS=: read -r label height <<<"$checkpoint"
    file="$tmp/$label-${#early_records[@]}-$height.json"
    curl -fsS --connect-timeout 5 --max-time 15 "${rpc%/}/block?height=$height" >"$file" 2>/dev/null || die rpc_quorum_conflict "cannot read $label checkpoint from $rpc"
    record="$(record_from_block <"$file")" || die rpc_quorum_conflict "malformed $label checkpoint from $rpc"
    case "$label" in early) early_records+=("$record");; trust) trust_records+=("$record");; esac
  done
done
early="$(one_record early "${early_records[@]}")"
trust="$(one_record trust "${trust_records[@]}")"
# Upgrade-plan names are not derived from the Core version. Gonka exposes the
# actual most-recent applied height through its inference query API; the
# Bootstrap-declared runtime API is its only discovery authority.
declare -a applied_heights=()
if [[ -n "$OBSERVATION" ]]; then
  mapfile -t runtime_apis < <(jq -r '.runtime_api_origins[].api_url' "$OBSERVATION" | LC_ALL=C sort -u)
else
  mapfile -t runtime_apis < <(jq -r '[.seeds[].api // empty] | unique[]' "$BOOTSTRAP")
fi
for api in "${runtime_apis[@]}"; do
  applied="$tmp/applied-${#applied_heights[@]}.json"
  curl -fsS --connect-timeout 5 --max-time 15 "$api/chain-api/productscience/inference/inference/last_upgrade_height" >"$applied" 2>/dev/null || continue
  applied_height="$(jq -er 'select(.found == true) | (.lastUpgradeHeight // .last_upgrade_height) | tonumber' "$applied" 2>/dev/null || true)"
  [[ "$applied_height" =~ ^[0-9]+$ ]] && applied_heights+=("$applied_height")
done
if (( ${#applied_heights[@]} > 0 )); then
  post_height="$(one_record post_upgrade_height "${applied_heights[@]}")"; post_height=$((post_height + 1))
else
  post_height="$(jq -r .height <<<"$trust")"
fi
declare -a post_records=() snapshot_providers=()
for rpc in "${quorum_rpcs[@]}"; do
  post_file="$tmp/post-${#post_records[@]}.json"
  curl -fsS --connect-timeout 5 --max-time 15 "${rpc%/}/block?height=$post_height" >"$post_file" 2>/dev/null || die rpc_quorum_conflict "cannot read post-upgrade checkpoint from $rpc"
  post_records+=("$(record_from_block <"$post_file")")
  provider="$(p2p_for_rpc "$rpc")" || die configuration "Bootstrap has no valid P2P provider for quorum RPC $rpc"
  snapshot_providers+=("$provider")
done
post="$(one_record post_upgrade "${post_records[@]}")"
# CometBFT v0.38 has no HTTP /snapshots RPC. Snapshot metadata and chunks are
# discovered through P2P channels and ABCI; actual availability is therefore
# proven by the signerless canary, not by a made-up HTTP endpoint.
snapshot="$(printf '%s\n' "${snapshot_providers[@]}" | jq -R . | jq -s '{discovery:"p2p_canary_pending",providers:.}')"

# DevShard approvals are mutable chain state and do not participate in choosing
# the software profile.  The profile above has already bound the full Core/DAPI
# tuple from one healthy Bootstrap seed.  Before rendering the participant edge
# we still need a current, normalized compatibility set for Versiond.  Keep it
# in this later lineage receipt rather than smuggling a protocol choice into the
# immutable Join Profile.
declare -a approval_sets=() approval_sources=()
for rpc in "${quorum_rpcs[@]}"; do
  case "$rpc" in
    */chain-rpc) chain_api="${rpc%/chain-rpc}/chain-api/productscience/inference/inference/params" ;;
    *) continue ;;
  esac
  params="$tmp/params-${#approval_sets[@]}.json"
  if ! curl -fsS --connect-timeout 5 --max-time 15 "$chain_api" >"$params" 2>/dev/null; then
    continue
  fi
  approval_set="$(jq -cer '
    (.params // .).devshard_escrow_params.approved_versions
    | if type == "array" and length > 0 then . else error("empty approval set") end
    | if all(.[];
        type == "object" and (keys | sort) == ["binary","name","sha256"] and
        (.name | type == "string" and test("^v[1-9][0-9]*$")) and
        (.binary | type == "string" and test("^https://[^[:space:]]+$")) and
        (.sha256 | type == "string" and test("^[0-9a-f]{64}$")))
      then . else error("malformed approval record") end
    | if (map(.name) | unique | length) == length
      then . else error("duplicate approval name") end
    | map({name, url:.binary, sha256}) | sort_by(.name, .url, .sha256)
  ' "$params" 2>/dev/null || true)"
  [[ -n "$approval_set" ]] || continue
  approval_sets+=("$approval_set")
  approval_sources+=("$chain_api")
done
(( ${#approval_sets[@]} >= 2 )) || die devshard_approval_quorum 'fewer than two independent chain APIs exposed a valid DevShard compatibility set'
mapfile -t unique_approval_sets < <(printf '%s\n' "${approval_sets[@]}" | LC_ALL=C sort -u)
(( ${#unique_approval_sets[@]} == 1 )) || die devshard_approval_conflict 'independent chain APIs disagree about DevShard compatibility records'
devshard_approvals="${unique_approval_sets[0]}"
gateway_admission_protocols="$(jq -ce '
  reduce .[] as $record ({};
    . + {($record.name):{binary:$record.url,sha256:$record.sha256}})
' <<<"$devshard_approvals")"

expires_at="$(date -u -d "+${ttl} seconds" +%FT%TZ)"
empty_digest="$(printf '' | sha256sum | awk '{print $1}')"
mkdir -p "$(dirname "$RECEIPT")" "$(dirname "$ENV_FILE")"
receipt_tmp="$(mktemp "$(dirname "$RECEIPT")/.join-lineage-receipt.XXXXXX")"
env_tmp="$(mktemp "$(dirname "$ENV_FILE")/.join-lineage-env.XXXXXX")"
jq -n \
  --arg fingerprint "$GDC_NETWORK_FINGERPRINT" --arg observation_sha256 "$OBSERVATION_SHA256" --arg runtime_source_kind "$RUNTIME_SOURCE_KIND" --arg runtime_source_id "$RUNTIME_SOURCE_ID" \
  --arg core_version "$GDC_NETWORK_CORE_VERSION" --arg core_commit "$GDC_NETWORK_CORE_COMMIT" \
  --arg dapi_version "$GDC_NETWORK_DAPI_VERSION" --arg dapi_commit "$GDC_NETWORK_DAPI_COMMIT" \
  --arg chain "$GDC_NETWORK_CHAIN_ID" --arg genesis "$GDC_NETWORK_GENESIS_SHA256" --arg expires "$expires_at" \
  --argjson early "$early" --argjson post "$post" --argjson trust "$trust" --argjson snapshot "$snapshot" \
  --argjson devshard_approvals "$devshard_approvals" \
  --argjson devshard_sources "$(for source in "${approval_sources[@]}"; do jq -cn --arg url "$source" '{chain_api_url:$url}'; done | jq -s .)" \
  --argjson domains "$(for i in "${!quorum_rpcs[@]}"; do jq -cn --arg id "${quorum_domains[$i]}" --arg rpc "${quorum_rpcs[$i]}" --arg chain "$GDC_NETWORK_CHAIN_ID" --arg genesis "$GDC_NETWORK_GENESIS_SHA256" '{id:$id,rpc_url:$rpc,chain_id:$chain,genesis_sha256:$genesis}'; done | jq -s .)" \
  --arg empty "$empty_digest" \
  '{schema_version:1,kind:"gdc-host-join-lineage-preflight",runtime:{network_fingerprint:$fingerprint,observation_sha256:(if $observation_sha256 == "" then null else $observation_sha256 end),source:{kind:$runtime_source_kind,id:$runtime_source_id},core:{version:$core_version,commit:$core_commit},dapi:{version:$dapi_version,commit:$dapi_commit}},bootstrap:{mode:"state_sync",chain_id:$chain,genesis_sha256:$genesis,trust:($trust+{expires_at:$expires}),snapshot:$snapshot},fault_domains:$domains,checkpoints:{early:$early,post_upgrade:$post,trust:$trust},devshard_compatibility:{approvals:$devshard_approvals,sources:$devshard_sources},staging:{previous_deployment_digest:$empty,rendered_config_digest:$empty,compose_validated:false},signer:{state:"PREPARED",tmkms_monotonic:false},result:{terminal_state:"prepared",category:"none",resume:"safe_exact_resume"}}' >"$receipt_tmp"
{
  printf 'GDC_JOIN_BOOTSTRAP_MODE=%q\n' state_sync
  printf 'GDC_JOIN_TRUST_HEIGHT=%q\n' "$(jq -r .height <<<"$trust")"
  printf 'GDC_JOIN_TRUST_HASH=%q\n' "$(jq -r .block_id <<<"$trust")"
  printf 'GDC_JOIN_SNAPSHOT_PEERS=%q\n' "$(IFS=,; echo "${snapshot_providers[*]}")"
  printf 'GDC_JOIN_RPC_SERVER_1=%q\n' "${quorum_rpcs[0]}/"
  printf 'GDC_JOIN_RPC_SERVER_2=%q\n' "${quorum_rpcs[1]}/"
  printf 'GDC_JOIN_TRUSTED_BLOCK_PERIOD=%q\n' "$period"
  printf 'GDC_JOIN_LINEAGE_RECEIPT=%q\n' "$RECEIPT"
  printf 'GDC_JOIN_GATEWAY_ADMISSION_PROTOCOLS_JSON=%q\n' "$gateway_admission_protocols"
} >"$env_tmp"
chmod 0600 "$receipt_tmp" "$env_tmp"
mv -f "$receipt_tmp" "$RECEIPT"
mv -f "$env_tmp" "$ENV_FILE"
printf 'PASS JOIN lineage preflight mode=state_sync trust_height=%s p2p_snapshot_providers=%s fault_domains=%s receipt=%s\n' "$(jq -r .height <<<"$trust")" "${#snapshot_providers[@]}" "${#quorum_rpcs[@]}" "$RECEIPT"
