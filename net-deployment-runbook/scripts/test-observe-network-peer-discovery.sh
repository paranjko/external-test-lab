#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OBSERVE="$ROOT/scripts/observe-network-state.sh"
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT

seed_a=00000000000000000000000000000000000003e9
seed_b=00000000000000000000000000000000000003ea
jq -n --arg a "$seed_a" --arg b "$seed_b" '
  {"$schema":"https://gonka-dev.net/v1.bootstrap.schema.json",chain_id:"gonka-fixture",genesis:{sha256:("d" * 64)},
   seeds:[
     {node_id:$a,rpc:"https://seed-a.example.test/chain-rpc",api:"https://seed-a.example.test",p2p:"tcp://seed-a.example.test:5000"},
     {node_id:$b,rpc:"http://seed-b.example.test:8000/chain-rpc",api:"http://seed-b.example.test:8000",p2p:"tcp://seed-b.example.test:5000"}
   ],brokers:[]}
' >"$tmp/bootstrap.json"
jq '.seeds |= reverse' "$tmp/bootstrap.json" >"$tmp/bootstrap-reversed.json"
jq '.chain_id = "gonka-devnet-community"' "$tmp/bootstrap.json" >"$tmp/bootstrap-community.json"
jq '.chain_id = "gonka-mainnet"' "$tmp/bootstrap.json" >"$tmp/bootstrap-mainnet.json"

mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${!#}"
printf '%s\n' "$url" >>"$CURL_SPY"
write_remote=false
for arg in "$@"; do
  [[ "$arg" == --write-out ]] && write_remote=true
done

chain="${MOCK_CHAIN:-gonka-fixture}"
remote_ip=
case "$url" in
  https://seed-a.example.test/chain-rpc/status)
    catching=false
    [[ "${CATCHING_SEED:-}" == a ]] && catching=true
    printf '{"result":{"node_info":{"id":"00000000000000000000000000000000000003e9","network":"%s","version":"0.38.19"},"sync_info":{"catching_up":%s}}}\n' "$chain" "$catching"
    remote_ip=8.8.4.1
    ;;
  http://seed-b.example.test:8000/chain-rpc/status)
    catching=false
    [[ "${CATCHING_SEED:-}" == b ]] && catching=true
    printf '{"result":{"node_info":{"id":"00000000000000000000000000000000000003ea","network":"%s","version":"0.38.19"},"sync_info":{"catching_up":%s}}}\n' "$chain" "$catching"
    remote_ip=8.8.4.2
    [[ "${SAME_SEED_REMOTE:-false}" == true ]] && remote_ip=8.8.4.1
    ;;
  https://seed-a.example.test/chain-rpc/abci_info|http://seed-b.example.test:8000/chain-rpc/abci_info)
    printf '{"result":{"response":{"version":"0.2.15"}}}\n'
    case "$url" in
      https://*) remote_ip=8.8.4.1 ;;
      http://*) remote_ip=8.8.4.2; [[ "${SAME_SEED_REMOTE:-false}" == true ]] && remote_ip=8.8.4.1 ;;
    esac
    ;;
  https://seed-a.example.test/chain-rpc/net_info|http://seed-b.example.test:8000/chain-rpc/net_info)
    printf '{"result":{"peers":['
    first=true
    sequence="$(seq 1 "${PEER_COUNT:-21}")"
    [[ "${PEER_ORDER:-forward}" == reverse ]] && sequence="$(seq "${PEER_COUNT:-21}" -1 1)"
    for n in $sequence; do
      [[ "$first" == true ]] || printf ','
      first=false
      printf '{"node_info":{"id":"%040x"},"remote_ip":"8.8.8.%d"}' "$n" "$((n + 7))"
    done
    if [[ "${GOSSIP_CONFLICT:-false}" == true ]]; then
      printf ',{"node_info":{"id":"%040x"},"remote_ip":"8.8.8.29"}' 22
      printf ',{"node_info":{"id":"%040x"},"remote_ip":"8.8.8.30"}' 22
      printf ',{"node_info":{"id":"%040x"},"remote_ip":"8.8.8.31"}' 23
      printf ',{"node_info":{"id":"%040x"},"remote_ip":"8.8.8.31"}' 24
      printf ',{"node_info":{"id":"%040x"},"remote_ip":"10.0.0.25"}' 25
    fi
    if [[ "${CONFLICT_QUORUM:-false}" == true ]]; then
      printf ',{"node_info":{"id":"%040x"},"remote_ip":"8.8.8.40"}' 30
      printf ',{"node_info":{"id":"%040x"},"remote_ip":"8.8.8.40"}' 31
      printf ',{"node_info":{"id":"%040x"},"remote_ip":"8.8.8.41"}' 32
      printf ',{"node_info":{"id":"%040x"},"remote_ip":"8.8.8.42"}' 32
    fi
    if [[ "${INCLUDE_SEEDS_IN_GOSSIP:-false}" == true ]]; then
      printf ',{"node_info":{"id":"00000000000000000000000000000000000003e9"},"remote_ip":"8.8.4.1"}'
      printf ',{"node_info":{"id":"00000000000000000000000000000000000003ea"},"remote_ip":"8.8.4.2"}'
    fi
    printf ']}}\n'
    case "$url" in
      https://*) remote_ip=8.8.4.1 ;;
      http://*)
        remote_ip=8.8.4.2
        [[ "${SAME_SEED_REMOTE:-false}" == true ]] && remote_ip=8.8.4.1
        ;;
    esac
    ;;
  https://seed-a.example.test/v1/versions|http://seed-b.example.test:8000/v1/versions)
    seed=a; remote_ip=8.8.4.1
    [[ "$url" == http://* ]] && { seed=b; remote_ip=8.8.4.2; }
    [[ "${SAME_SEED_REMOTE:-false}" == true && "$seed" == b ]] && remote_ip=8.8.4.1
    [[ "${SEED_API_DOWN:-}" == all || "${SEED_API_DOWN:-}" == "$seed" ]] && exit 22
    [[ "${MISMATCH_SEED_API:-}" == "$seed" ]] && remote_ip=8.8.4.9
    dapi=0.2.15-post5
    dapi_commit=cccccccccccccccccccccccccccccccccccccccc
    if [[ "${SEED_DAPI:-}" == post3 || "${SEED_SPLIT:-false}:$seed" == true:a ]]; then
      dapi=0.2.15-post3
      dapi_commit=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    fi
    printf '{"node_version":{"application_name":"inference-chain","version":"0.2.15","commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"api_version":{"application_name":"decentralized-api","version":"%s","commit":"%s"}}\n' "$dapi" "$dapi_commit"
    ;;
  http://8.8.4.[12]:8000/v1/versions)
    [[ "${PEERS_DOWN:-false}" == true ]] && exit 7
    octet="${url#http://8.8.4.}"; octet="${octet%%:*}"
    dapi=0.2.15-post5
    dapi_commit=cccccccccccccccccccccccccccccccccccccccc
    [[ "${SEED_DAPI:-}" == post3 ]] && { dapi=0.2.15-post3; dapi_commit=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; }
    printf '{"node_version":{"application_name":"inference-chain","version":"0.2.15","commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"api_version":{"application_name":"decentralized-api","version":"%s","commit":"%s"}}\n' "$dapi" "$dapi_commit"
    remote_ip="8.8.4.$octet"
    ;;
  http://8.8.8.*:8000/chain-rpc/*)
    # Real public peers commonly expose DAPI but no public chain-rpc surface.
    exit 22
    ;;
  http://8.8.8.*:8000/v1/epochs/current/participants)
    octet="${url#http://8.8.8.}"; octet="${octet%%:*}"; n=$((octet - 7))
    [[ "${CHAIN_EVIDENCE_DOWN_PEER:-}" == "$n" ]] && exit 22
    observed_chain="$chain"
    [[ "${OTHER_CHAIN_PEER:-}" == "$n" ]] && observed_chain=gonka-other
    printf '{"block":{"header":{"chain_id":"%s","height":"123"}}}\n' "$observed_chain"
    remote_ip="8.8.8.$octet"
    [[ "${CHAIN_PRIVATE_REMOTE_PEER:-}" == "$n" ]] && remote_ip=10.0.0.8
    ;;
  http://8.8.8.*:8000/v1/versions)
    [[ "${PEERS_DOWN:-false}" == true ]] && exit 7
    octet="${url#http://8.8.8.}"; octet="${octet%%:*}"; n=$((octet - 7))
    [[ "${UNREACHABLE_PEER:-}" == "$n" ]] && exit 7
    core=0.2.15
    core_commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    dapi=0.2.15-post3
    dapi_commit=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    if [[ "${FORCE_DAPI:-}" == post5 || "$n" -ge 18 && "$n" -le 20 || "${SPLIT_TWO:-false}" == true && "$n" -eq 2 ]]; then
      dapi=0.2.15-post5
      dapi_commit=cccccccccccccccccccccccccccccccccccccccc
    elif [[ "$n" -eq 21 ]]; then
      core=0.2.14
      core_commit=dddddddddddddddddddddddddddddddddddddddd
    fi
    api_application=decentralized-api
    [[ "${OTHER_APP_PEER:-}" == "$n" ]] && api_application=other-api
    printf '{"node_version":{"application_name":"inference-chain","version":"%s","commit":"%s"},"api_version":{"application_name":"%s","version":"%s","commit":"%s"}}\n' \
      "$core" "$core_commit" "$api_application" "$dapi" "$dapi_commit"
    remote_ip="8.8.8.$octet"
    [[ "${PRIVATE_REMOTE_PEER:-}" == "$n" ]] && remote_ip=10.0.0.8
    ;;
  *) exit 2 ;;
esac
if [[ "$write_remote" == true ]]; then
  [[ -n "$remote_ip" ]] || exit 2
  printf '\n__GDC_REMOTE_IP__=%s\n' "$remote_ip"
fi
EOF
chmod 0755 "$tmp/bin/curl"

run_case() {
  local bootstrap="$1" output="$2" chain="${3:-gonka-fixture}" spy
  spy="${output}.curl-spy"
  : >"$spy"
  CURL_SPY="$spy" MOCK_CHAIN="$chain" \
    PEER_COUNT="${PEER_COUNT:-21}" PEER_ORDER="${PEER_ORDER:-forward}" \
    CATCHING_SEED="${CATCHING_SEED:-}" GOSSIP_CONFLICT="${GOSSIP_CONFLICT:-false}" \
    SAME_SEED_REMOTE="${SAME_SEED_REMOTE:-false}" \
    SEED_API_DOWN="${SEED_API_DOWN:-}" SEED_DAPI="${SEED_DAPI:-}" \
    SEED_SPLIT="${SEED_SPLIT:-false}" MISMATCH_SEED_API="${MISMATCH_SEED_API:-}" \
    INCLUDE_SEEDS_IN_GOSSIP="${INCLUDE_SEEDS_IN_GOSSIP:-false}" PEERS_DOWN="${PEERS_DOWN:-false}" \
    CONFLICT_QUORUM="${CONFLICT_QUORUM:-false}" UNREACHABLE_PEER="${UNREACHABLE_PEER:-}" \
    OTHER_APP_PEER="${OTHER_APP_PEER:-}" PRIVATE_REMOTE_PEER="${PRIVATE_REMOTE_PEER:-}" \
    OTHER_CHAIN_PEER="${OTHER_CHAIN_PEER:-}" CHAIN_EVIDENCE_DOWN_PEER="${CHAIN_EVIDENCE_DOWN_PEER:-}" \
    CHAIN_PRIVATE_REMOTE_PEER="${CHAIN_PRIVATE_REMOTE_PEER:-}" \
    FORCE_DAPI="${FORCE_DAPI:-}" SPLIT_TWO="${SPLIT_TWO:-false}" \
    PATH="$tmp/bin:$PATH" "$OBSERVE" --bootstrap-file "$bootstrap" \
      --bootstrap-url "https://gonka.dev/${chain}/bootstrap.json" --chain-id "$chain" \
      --run-id peer-discovery-fixture --output "$output"
}

run_case "$tmp/bootstrap.json" "$tmp/normal.json"
jq -e '
  .runtime.dapi.version == "0.2.15-post3" and
  .policy.policy_id == "net-info-software-majority/v1" and
  .policy.quorum_policy.policy_id == "gdc-join-software-quorum/v1" and
  .policy.quorum_policy.source == "runbook_local" and
  .policy.quorum_policy.scope == "default" and
  .policy.quorum_policy.minimum_valid_observations == 3 and
  .policy.quorum_policy.minimum_independent_discovery_roots == 2 and
  (.policy.quorum_policy.definition_sha256 | test("^[0-9a-f]{64}$")) and
  .policy.authority.valid_observation_count == 23 and
  .policy.authority.strict_majority_count == 17 and
  .policy.authority.selected.tuple.core.application_name == "inference-chain" and
  .policy.authority.selected.tuple.dapi.application_name == "decentralized-api" and
  .policy.authority.selected_discovery_root_count == 2 and
  .policy.authority.selected.discovery_root_count == 2 and
  .runtime_api_origins[0].seed_index == -1 and
  .runtime_api_origins[0].cometbft.version == "0.38.19" and
  ([.policy.discovered_peers[].node_id] | unique | length) == 21 and
  ([.policy.discovered_peers[] | select(.node_id == "0000000000000000000000000000000000000001") | .discovery_root_ids | length] | max) == 2
' "$tmp/normal.json" >/dev/null
[[ "$(stat -c %a "$tmp/normal.json")" == 600 ]]
[[ "$(grep -Ec '^http://8\.8\.8\.[0-9]+:8000/v1/versions$' "$tmp/normal.json.curl-spy")" -eq 21 ]]
[[ "$(grep -Ec '^http://8\.8\.8\.[0-9]+:8000/chain-rpc/status$' "$tmp/normal.json.curl-spy")" -eq 21 ]]
[[ "$(grep -Ec '^http://8\.8\.8\.[0-9]+:8000/v1/epochs/current/participants$' "$tmp/normal.json.curl-spy")" -eq 21 ]]
[[ "$(grep -Ec 'seed-[ab].*/v1/versions$' "$tmp/normal.json.curl-spy")" -eq 2 ]]

PEER_ORDER=reverse run_case "$tmp/bootstrap-reversed.json" "$tmp/reversed.json"
jq -e '.runtime.dapi.version == "0.2.15-post3" and .policy.authority.strict_majority_count == 17' "$tmp/reversed.json" >/dev/null

SAME_SEED_REMOTE=true run_case "$tmp/bootstrap.json" "$tmp/seed-aliases.json"
jq -e '.policy.authority.valid_observation_count == 21 and .policy.authority.strict_majority_count == 17' "$tmp/seed-aliases.json" >/dev/null

INCLUDE_SEEDS_IN_GOSSIP=true run_case "$tmp/bootstrap.json" "$tmp/seed-peer-dedup.json"
jq -e '.policy.authority.valid_observation_count == 23 and .policy.authority.strict_majority_count == 17' "$tmp/seed-peer-dedup.json" >/dev/null

if CATCHING_SEED=a run_case "$tmp/bootstrap.json" "$tmp/catching-root.json" >"$tmp/catching-root.out" 2>"$tmp/catching-root.err"; then
  echo 'one usable discovery root unexpectedly satisfied root corroboration' >&2
  exit 1
fi
jq -e '.state == "insufficient_discovery_roots" and .valid_observation_count == 22 and .minimum_independent_discovery_roots == 2 and .selected_discovery_root_count == 1 and .selected == null' "$tmp/catching-root.json.software-authority.json" >/dev/null
grep -Fq 'network_observation_insufficient_discovery_roots:' "$tmp/catching-root.err"
if grep -Fq 'https://seed-a.example.test/chain-rpc/net_info' "$tmp/catching-root.json.curl-spy"; then
  echo 'catching-up seed unexpectedly acted as a discovery root' >&2
  exit 1
fi

UNREACHABLE_PEER=18 run_case "$tmp/bootstrap.json" "$tmp/unreachable.json"
jq -e '.policy.authority.valid_observation_count == 22 and .policy.authority.strict_majority_count == 17 and ([.policy.excluded_observations[] | select(.reason == "versions_unavailable")] | length) == 1' "$tmp/unreachable.json" >/dev/null

OTHER_APP_PEER=17 run_case "$tmp/bootstrap.json" "$tmp/other-app.json"
jq -e '.policy.authority.valid_observation_count == 22 and .policy.authority.strict_majority_count == 16 and ([.policy.excluded_observations[] | select(.reason == "application_mismatch")] | length) == 1' "$tmp/other-app.json" >/dev/null

PRIVATE_REMOTE_PEER=17 run_case "$tmp/bootstrap.json" "$tmp/private-remote.json"
jq -e '.policy.authority.valid_observation_count == 22 and .policy.authority.strict_majority_count == 16 and ([.policy.excluded_observations[] | select(.reason == "versions_remote_address")] | length) == 1' "$tmp/private-remote.json" >/dev/null

OTHER_CHAIN_PEER=17 run_case "$tmp/bootstrap.json" "$tmp/other-chain.json"
jq -e '.policy.authority.valid_observation_count == 22 and .policy.authority.strict_majority_count == 16 and ([.policy.excluded_observations[] | select(.reason == "chain_identity_mismatch")] | length) == 1' "$tmp/other-chain.json" >/dev/null

CHAIN_EVIDENCE_DOWN_PEER=17 run_case "$tmp/bootstrap.json" "$tmp/no-chain-evidence.json"
jq -e '.policy.authority.valid_observation_count == 22 and .policy.authority.strict_majority_count == 16 and ([.policy.excluded_observations[] | select(.reason == "chain_identity_unavailable")] | length) == 1' "$tmp/no-chain-evidence.json" >/dev/null

GOSSIP_CONFLICT=true run_case "$tmp/bootstrap.json" "$tmp/stale-conflicts.json"
jq '{valid:.policy.authority.valid_observation_count,majority:.policy.authority.strict_majority_count,nodes:.policy.authority.conflicting_node_ids,ips:.policy.authority.conflicting_remote_ips,reasons:[.policy.excluded_observations[].reason]}' "$tmp/stale-conflicts.json"
jq -e '
  .result.state == "ready" and
  .policy.authority.valid_observation_count == 23 and
  .policy.authority.strict_majority_count == 17 and
  (.policy.authority.conflicting_node_ids | index("0000000000000000000000000000000000000016") != null) and
  .policy.authority.conflicting_remote_ips == ["redacted"] and
  ([.policy.excluded_observations[] | select(.reason == "identity_conflict")] | length) == 3 and
  ([.policy.excluded_observations[] | select(.reason == "non_public_peer" and .remote_ip == "redacted")] | length) == 1
' "$tmp/stale-conflicts.json" >/dev/null

if SEED_API_DOWN=all PEER_COUNT=1 CONFLICT_QUORUM=true run_case "$tmp/bootstrap.json" "$tmp/conflict-quorum.json" >"$tmp/conflict-quorum.out" 2>"$tmp/conflict-quorum.err"; then
  echo 'conflicts that leave fewer than the default quorum unexpectedly passed' >&2
  exit 1
fi
grep -Fq 'network_observation_insufficient_quorum:' "$tmp/conflict-quorum.err"
jq -e '.state == "insufficient_quorum" and .valid_observation_count == 1 and .minimum_quorum == 3 and (.conflicting_node_ids | length) >= 1 and .conflicting_remote_ips == ["redacted"]' "$tmp/conflict-quorum.json.software-authority.json" >/dev/null
[[ "$(stat -c %a "$tmp/conflict-quorum.json.software-authority.json")" == 600 ]]

base_state="$(jq -r .network_state_id "$tmp/normal.json")"
for stable in reversed seed-aliases seed-peer-dedup unreachable other-app private-remote other-chain no-chain-evidence stale-conflicts; do
  [[ "$(jq -r .network_state_id "$tmp/$stable.json")" == "$base_state" ]]
done

FORCE_DAPI=post5 run_case "$tmp/bootstrap.json" "$tmp/post5.json"
[[ "$(jq -r .network_state_id "$tmp/post5.json")" != "$base_state" ]]
jq '.genesis.sha256 = ("e" * 64)' "$tmp/bootstrap.json" >"$tmp/genesis-changed.json"
run_case "$tmp/genesis-changed.json" "$tmp/genesis-changed-result.json"
[[ "$(jq -r .network_state_id "$tmp/genesis-changed-result.json")" != "$base_state" ]]
jq '.chain_id = "gonka-other"' "$tmp/bootstrap.json" >"$tmp/chain-changed.json"
run_case "$tmp/chain-changed.json" "$tmp/chain-changed-result.json" gonka-other
[[ "$(jq -r .network_state_id "$tmp/chain-changed-result.json")" != "$base_state" ]]

# Community is an explicit reviewed two-observation policy. Agreement passes,
# one endpoint fails, and a 1/1 split cannot establish a strict majority.
SEED_DAPI=post3 PEERS_DOWN=true PEER_COUNT=2 run_case "$tmp/bootstrap-community.json" "$tmp/community-two.json" gonka-devnet-community
jq -e '.policy.minimum_valid_observations == 2 and .policy.quorum_policy.scope == "network" and .policy.authority.strict_majority_count == 2 and .result.state == "ready"' "$tmp/community-two.json" >/dev/null
if SEED_DAPI=post3 SEED_API_DOWN=b PEERS_DOWN=true PEER_COUNT=2 run_case "$tmp/bootstrap-community.json" "$tmp/community-one.json" gonka-devnet-community >"$tmp/community-one.out" 2>"$tmp/community-one.err"; then
  echo 'one Community endpoint unexpectedly selected a profile' >&2
  exit 1
fi
jq -e '.state == "insufficient_quorum" and .valid_observation_count == 1 and .minimum_quorum == 2' "$tmp/community-one.json.software-authority.json" >/dev/null
if SEED_SPLIT=true PEERS_DOWN=true PEER_COUNT=2 run_case "$tmp/bootstrap-community.json" "$tmp/community-split.json" gonka-devnet-community >"$tmp/community-split.out" 2>"$tmp/community-split.err"; then
  echo 'Community 1/1 software split unexpectedly selected a profile' >&2
  exit 1
fi
jq -e '.state == "no_strict_majority" and .valid_observation_count == 2 and .minimum_quorum == 2 and .strict_majority_count == 1' "$tmp/community-split.json.software-authority.json" >/dev/null

# Mainnet and every unknown network retain the default quorum of three.
if SEED_DAPI=post3 PEERS_DOWN=true PEER_COUNT=2 run_case "$tmp/bootstrap-mainnet.json" "$tmp/mainnet-two.json" gonka-mainnet >"$tmp/mainnet-two.out" 2>"$tmp/mainnet-two.err"; then
  echo 'two Mainnet endpoints unexpectedly satisfied the default quorum' >&2
  exit 1
fi
jq -e '.state == "insufficient_quorum" and .minimum_quorum == 3' "$tmp/mainnet-two.json.software-authority.json" >/dev/null
SEED_DAPI=post3 PEER_COUNT=1 run_case "$tmp/bootstrap-mainnet.json" "$tmp/mainnet-three.json" gonka-mainnet
jq -e '.policy.minimum_valid_observations == 3 and .policy.quorum_policy.scope == "default" and .policy.authority.strict_majority_count == 3' "$tmp/mainnet-three.json" >/dev/null

python3 - "$ROOT/lineage/network-observation.v1.schema.json" \
  "$tmp/normal.json" "$tmp/reversed.json" "$tmp/seed-aliases.json" "$tmp/seed-peer-dedup.json" \
  "$tmp/unreachable.json" "$tmp/other-app.json" "$tmp/private-remote.json" "$tmp/other-chain.json" "$tmp/no-chain-evidence.json" \
  "$tmp/stale-conflicts.json" "$tmp/community-two.json" "$tmp/mainnet-three.json" <<'PY'
import json
import pathlib
import sys

from jsonschema import Draft202012Validator

schema = json.loads(pathlib.Path(sys.argv[1]).read_text())
Draft202012Validator.check_schema(schema)
validator = Draft202012Validator(schema)
for path in map(pathlib.Path, sys.argv[2:]):
    errors = sorted(validator.iter_errors(json.loads(path.read_text())), key=lambda error: list(error.path))
    if errors:
        raise SystemExit(f"{path}: {errors[0].message}")
PY

printf 'PASS peer discovery: chain-bound peer probing, root-span corroboration, one-root Sybil rejection, overlapping-root support, seed-order independence, conflict exclusion, local quorum policy, and stable network identity\n'
