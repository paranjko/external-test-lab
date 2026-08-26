#!/usr/bin/env bash
set -Eeuo pipefail

MAX_SAFE_INTEGER=9007199254740991
MAX_VALIDATOR_ITEMS=10000
VALIDATOR_PAGE_SIZE=100
MAX_VALIDATOR_PAGES=100
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMMIT_VERIFIER="$SCRIPT_DIR/verify-cometbft-commit.py"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

is_uint() {
  local value="${1:-}"
  [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  ((${#value} < ${#MAX_SAFE_INTEGER})) && return 0
  ((${#value} == ${#MAX_SAFE_INTEGER})) && ((10#$value <= MAX_SAFE_INTEGER))
}

is_positive_uint() {
  is_uint "${1:-}" && [[ "$1" != 0 ]]
}

require_uint() {
  is_uint "$2" || die "$1 must be a non-negative safe integer"
}

require_positive_uint() {
  is_positive_uint "$2" || die "$1 must be a positive safe integer"
}

require_token() {
  [[ "$2" =~ ^[A-Za-z0-9._:+/=-]+$ ]] || die "$1 is malformed"
}

consensus_address_from_key() (
  set +x
  set -Eeuo pipefail
  local key="$1" work canonical digest
  [[ "$key" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
    || die 'expected validator consensus key is not canonical Ed25519 public-key material'
  work="$(mktemp -d)"
  trap 'rm -rf -- "$work"' EXIT
  printf '%s' "$key" | base64 -d >"$work/key.raw" 2>/dev/null \
    || die 'expected validator consensus key is not canonical Ed25519 public-key material'
  [[ "$(wc -c <"$work/key.raw" | tr -d ' ')" == 32 ]] \
    || die 'expected validator consensus key is not a 32-byte Ed25519 public key'
  canonical="$(base64 <"$work/key.raw" | tr -d '\n')"
  [[ "$canonical" == "$key" ]] \
    || die 'expected validator consensus key is not canonical Ed25519 public-key material'
  digest="$(sha256sum "$work/key.raw" | awk '{print toupper(substr($1,1,40))}')"
  [[ "$digest" =~ ^[0-9A-F]{40}$ ]] \
    || die 'expected validator consensus address could not be derived'
  printf '%s\n' "$digest"
)

read_status() {
  local file="$1" record
  record="$(jq -er --arg max "$MAX_SAFE_INTEGER" '
    def uint_string:
      type == "string"
      and test("^(0|[1-9][0-9]*)$")
      and ((length < ($max | length)) or (length == ($max | length) and . <= $max));
    .result as $result
    | select($result | type == "object")
    | select($result.node_info | type == "object")
    | select($result.sync_info | type == "object")
    | select($result.node_info.network | type == "string" and test("^[A-Za-z0-9._-]+$"))
    | select($result.node_info.id | type == "string" and test("^[A-Za-z0-9._:-]+$"))
    | select($result.sync_info.latest_block_height | uint_string)
    | select($result.sync_info.catching_up | type == "boolean")
    | [$result.node_info.network,$result.node_info.id,
       $result.sync_info.latest_block_height,($result.sync_info.catching_up | tostring)]
    | @tsv
  ' "$file" 2>/dev/null)" || die "recovery status evidence is malformed or unsafe: $file"
  printf '%s\n' "$record"
}

case "${1:-}" in
  lineage)
    [[ $# == 5 ]] \
      || die 'usage: evaluate-running-host-recovery.sh lineage EXPECTED_CHAIN EXPECTED_GENESIS LIVE_CHAIN LIVE_GENESIS'
    expected_chain="$2"
    expected_genesis="$3"
    live_chain="$4"
    live_genesis="$5"
    [[ "$expected_chain" =~ ^[A-Za-z0-9._-]+$ && "$live_chain" =~ ^[A-Za-z0-9._-]+$ \
      && "$expected_genesis" =~ ^[0-9a-f]{64}$ && "$live_genesis" =~ ^[0-9a-f]{64}$ ]] \
      || die 'recovery Genesis lineage evidence is malformed'
    [[ "$live_chain" == "$expected_chain" ]] \
      || die 'live canonical Genesis belongs to another chain'
    [[ "$live_genesis" == "$expected_genesis" ]] \
      || die 'live canonical Genesis belongs to a different Genesis lineage'
    jq -n --arg chain_id "$live_chain" --arg genesis_sha256 "$live_genesis" \
      '{matched:true,chain_id:$chain_id,genesis_sha256:$genesis_sha256}'
    ;;
  status)
    [[ $# == 10 ]] || die 'usage: evaluate-running-host-recovery.sh status CHAIN_ID NODE_ID MAX_LAG PREVIOUS_CHAIN PREVIOUS_PUBLIC PREVIOUS_LOCAL CHAIN_STATUS PUBLIC_STATUS LOCAL_STATUS'
    expected_chain="$2"
    expected_node_id="$3"
    max_lag="$4"
    previous_chain="$5"
    previous_public="$6"
    previous_local="$7"
    chain_file="$8"
    public_file="$9"
    local_file="${10}"
    [[ "$expected_chain" =~ ^[A-Za-z0-9._-]+$ ]] || die 'expected recovery chain ID is malformed'
    [[ "$expected_node_id" =~ ^[A-Za-z0-9._:-]+$ ]] || die 'expected recovery node ID is malformed'
    require_uint 'maximum recovery lag' "$max_lag"
    require_uint 'previous canonical height' "$previous_chain"
    require_uint 'previous public height' "$previous_public"
    require_uint 'previous local height' "$previous_local"

    chain_record="$(read_status "$chain_file")"
    public_record="$(read_status "$public_file")"
    local_record="$(read_status "$local_file")"
    IFS=$'\t' read -r chain_network chain_node_id chain_height chain_catching <<<"$chain_record"
    IFS=$'\t' read -r public_network public_node_id public_height public_catching <<<"$public_record"
    IFS=$'\t' read -r local_network local_node_id local_height local_catching <<<"$local_record"
    [[ -n "$chain_node_id" ]] || die 'canonical recovery status has no P2P identity'
    [[ "$chain_network" == "$expected_chain" && "$public_network" == "$expected_chain" \
      && "$local_network" == "$expected_chain" ]] \
      || die 'canonical, public, or local Host status belongs to another chain'
    [[ "$public_node_id" == "$expected_node_id" ]] \
      || die 'public Host endpoint routes to another P2P identity'
    [[ "$local_node_id" == "$expected_node_id" ]] \
      || die 'local Host runtime uses another P2P identity'

    public_ahead=false
    local_ahead=false
    public_lag=0
    local_lag=0
    if ((public_height > chain_height)); then
      public_ahead=true
      public_lag=$((public_height - chain_height))
    else
      public_lag=$((chain_height - public_height))
    fi
    if ((local_height > chain_height)); then
      local_ahead=true
      local_lag=$((local_height - chain_height))
    else
      local_lag=$((chain_height - local_height))
    fi
    ready=false
    if [[ "$chain_catching" == false && "$public_catching" == false && "$local_catching" == false ]] \
      && ((chain_height > previous_chain && public_height > previous_public && local_height > previous_local \
        && public_lag <= max_lag && local_lag <= max_lag)); then
      ready=true
    fi
    jq -n \
      --argjson ready "$ready" \
      --argjson chain_height "$chain_height" \
      --argjson public_height "$public_height" \
      --argjson local_height "$local_height" \
      --argjson public_lag "$public_lag" \
      --argjson local_lag "$local_lag" \
      --argjson public_ahead "$public_ahead" \
      --argjson local_ahead "$local_ahead" \
      --argjson chain_catching_up "$chain_catching" \
      --argjson public_catching_up "$public_catching" \
      --argjson local_catching_up "$local_catching" \
      '{ready:$ready,chain_height:$chain_height,public_height:$public_height,
        local_height:$local_height,public_lag:$public_lag,local_lag:$local_lag,
        public_ahead_of_canonical:$public_ahead,local_ahead_of_canonical:$local_ahead,
        chain_catching_up:$chain_catching_up,public_catching_up:$public_catching_up,
        local_catching_up:$local_catching_up}'
    ;;
  block)
    [[ $# == 6 ]] || die 'usage: evaluate-running-host-recovery.sh block CHAIN_ID HEIGHT CHAIN_BLOCK PUBLIC_BLOCK LOCAL_BLOCK'
    expected_chain="$2"
    expected_height="$3"
    [[ "$expected_chain" =~ ^[A-Za-z0-9._-]+$ ]] || die 'common recovery block chain ID is malformed'
    require_positive_uint 'common recovery block height' "$expected_height"
    shift 3
    reference=''
    for file in "$@"; do
      value="$(jq -er --arg chain "$expected_chain" --arg height "$expected_height" '
        [.result.block.header.chain_id,.result.block.header.height,
         .result.block_id.hash,.result.block.header.app_hash]
        | select(
            (.[0] | type == "string" and . == $chain)
            and (.[1] | type == "string" and . == $height)
            and (.[2] | type == "string" and test("^[0-9A-Fa-f]{64}$"))
            and (.[3] | type == "string" and test("^[0-9A-Fa-f]{64}$")))
        | @tsv
      ' "$file" 2>/dev/null)" \
        || die "recovery block evidence is malformed, stale, or from another chain: $file"
      if [[ -z "$reference" ]]; then
        reference="$value"
      elif [[ "$value" != "$reference" ]]; then
        die 'canonical, public, and local Host block or app state disagree at the common height'
      fi
    done
    jq -n --argjson height "$expected_height" --arg block_hash "$(cut -f3 <<<"$reference")" \
      --arg app_hash "$(cut -f4 <<<"$reference")" \
      '{matched:true,height:$height,block_hash:$block_hash,app_hash:$app_hash}'
    ;;
  commit-canonicality)
    [[ $# == 2 ]] \
      || die 'usage: evaluate-running-host-recovery.sh commit-canonicality COMMIT_EVIDENCE'
    jq -er '
      .result
      | select(type == "object")
      | .canonical
      | if type == "boolean" then tostring else error("invalid canonicality") end
    ' "$2" 2>/dev/null \
      || die 'consensus commit canonicality metadata is malformed'
    ;;
  participant)
    [[ $# == 5 ]] \
      || die 'usage: evaluate-running-host-recovery.sh participant OPERATOR_ADDRESS CONSENSUS_KEY INFERENCE_URL PARTICIPANT_EVIDENCE'
    expected_operator="$2"
    expected_key="$3"
    expected_url="${4%/}"
    participant_file="$5"
    [[ "$expected_operator" =~ ^[a-z0-9]{3,128}$ ]] || die 'expected validator operator address is malformed'
    require_token 'expected validator consensus key' "$expected_key"
    [[ "$expected_url" =~ ^https://[A-Za-z0-9._:-]+$ ]] || die 'expected participant inference URL is malformed'
    jq -e \
      --arg operator "$expected_operator" \
      --arg key "$expected_key" \
      --arg url "$expected_url" '
      .participant as $participant
      | if ($participant | type) != "object"
          or ($participant.address | type) != "string"
          or ($participant.validator_key | type) != "string"
          or ($participant.inference_url | type) != "string"
          or (($participant.status | type) != "string" and ($participant.status | type) != "number")
        then error("malformed participant") else . end
      | if ($participant.status | type) == "number"
          and (($participant.status | floor) != $participant.status or $participant.status < 0
               or $participant.status > 9007199254740991)
        then error("unsafe participant status") else . end
      | if $participant.address != $operator
          or $participant.validator_key != $key
          or ($participant.inference_url | rtrimstr("/")) != $url
        then error("wrong participant binding") else . end
      | if ($participant.status == "ACTIVE" or $participant.status == "PARTICIPANT_STATUS_ACTIVE"
            or $participant.status == "1" or $participant.status == 1) | not
        then error("participant is not active") else . end
      | {matched:true,active:true,operator_address:$operator,consensus_key:$key,
         inference_url:$url}
    ' "$participant_file" 2>/dev/null \
      || die 'participant evidence is malformed, inactive, or bound to another validator'
    ;;
  validator-pages)
    [[ $# == 3 ]] \
      || die 'usage: evaluate-running-host-recovery.sh validator-pages HEIGHT FIRST_VALIDATOR_PAGE'
    expected_height="$2"
    first_page="$3"
    require_positive_uint 'validator-set height' "$expected_height"
    jq -e \
      --arg height "$expected_height" \
      --arg max_safe "$MAX_SAFE_INTEGER" \
      --argjson max_items "$MAX_VALIDATOR_ITEMS" \
      --argjson max_pages "$MAX_VALIDATOR_PAGES" \
      --argjson page_size "$VALIDATOR_PAGE_SIZE" '
      def uint_string:
        type == "string"
        and test("^(0|[1-9][0-9]*)$")
        and ((length < ($max_safe | length)) or (length == ($max_safe | length) and . <= $max_safe));
      .result as $result
      | if ($result | type) != "object"
          or ($result.block_height | type) != "string" or $result.block_height != $height
          or ($result.total | uint_string | not)
          or ($result.count | uint_string | not)
          or ($result.validators | type) != "array"
        then error("malformed first validator page") else . end
      | ($result.total | tonumber) as $total
      | ($result.count | tonumber) as $count
      | (($total + $page_size - 1) / $page_size | floor) as $pages
      | if $total <= 0 or $total > $max_items or $pages <= 0 or $pages > $max_pages
          or $count != ($result.validators | length)
          or $count != (if $total < $page_size then $total else $page_size end)
        then error("unsafe or inconsistent first validator page") else . end
      | {total:$total,page_size:$page_size,pages:$pages,max_items:$max_items,max_pages:$max_pages}
    ' "$first_page" 2>/dev/null \
      || die 'first validator page is malformed, stale, unsafe, or inconsistent'
    ;;
  validators)
    [[ $# -ge 6 ]] \
      || die 'usage: evaluate-running-host-recovery.sh validators HEIGHT OPERATOR_ADDRESS CONSENSUS_KEY PARTICIPANT_EVALUATION VALIDATOR_PAGE...'
    expected_height="$2"
    expected_operator="$3"
    expected_key="$4"
    participant_evaluation="$5"
    require_positive_uint 'validator-set height' "$expected_height"
    [[ "$expected_operator" =~ ^[a-z0-9]{3,128}$ ]] || die 'expected validator operator address is malformed'
    expected_consensus_address="$(consensus_address_from_key "$expected_key")"
    jq -e --arg operator "$expected_operator" --arg key "$expected_key" '
      type == "object" and .matched == true and .active == true
      and .operator_address == $operator and .consensus_key == $key
    ' "$participant_evaluation" >/dev/null 2>&1 \
      || die 'validator-set evidence is not bound to the intended active operator'
    shift 5
    (($# <= MAX_VALIDATOR_PAGES)) \
      || die "validator-set pagination exceeds the deterministic $MAX_VALIDATOR_PAGES-page limit"
    jq -es \
      --arg height "$expected_height" \
      --arg operator "$expected_operator" \
      --arg key "$expected_key" \
      --arg expected_address "$expected_consensus_address" \
      --arg max_safe "$MAX_SAFE_INTEGER" \
      --argjson max_items "$MAX_VALIDATOR_ITEMS" \
      --argjson max_pages "$MAX_VALIDATOR_PAGES" \
      --argjson page_size "$VALIDATOR_PAGE_SIZE" '
      def uint_string:
        type == "string"
        and test("^(0|[1-9][0-9]*)$")
        and ((length < ($max_safe | length)) or (length == ($max_safe | length) and . <= $max_safe));
      def consensus_address: type == "string" and test("^[0-9A-F]{40}$");
      def consensus_key: type == "string" and length > 0 and length <= 256
        and test("^[A-Za-z0-9+/=_-]+$");
      if length == 0 or length > $max_pages or any(.[]; . == null)
      then error("invalid page count") else . end
      | if any(.[];
          (.result | type) != "object"
          or (.result.block_height | type) != "string" or .result.block_height != $height
          or (.result.total | uint_string | not)
          or (.result.count | uint_string | not)
          or (.result.validators | type) != "array"
          or ((.result.count | tonumber) != (.result.validators | length)))
        then error("malformed validator page") else . end
      | ([.[].result.total] | unique) as $totals
      | if ($totals | length) != 1 then error("inconsistent totals") else . end
      | ($totals[0] | tonumber) as $total
      | if $total <= 0 or $total > $max_items then error("unsafe validator total") else . end
      | (($total + $page_size - 1) / $page_size | floor) as $expected_pages
      | if length != $expected_pages then error("incomplete pages") else . end
      | if any(to_entries[];
          (.value.result.count | tonumber)
          != (if .key + 1 < $expected_pages then $page_size else $total - (.key * $page_size) end))
        then error("inconsistent page shape") else . end
      | [.[].result.validators[]] as $validators
      | if ($validators | length) != $total
          or any($validators[];
            (.address | consensus_address | not)
            or (.pub_key | type) != "object"
            or (.pub_key.type | type) != "string"
            or (.pub_key.type != "tendermint/PubKeyEd25519"
                and .pub_key.type != "cometbft/PubKeyEd25519")
            or (.pub_key.value | consensus_key | not)
            or (.voting_power | uint_string | not)
            or ((.voting_power | tonumber) <= 0))
        then error("malformed validators") else . end
      | [$validators[].address] as $addresses
      | [$validators[].pub_key.value] as $keys
      | [$validators[] | select(.pub_key.value == $key)] as $key_matches
      | [$key_matches[] | select(.address == $expected_address)] as $matches
      | if ($addresses | unique | length) != $total
          or ($keys | unique | length) != $total
          or ($key_matches | length) > 1
          or (($key_matches | length) == 1 and ($matches | length) != 1)
        then error("duplicate validator identity") else . end
      | {height:($height | tonumber),total:$total,returned:($validators | length),operator_address:$operator,
         consensus_key:$key,match_count:($matches | length),
         voting_power:(if ($matches | length) == 1 then ($matches[0].voting_power | tonumber) else 0 end),
         consensus_address:(if ($matches | length) == 1 then $matches[0].address else null end)}
    ' "$@" 2>/dev/null \
      || die 'consensus validator set pages are malformed, unsafe, duplicated, or incomplete'
    ;;
  decision-height)
    [[ $# == 3 ]] \
      || die 'usage: evaluate-running-host-recovery.sh decision-height STATUS VALIDATOR_EVALUATION'
    status_file="$2"
    validator_evaluation="$3"
    jq -e --argjson max_safe "$MAX_SAFE_INTEGER" -n \
      --slurpfile status "$status_file" --slurpfile validators "$validator_evaluation" '
      ($status | select(length == 1) | .[0]) as $status
      | ($validators | select(length == 1) | .[0]) as $validators
      | select($status | type == "object" and .ready == true)
      | select($status.chain_height | type == "number" and floor == . and . > 0 and . <= $max_safe)
      | select($validators | type == "object")
      | select($validators.height | type == "number" and floor == . and . > 0 and . <= $max_safe)
      | select($validators.voting_power | type == "number" and floor == . and . >= 0 and . <= $max_safe)
      | select($validators.height == $status.chain_height)
      | {matched:true,height:$status.chain_height,voting_power:$validators.voting_power}
    ' 2>/dev/null \
      || die 'validator-set evidence is not bound to the final synchronized decision height'
    ;;
  signature)
    [[ $# == 7 ]] \
      || die 'usage: evaluate-running-host-recovery.sh signature CHAIN_ID HEIGHT OPERATOR_ADDRESS CONSENSUS_KEY VALIDATOR_EVALUATION COMMIT_EVIDENCE'
    expected_chain="$2"
    expected_height="$3"
    expected_operator="$4"
    expected_key="$5"
    validator_evaluation="$6"
    commit_file="$7"
    [[ "$expected_chain" =~ ^[A-Za-z0-9._-]+$ ]] || die 'consensus commit chain ID is malformed'
    require_positive_uint 'consensus commit height' "$expected_height"
    [[ "$expected_operator" =~ ^[a-z0-9]{3,128}$ ]] || die 'expected validator operator address is malformed'
    expected_consensus_address="$(consensus_address_from_key "$expected_key")"
    commit_sha256="$(sha256sum "$commit_file" 2>/dev/null | awk '{print $1}')" \
      || die 'canonical commit evidence cannot be hashed'
    [[ "$commit_sha256" =~ ^[0-9a-f]{64}$ ]] \
      || die 'canonical commit evidence cannot be hashed'
    validator_record="$(jq -er \
      --arg operator "$expected_operator" \
      --arg key "$expected_key" \
      --arg expected_address "$expected_consensus_address" \
      --argjson max_safe "$MAX_SAFE_INTEGER" '
      select(type == "object")
      | select(.operator_address == $operator and .consensus_key == $key)
      | select(.match_count | type == "number" and floor == . and (. == 0 or . == 1))
      | select(.voting_power | type == "number" and floor == . and . >= 0 and . <= $max_safe)
      | select((.match_count == 0 and .voting_power == 0 and .consensus_address == null)
          or (.match_count == 1 and .voting_power > 0
              and (.consensus_address | type == "string" and . == $expected_address)))
      | [(.consensus_address // "-"),(.voting_power | tostring)] | @tsv
    ' "$validator_evaluation" 2>/dev/null)" \
      || die 'consensus commit evidence is not bound to the intended validator-set decision'
    IFS=$'\t' read -r consensus_address voting_power <<<"$validator_record"
    [[ "$consensus_address" != - ]] || consensus_address=''
    signature_required=false
    ((voting_power > 0)) && signature_required=true
    command -v python3 >/dev/null 2>&1 \
      || die 'python3 is required to verify canonical consensus commit evidence'
    command -v openssl >/dev/null 2>&1 \
      || die 'OpenSSL is required to verify canonical consensus commit evidence'
    [[ -f "$COMMIT_VERIFIER" && ! -L "$COMMIT_VERIFIER" && -r "$COMMIT_VERIFIER" ]] \
      || die 'canonical consensus commit verifier is unavailable'
    verifier_address='-'
    [[ "$signature_required" == false ]] || verifier_address="$consensus_address"
    verification="$(
      python3 "$COMMIT_VERIFIER" "$commit_file" "$expected_chain" "$expected_height" \
        "$expected_key" "$verifier_address" 2>/dev/null
    )" || die 'consensus commit evidence is malformed, non-canonical, stale, duplicated, or invalid; cryptographic signature and header binding are required'
    jq -en \
      --arg operator "$expected_operator" \
      --arg key "$expected_key" \
      --arg address "$consensus_address" \
      --arg commit_sha256 "$commit_sha256" \
      --argjson height "$expected_height" \
      --argjson voting_power "$voting_power" \
      --argjson signature_required "$signature_required" \
      --argjson verification "$verification" '
      $verification
      | select(type == "object")
      | select(.signed | type == "boolean")
      | select(.header_hash | type == "string" and test("^[0-9A-F]{64}$"))
      | select(.commit_round | type == "number" and floor == . and . >= 0)
      | {canonical:true,commit_height:$height,operator_address:$operator,
         consensus_key:$key,consensus_address:(if $address == "" then null else $address end),
         voting_power:$voting_power,signature_required:$signature_required,
         signed:(if $signature_required then .signed else false end),
         canonical_header_hash:.header_hash,commit_round:.commit_round,
         verified_signature_timestamp:.verified_signature_timestamp,
         canonical_commit_sha256:$commit_sha256}
    ' || die 'canonical consensus commit verification returned malformed output'
    ;;
  freshness)
    [[ $# == 9 ]] \
      || die 'usage: evaluate-running-host-recovery.sh freshness MAX_AGE_SECONDS BOUNDARY_MARKER STATUS PARTICIPANT VALIDATOR_SET COMMIT RUNTIME SYNCHRONIZATION'
    max_age="$2"
    boundary_file="$3"
    require_positive_uint 'maximum snapshot age' "$max_age"
    ((max_age <= 3600)) || die 'maximum snapshot age exceeds the one-hour safety bound'
    now="$(date +%s)"
    require_uint 'current timestamp' "$now"
    [[ -f "$boundary_file" && ! -L "$boundary_file" && -r "$boundary_file" ]] \
      || die 'decision boundary marker is missing, unreadable, or not a regular file'
    boundary_mtime="$(stat -c %Y -- "$boundary_file" 2>/dev/null)" \
      || die 'decision boundary marker timestamp is unavailable'
    require_uint 'decision boundary marker timestamp' "$boundary_mtime"
    ((boundary_mtime <= now && now - boundary_mtime <= max_age)) \
      || die 'decision boundary marker is stale or from the future'
    boundary_hash="$(sha256sum -- "$boundary_file" | cut -d' ' -f1)"
    [[ "$boundary_hash" =~ ^[0-9a-f]{64}$ ]] || die 'decision boundary marker cannot be hashed'
    labels=(status participant validator_set commit runtime synchronization)
    files=("$4" "$5" "$6" "$7" "$8" "$9")
    hashes=()
    mtimes=()
    for index in "${!files[@]}"; do
      file="${files[$index]}"
      [[ -f "$file" && ! -L "$file" && -r "$file" && -s "$file" ]] \
        || die "${labels[$index]} decision snapshot is missing, empty, unreadable, or not a regular file"
      mtime="$(stat -c %Y -- "$file" 2>/dev/null)" \
        || die "${labels[$index]} decision snapshot timestamp is unavailable"
      require_uint "${labels[$index]} decision snapshot timestamp" "$mtime"
      [[ "$file" -nt "$boundary_file" ]] \
        || die "${labels[$index]} decision snapshot does not postdate the decision boundary"
      ((mtime <= now && now - mtime <= max_age)) \
        || die "${labels[$index]} decision snapshot is stale or from the future"
      hash="$(sha256sum -- "$file" | cut -d' ' -f1)"
      [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || die "${labels[$index]} decision snapshot cannot be hashed"
      hashes+=("$hash")
      mtimes+=("$mtime")
    done
    jq -n \
      --argjson evaluated_at "$now" \
      --argjson not_before "$boundary_mtime" \
      --argjson max_age "$max_age" \
      --arg boundary_hash "$boundary_hash" \
      --arg status_hash "${hashes[0]}" --argjson status_mtime "${mtimes[0]}" \
      --arg participant_hash "${hashes[1]}" --argjson participant_mtime "${mtimes[1]}" \
      --arg validator_hash "${hashes[2]}" --argjson validator_mtime "${mtimes[2]}" \
      --arg commit_hash "${hashes[3]}" --argjson commit_mtime "${mtimes[3]}" \
      --arg runtime_hash "${hashes[4]}" --argjson runtime_mtime "${mtimes[4]}" \
      --arg synchronization_hash "${hashes[5]}" --argjson synchronization_mtime "${mtimes[5]}" '
      {matched:true,evaluated_at_unix:$evaluated_at,not_before_unix:$not_before,
       max_age_seconds:$max_age,boundary_sha256:$boundary_hash,snapshots:{
         status:{sha256:$status_hash,mtime_unix:$status_mtime},
         participant:{sha256:$participant_hash,mtime_unix:$participant_mtime},
         validator_set:{sha256:$validator_hash,mtime_unix:$validator_mtime},
         commit:{sha256:$commit_hash,mtime_unix:$commit_mtime},
         runtime:{sha256:$runtime_hash,mtime_unix:$runtime_mtime},
         synchronization:{sha256:$synchronization_hash,mtime_unix:$synchronization_mtime}}}
    '
    ;;
  topology)
    [[ $# == 9 ]] \
      || die 'usage: evaluate-running-host-recovery.sh topology NODE RUNTIME_ID ML_ALIAS ML_ENDPOINT ARCHIVE_HAS_ML_HOST ARCHIVE_ML_HOST LINK CONFIG'
    node="$2"
    runtime_id="$3"
    ml_alias="$4"
    ml_endpoint="$5"
    archive_has_ml_host="$6"
    archive_ml_host="$7"
    link_file="$8"
    config_file="$9"
    [[ "$node" =~ ^[A-Za-z0-9._-]+$ ]] || die 'validator node alias is malformed'
    require_token 'expected runtime identity' "$runtime_id"
    [[ "$archive_has_ml_host" == true || "$archive_has_ml_host" == false ]] \
      || die 'validator backup split-GPU presence must be true or false'
    [[ -z "$ml_alias" || "$ml_alias" =~ ^[A-Za-z0-9._-]+$ ]] || die 'split-GPU SSH alias is malformed'
    [[ -z "$archive_ml_host" || "$archive_ml_host" =~ ^[A-Za-z0-9._-]+$ ]] \
      || die 'validator backup split-GPU alias is malformed'
    [[ -z "$ml_endpoint" || "$ml_endpoint" =~ ^[A-Za-z0-9._:-]+$ ]] \
      || die 'split-GPU endpoint is malformed'
    jq -e --arg runtime_id "$runtime_id" '
      type == "array" and (.[0] | type) == "object"
      and ((.[0].id | type) == "string" and length == 1 and .[0].id == $runtime_id)
      and (.[0].host | type) == "string" and (.[0].host | length) > 0
    ' "$config_file" >/dev/null 2>&1 \
      || die 'deployed node configuration has another or malformed runtime identity'

    binding=manifest
    [[ "$archive_has_ml_host" == true ]] || binding=live-running-host
    if [[ -n "$ml_alias" ]]; then
      [[ -n "$ml_endpoint" ]] || die 'configured split-GPU SSH alias has no endpoint'
      if [[ "$archive_has_ml_host" == true && "$archive_ml_host" != "$ml_alias" ]]; then
        die 'validator backup split-GPU binding disagrees with the requested topology'
      fi
      jq -e --arg node "$node" --arg alias "$ml_alias" --arg endpoint "$ml_endpoint" '
        type == "object" and (.schema_version | type) == "number" and .schema_version == 1
        and (.validator_alias | type) == "string" and .validator_alias == $node
        and (.ml_ssh_alias | type) == "string" and .ml_ssh_alias == $alias
        and (.ml_endpoint | type) == "string" and .ml_endpoint == $endpoint
      ' "$link_file" >/dev/null 2>&1 \
        || die 'running split-GPU binding disagrees with the requested topology'
      jq -e --arg endpoint "$ml_endpoint" '.[0].host == $endpoint' "$config_file" >/dev/null 2>&1 \
        || die 'deployed ML endpoint disagrees with the requested split-GPU topology'
    else
      [[ "$archive_has_ml_host" == false || -z "$archive_ml_host" ]] \
        || die 'validator backup requires split-GPU topology but no split-GPU Host was requested'
      if [[ -s "$link_file" ]] && grep -q '[^[:space:]]' "$link_file"; then
        die 'running Host has an unexpected split-GPU binding'
      fi
      jq -e '.[0].host == "inference"' "$config_file" >/dev/null 2>&1 \
        || die 'deployed ML endpoint is external but no split-GPU Host was requested'
    fi
    jq -n --arg binding "$binding" --arg endpoint "$ml_endpoint" --arg runtime_id "$runtime_id" \
      '{matched:true,runtime_id:$runtime_id,backup_topology_binding:$binding,
        ml_endpoint:(if $endpoint == "" then null else $endpoint end)}'
    ;;
  *)
    die 'usage: evaluate-running-host-recovery.sh lineage ... | status ... | block ... | participant ... | validator-pages ... | validators ... | decision-height ... | signature ... | freshness ... | topology ...'
    ;;
esac
