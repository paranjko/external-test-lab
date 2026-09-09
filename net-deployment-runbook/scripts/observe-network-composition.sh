#!/usr/bin/env bash
set -Eeuo pipefail

usage() { echo "Usage: $0 --bootstrap-file FILE --output FILE" >&2; }
die() { printf 'software_%s: %s\n' "$1" "$2" >&2; exit 1; }

BOOTSTRAP=''
OUTPUT=''
while (($#)); do
  case "$1" in
    --bootstrap-file) BOOTSTRAP="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ -r "$BOOTSTRAP" && -n "$OUTPUT" ]] || { usage; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/network-bootstrap.sh" verify "$BOOTSTRAP" >/dev/null
command -v curl >/dev/null || die unsupported 'curl is required to observe seed endpoints'
command -v jq >/dev/null || die unsupported 'jq is required to validate seed observations'

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
chain_id="$(jq -r .chain_id "$BOOTSTRAP")"
genesis_sha256="$(jq -r .genesis.sha256 "$BOOTSTRAP")"
declare -a rpc_observations=() api_observations=()

fetch_json() {
  local url="$1" output="$2"
  curl -fsS --connect-timeout 5 --max-time 15 "$url" >"$output" 2>/dev/null
}

seed_count="$(jq '.seeds | length' "$BOOTSTRAP")"
for (( index=0; index<seed_count; index++ )); do
  node_id="$(jq -r ".seeds[$index].node_id" "$BOOTSTRAP")"
  rpc="$(jq -r ".seeds[$index].rpc" "$BOOTSTRAP")"
  explicit_api="$(jq -r ".seeds[$index].api // empty" "$BOOTSTRAP")"
  status="$tmp/status-$index.json"
  abci="$tmp/abci-$index.json"
  if ! fetch_json "${rpc%/}/status" "$status" || ! fetch_json "${rpc%/}/abci_info" "$abci"; then
    continue
  fi
  jq -e --arg id "$node_id" --arg chain "$chain_id" '
    .result.node_info.id == $id and .result.node_info.network == $chain and
    (.result.node_info.version | type == "string" and length > 0)
  ' "$status" >/dev/null || die ambiguous "seed $rpc does not attest its Bootstrap identity and chain"
  jq -e '.result.response.version | type == "string" and length > 0' "$abci" >/dev/null \
    || die incomplete "seed $rpc does not expose an ABCI application version"
  # /status identifies the CometBFT transport runtime.  The application
  # version which must agree with DAPI is exposed by /abci_info instead.
  cometbft_version="$(jq -r '.result.node_info.version | ltrimstr("v")' "$status")"
  abci_version="$(jq -r '.result.response.version | ltrimstr("v")' "$abci")"
  rpc_observations+=("$cometbft_version|$abci_version")
  # Bootstrap v1 names runtime APIs explicitly.  A chain RPC endpoint is not
  # an implicit DAPI authority: operators may expose node-local APIs there
  # while Bootstrap deliberately designates one different discovery endpoint.
  [[ -n "$explicit_api" ]] || continue
  api="$explicit_api"
  versions="$tmp/versions-$index.json"
  fetch_json "${api%/}/v1/versions" "$versions" \
    || die declared_api_unavailable "declared runtime API $api is unavailable"
  jq -e '
    (.node_version.version | type == "string" and length > 0) and
    (.node_version.commit | type == "string" and test("^[0-9a-f]{40}$")) and
    (.api_version.version | type == "string" and length > 0) and
    (.api_version.commit | type == "string" and test("^[0-9a-f]{40}$"))
  ' "$versions" >/dev/null || die incomplete "seed API $api does not expose complete node and DAPI versions"
  node_version="$(jq -r '.node_version.version | ltrimstr("v")' "$versions")"
  node_commit="$(jq -r '.node_version.commit' "$versions")"
  api_version="$(jq -r '.api_version.version | ltrimstr("v")' "$versions")"
  api_commit="$(jq -r '.api_version.commit' "$versions")"
  [[ "$node_version" == "$abci_version" ]] || die upgrade_required "seed API $api reports a core version that disagrees with its RPC application endpoint"
  api_observations+=("$node_version|$node_commit|$api_version|$api_commit")
done

(( ${#rpc_observations[@]} >= 2 )) || die incomplete "fewer than two independent seed RPC observations were complete (complete=${#rpc_observations[@]})"
mapfile -t unique_rpc_observations < <(printf '%s\n' "${rpc_observations[@]}" | LC_ALL=C sort -u)
(( ${#unique_rpc_observations[@]} == 1 )) || die ambiguous 'independent seed RPC observations disagree; refusing a majority or endpoint-order choice'
IFS='|' read -r cometbft_version abci_version <<<"${unique_rpc_observations[0]}"
(( ${#api_observations[@]} >= 1 )) || die incomplete 'no Bootstrap seed API exposed complete public node and DAPI versions'
mapfile -t unique_api_observations < <(printf '%s\n' "${api_observations[@]}" | LC_ALL=C sort -u)
(( ${#unique_api_observations[@]} == 1 )) || die ambiguous 'available seed APIs disagree about node or DAPI versions'
IFS='|' read -r api_node_version node_commit api_version api_commit <<<"${unique_api_observations[0]}"
[[ "$api_node_version" == "$abci_version" ]] || die upgrade_required 'seed API version disagrees with independently observed seed RPC application version'

# Governance state is chain state, not DAPI state: query the public chain-api
# that each seed exposes alongside its RPC route. A DAPI root can legitimately
# serve the dashboard and must not be mistaken for the Cosmos REST service.
#
# approved_versions is a compatibility allowlist consumed by Versiond. It does
# not identify one active DevShard runtime and therefore must never select a
# Host composition. Retain the complete normalized records as evidence.
declare -a approval_sets=()
for (( index=0; index<seed_count; index++ )); do
  rpc="$(jq -r ".seeds[$index].rpc" "$BOOTSTRAP")"
  case "$rpc" in
    */chain-rpc) chain_api="${rpc%/chain-rpc}/chain-api/productscience/inference/inference/params" ;;
    *) continue ;;
  esac
  params="$tmp/params-$index.json"
  if fetch_json "$chain_api" "$params"; then
    approval_set="$(jq -cer '
      (.params // .).devshard_escrow_params.approved_versions
      | if type != "array" then error("approved_versions is not an array") else . end
      | if all(.[];
          type == "object" and
          (.name | type == "string" and test("^v[1-9][0-9]*$")) and
          (.binary | type == "string" and test("^https://[^[:space:]]+$")) and
          (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
        ) then . else error("malformed approved version") end
      | if (map(.name) | unique | length) == length
        then . else error("duplicate approved version name") end
      | map({name: .name, url: .binary, sha256: .sha256})
      | sort_by(.name, .url, .sha256)
    ' "$params" 2>/dev/null)" \
      || die incomplete "seed chain API $chain_api returned malformed governed DevShard state"
    approval_sets+=("$approval_set")
  fi
done
(( ${#approval_sets[@]} >= 2 )) || die incomplete 'fewer than two seed chain APIs exposed governed DevShard approval state'
mapfile -t unique_approval_sets < <(printf '%s\n' "${approval_sets[@]}" | LC_ALL=C sort -u)
(( ${#unique_approval_sets[@]} == 1 )) || die ambiguous 'seed chain APIs disagree about governed DevShard approval records'
devshard_approvals="${unique_approval_sets[0]}"

profile=''
for lock in "$ROOT"/profiles/releases/*.lock; do
  [[ -r "$lock" ]] || continue
  [[ "$(awk -F= '$1 == "LAB_CANDIDATE" {print $2; exit}' "$lock")" != true ]] || continue
  lock_version="$(awk -F= '$1 == "GONKA_RELEASE" {print $2; exit}' "$lock")"
  lock_commit="$(awk -F= '$1 == "GONKA_COMMIT" {print $2; exit}' "$lock")"
  lock_dapi_ref="$(awk -F= '$1 == "DAPI_SOURCE_REF" {print $2; exit}' "$lock")"
  lock_dapi_commit="$(awk -F= '$1 == "DAPI_COMMIT" {print $2; exit}' "$lock")"
  lock_chain_id="$(awk -F= '$1 == "JOIN_NETWORK_CHAIN_ID" {print $2; exit}' "$lock")"
  lock_genesis_sha256="$(awk -F= '$1 == "JOIN_NETWORK_GENESIS_SHA256" {print $2; exit}' "$lock")"
  lock_dapi_version="${lock_dapi_ref#release/v}"
  if [[ "$lock_version" == "$node_version" && "$lock_commit" == "$node_commit" &&
    "$lock_dapi_version" == "$api_version" && "$lock_dapi_commit" == "$api_commit" &&
    "$lock_chain_id" == "$chain_id" && "$lock_genesis_sha256" == "$genesis_sha256" ]]; then
    candidate="${lock##*/}"; candidate="${candidate%.lock}"
  [[ -z "$profile" ]] || die ambiguous "multiple local profiles match observed chain/Genesis/core/DAPI runtime"
    profile="$candidate"
  fi
done
[[ -n "$profile" ]] || die unsupported "no immutable local profile matches observed core/DAPI runtime $node_version@$node_commit $api_version@$api_commit"

fingerprint="$(printf 'chain_id=%s\ngenesis_sha256=%s\ncometbft_version=%s\nnode_version=%s\nnode_commit=%s\ndapi_version=%s\ndapi_commit=%s\nabci_version=%s\ndevshard_approvals=%s\n' "$chain_id" "$genesis_sha256" "$cometbft_version" "$node_version" "$node_commit" "$api_version" "$api_commit" "$abci_version" "$devshard_approvals" | sha256sum | awk '{print $1}')"
mkdir -p "$(dirname "$OUTPUT")"
{
  printf 'GDC_NETWORK_FINGERPRINT=%q\n' "$fingerprint"
  printf 'GDC_NETWORK_CHAIN_ID=%q\n' "$chain_id"
  printf 'GDC_NETWORK_GENESIS_SHA256=%q\n' "$genesis_sha256"
  printf 'GDC_NETWORK_COMETBFT_VERSION=%q\n' "$cometbft_version"
  printf 'GDC_NETWORK_CORE_VERSION=%q\nGDC_NETWORK_CORE_COMMIT=%q\n' "$node_version" "$node_commit"
  printf 'GDC_NETWORK_DAPI_VERSION=%q\nGDC_NETWORK_DAPI_COMMIT=%q\n' "$api_version" "$api_commit"
  printf 'GDC_NETWORK_DEVSHARD_APPROVALS=%q\n' "$devshard_approvals"
  printf 'GDC_RELEASE_PROFILE=%q\n' "$profile"
} >"$OUTPUT"
chmod 0600 "$OUTPUT"
printf 'PASS observed network software fingerprint=%s profile=%s rpc_seeds=%s api_seeds=%s approval_seeds=%s\n' "$fingerprint" "$profile" "${#rpc_observations[@]}" "${#api_observations[@]}" "${#approval_sets[@]}"
