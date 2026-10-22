#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OBSERVE="$ROOT/scripts/observe-network-state.sh"
tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT

ids=(0123456789abcdef0123456789abcdef01234567 89abcdef0123456789abcdef0123456789abcdef fedcba9876543210fedcba9876543210fedcba98 abcdef0123456789abcdef0123456789abcdef01 1234567890abcdef1234567890abcdef12345678)
printf '%s\n' "${ids[@]}" >"$tmp/ids"
jq -n --argjson ids "$(printf '%s\n' "${ids[@]}" | jq -R . | jq -cs .)" '
  {"$schema":"https://gonka-dev.net/v1.bootstrap.schema.json",chain_id:"gonka-devnet-community",genesis:{sha256:"93c32ec403d59af6337c0d79c3ee16010c99394f8ecd9aee4fc72a898f64a9a6"},
   seeds:[$ids | to_entries[] | {node_id:.value,rpc:("https://node" + (.key|tostring) + ".example.test/chain-rpc"),p2p:("tcp://node" + (.key|tostring) + ".example.test:5000")} | if .node_id == $ids[0] then . + {api:"https://node0.example.test"} else . end],
   brokers:[]}
' >"$tmp/bootstrap.json"

mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${!#}"
[[ -z "${CURL_SPY:-}" ]] || printf '%s\n' "$url" >>"$CURL_SPY"
write_remote=false
for arg in "$@"; do
  [[ "$arg" == --write-out ]] && write_remote=true
done
node=
case "$url" in
  https://node[0-4].example.test/chain-rpc/*)
    host="${url#https://node}"; node="${host%%.*}"
    id="$(sed -n "$((node + 1))p" "$IDS_FILE")"
    case "${MODE:-good}:$node:$url" in
      all_roots_down:*:*status) exit 7 ;;
    esac
    case "$url" in
      */abci_info)
        case "${MODE:-}" in
          operator) printf '{"result":{"response":{"version":"0.2.15"}}}\n' ;;
          single_software|single_software_mismatch) printf '{"result":{"response":{"version":"0.2.16-post1"}}}\n' ;;
          *) exit 22 ;;
        esac ;;
      */status)
        catching=false
        [[ "${MODE:-good}:$node" == catching_root:0 ]] && catching=true
        printf '{"result":{"node_info":{"id":"%s","network":"gonka-devnet-community","version":"0.38.19"},"sync_info":{"catching_up":%s,"latest_block_height":"123"}}}\n' "$id" "$catching"
        ;;
      */net_info)
        printf '{"result":{"peers":['
        for peer in 0 1 2 3 4; do
          ((peer == 0)) || printf ','
          printf '{"node_info":{"id":"%s"},"remote_ip":"8.8.4.%d"}' "$(sed -n "$((peer + 1))p" "$IDS_FILE")" "$((peer + 1))"
        done
        printf ']}}\n'
        ;;
      *) exit 2 ;;
    esac
    remote_ip="8.8.4.$((node + 1))"
    ;;
  https://node0.example.test/v1/versions)
    remote_ip=8.8.4.1
    case "${MODE:-}" in
      operator) printf '{"node_version":{"application_name":"inference-chain","version":"0.2.15","commit":"4d687ed6782bcea3931d2d9135bf322f84e190ab"},"api_version":{"application_name":"decentralized-api","version":"0.2.15-post3","commit":"5dbb53ddf3ddc42655fc04dc39d96003169bdbb0"}}\n' ;;
      single_software|single_software_mismatch)
        dapi=0.2.16-post1
        [[ "${MODE:-}" != single_software_mismatch ]] || dapi=0.2.16-post2
        printf '{"node_version":{"application_name":"inference-chain","version":"0.2.16-post1","commit":"136041c81ea8ff38e7620d76af66a7c7fe7eec50"},"api_version":{"application_name":"decentralized-api","version":"%s","commit":"136041c81ea8ff38e7620d76af66a7c7fe7eec50"}}\n' "$dapi" ;;
      *) exit 22 ;;
    esac
    ;;
  http://8.8.4.[1-5]:8000/chain-rpc/*)
    exit 22
    ;;
  http://8.8.4.[1-5]:8000/v1/epochs/current/participants)
    octet="${url#http://8.8.4.}"; octet="${octet%%:*}"; node=$((octet - 1))
    case "${MODE:-good}:$node" in
      three_peer_down:[0-2]|four_peer_down:[0-3]) exit 7 ;;
    esac
    printf '{"block":{"header":{"chain_id":"gonka-devnet-community","height":"123"}}}\n'
    remote_ip="8.8.4.$octet"
    ;;
  http://8.8.4.[1-5]:8000/v1/versions)
    octet="${url#http://8.8.4.}"; octet="${octet%%:*}"; node=$((octet - 1))
    case "${MODE:-good}:$node" in
      three_peer_down:[0-2]|four_peer_down:[0-3]) exit 7 ;;
    esac
    dapi=0.2.15-post3
    commit=5dbb53ddf3ddc42655fc04dc39d96003169bdbb0
    if [[ "${MODE:-good}:$node" == different_tuples:1 ]]; then
      dapi=0.2.16
      commit=18506d42c510e0cafe6acd748bcd8d83036cba40
    fi
    printf '{"node_version":{"application_name":"inference-chain","version":"0.2.15","commit":"4d687ed6782bcea3931d2d9135bf322f84e190ab"},"api_version":{"application_name":"decentralized-api","version":"%s","commit":"%s"}}\n' "$dapi" "$commit"
    remote_ip="8.8.4.$octet"
    ;;
  *) exit 2 ;;
esac
if [[ "$write_remote" == true ]]; then
  printf '\n__GDC_REMOTE_IP__=%s\n' "$remote_ip"
fi
EOF
chmod 0755 "$tmp/bin/curl"

run_case() {
  local mode="$1"
  MODE="$mode" IDS_FILE="$tmp/ids" PATH="$tmp/bin:$PATH" "$OBSERVE" \
    --bootstrap-file "$tmp/bootstrap.json" \
    --bootstrap-url https://gonka-dev.net/gonka-devnet-community/bootstrap.json \
    --chain-id gonka-devnet-community --run-id fixture-run --output "$tmp/$mode.json"
}

run_case good
jq -e '
  .runtime_api_origins[0].seed_index == -1 and
  .runtime_api_origins[0].api_source == "derived" and
  .policy.minimum_valid_observations == 2 and
  .policy.quorum_policy.minimum_independent_discovery_roots == 2 and
  .policy.authority.valid_observation_count == 5 and
  .policy.authority.strict_majority_count == 5 and
  .policy.authority.selected_discovery_root_count == 5 and
  .policy.authority.selected.discovery_root_count == 5 and
  ([.seeds[] | select(.status == "usable")] | length) == 5
' "$tmp/good.json" >/dev/null

run_case three_peer_down
jq -e '.policy.authority.valid_observation_count == 2 and .policy.authority.strict_majority_count == 2 and .policy.authority.selected_discovery_root_count == 5 and .result.state == "ready"' "$tmp/three_peer_down.json" >/dev/null

if run_case four_peer_down >"$tmp/four-peer-down.out" 2>"$tmp/four-peer-down.err"; then
  echo 'one Community endpoint unexpectedly satisfied the local quorum' >&2
  exit 1
fi
jq -e '.state == "insufficient_quorum" and .valid_observation_count == 1 and .minimum_quorum == 2' "$tmp/four_peer_down.json.software-authority.json" >/dev/null

run_case different_tuples
jq -e '.runtime.dapi.version == "0.2.15-post3" and .policy.authority.strict_majority_count == 4' "$tmp/different_tuples.json" >/dev/null

run_case catching_root
jq -e '.seeds[0].status == "unavailable" and .seeds[0].reason == "catching_up" and .policy.authority.valid_observation_count == 5' "$tmp/catching_root.json" >/dev/null

if run_case all_roots_down >"$tmp/all-roots-down.out" 2>"$tmp/all-roots-down.err"; then
  echo 'unavailable discovery roots unexpectedly formed a runtime observation' >&2
  exit 1
fi
jq -e '.state == "insufficient_quorum" and .valid_observation_count == 0 and .minimum_quorum == 2' "$tmp/all_roots_down.json.software-authority.json" >/dev/null

if IDS_FILE="$tmp/ids" PATH="$tmp/bin:$PATH" "$OBSERVE" --bootstrap-file "$tmp/bootstrap.json" \
  --bootstrap-url https://gonka-dev.net/gonka-devnet-community/bootstrap.json \
  --chain-id gonka-other --run-id fixture-run --output "$tmp/mismatch.json" >"$tmp/mismatch.out" 2>"$tmp/mismatch.err"; then
  echo 'Bootstrap chain ID mismatch unexpectedly passed' >&2
  exit 1
fi
grep -Fq 'network_observation_chain_id_mismatch:' "$tmp/mismatch.err"

printf 'PASS network observation: Community quorum, peer majority, catching-root rejection, unavailable peers, and fail-closed discovery\n'
MODE=operator CURL_SPY="$tmp/source-requests" IDS_FILE="$tmp/ids" PATH="$tmp/bin:$PATH" "$OBSERVE" \
  --bootstrap-file "$tmp/bootstrap.json" --bootstrap-url https://gonka-dev.net/gonka-devnet-community/bootstrap.json \
  --chain-id gonka-devnet-community --run-id fixture-source --output "$tmp/source.json" --source-rpc https://node0.example.test/chain-rpc
jq -e '.policy.mode=="operator_source" and .policy.source_rpc=="https://node0.example.test/chain-rpc" and .policy.authority.state=="operator_selected"
  and (.seeds|length)==1 and .policy.discovered_peers==[]' "$tmp/source.json" >/dev/null
! grep -Ev '^https://node0.example.test/' "$tmp/source-requests"
! grep -q '/net_info' "$tmp/source-requests"
printf 'PASS explicit source selection is recorded as one authority without gossip or invented quorum\n'

jq --arg id "${ids[0]}" --slurpfile release "$(dirname "$ROOT")/bootstrap/gonka-devnet-community.json" \
  '.bootstrap_mode="genesis-single-seed" | .seeds=[{node_id:$id,rpc:"https://node0.example.test/chain-rpc",p2p:"tcp://node0.example.test:5000",api:"https://node0.example.test"}] | .software=$release[0].software' \
  "$tmp/bootstrap.json" >"$tmp/single-software-bootstrap.json"
MODE=single_software IDS_FILE="$tmp/ids" PATH="$tmp/bin:$PATH" "$OBSERVE" \
  --bootstrap-file "$tmp/single-software-bootstrap.json" --bootstrap-url https://gonka-dev.net/gonka-devnet-community/bootstrap.json \
  --chain-id gonka-devnet-community --run-id fixture-single-software --output "$tmp/single-software.json"
jq -e '.policy.policy_id=="bootstrap-software/v1" and .policy.mode=="operator_source" and
  .policy.source_rpc=="https://node0.example.test/chain-rpc" and (.seeds|length)==1 and .seeds[0].status=="usable" and
  (.runtime_api_origins|length)==1 and .runtime_api_origins[0].seed_index==0 and .runtime_api_origins[0].status=="usable" and .runtime_api_origins[0].node_id==.seeds[0].expected_node_id and .runtime_api_origins[0].remote_ip=="8.8.4.1" and
  .runtime.core.version==.software.components.node.version and .runtime.core.commit==.software.components.node.commit and
  .runtime.dapi.version==.software.components.api.version and .runtime.dapi.commit==.software.components.api.commit' "$tmp/single-software.json" >/dev/null
printf 'PASS explicit genesis single-seed software observation includes live identity and pinned runtime evidence\n'
# This synthetic lineage fixture models the confirm-observation field; the
# separate identity test below exercises deriving it from exact staged bytes.
jq '.bootstrap.chain_identity_sha256 = .bootstrap.genesis_sha256' "$tmp/single-software.json" >"$tmp/single-software-confirm.json"
mv "$tmp/single-software-confirm.json" "$tmp/single-software.json"
GDC_JOIN_RPC_IP_MAP='node0.example.test=8.8.4.1' IDS_FILE="$tmp/ids" PATH="$tmp/bin:$PATH" \
  "$ROOT/scripts/preflight-join-lineage.sh" --bootstrap-file "$tmp/single-software-bootstrap.json" \
  --observation "$tmp/single-software.json" --receipt "$tmp/single-software-lineage.json" \
  --env "$tmp/single-software-lineage.env" --source-rpc https://node0.example.test/chain-rpc >/dev/null
jq -e '.bootstrap.mode=="full_sync" and .result.terminal_state=="prepared" and .trust_authority.kind=="genesis_single_seed"' \
  "$tmp/single-software-lineage.json" >/dev/null
printf 'PASS observed single-seed runtime witness satisfies strict live full-sync lineage preflight\n'
if MODE=single_software_mismatch IDS_FILE="$tmp/ids" PATH="$tmp/bin:$PATH" "$OBSERVE" \
  --bootstrap-file "$tmp/single-software-bootstrap.json" --bootstrap-url https://gonka-dev.net/gonka-devnet-community/bootstrap.json \
  --chain-id gonka-devnet-community --run-id fixture-single-software-mismatch --output "$tmp/single-software-mismatch.json" \
  >"$tmp/single-software-mismatch.out" 2>"$tmp/single-software-mismatch.err"; then
  echo 'single-seed software descriptor unexpectedly accepted a runtime mismatch' >&2
  exit 1
fi
grep -Fq 'network_observation_bootstrap_runtime_mismatch:' "$tmp/single-software-mismatch.err"
printf 'PASS genesis single-seed software observer rejects live runtime mismatch\n'

# The confirmation observation must use the candidate profile's exact pinned
# CLI to validate raw distribution bytes before adding canonical identity.
identity_genesis="$tmp/identity-genesis.json"
cat >"$identity_genesis" <<'EOF'
{"app_name":"fixture","app_version":"v1","chain_id":"gonka-devnet-community","initial_height":1,"app_hash":null,"consensus":{"params":{"block":{"max_bytes":"22020096"}}}}
EOF
identity_raw="$(sha256sum "$identity_genesis" | awk '{print $1}')"
jq --arg id "${ids[0]}" --arg raw "$identity_raw" --slurpfile release "$(dirname "$ROOT")/bootstrap/gonka-devnet-community.json" \
  '.bootstrap_mode="genesis-single-seed" | .genesis.sha256=$raw | .seeds=[{node_id:$id,rpc:"https://node0.example.test/chain-rpc",p2p:"tcp://node0.example.test:5000",api:"https://node0.example.test"}] | .software=$release[0].software' \
  "$tmp/bootstrap.json" >"$tmp/identity-bootstrap.json"
identity_archive_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
identity_cli_version=9.9.9
prepare_identity_cli() {
  local cli_dir="$1/bin/$identity_cli_version" binary_sha
  mkdir -p "$cli_dir"
  cat >"$cli_dir/inferenced" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  version) printf 'inferenced v9.9.9\n' ;;
  download-genesis)
    if [[ "${GDC_TEST_BAD_GENESIS:-false}" == true ]]; then
      cp "$GDC_TEST_BAD_GENESIS_FILE" "$3"
    else
      cp "$GDC_TEST_GENESIS_FILE" "$3"
    fi
    ;;
  *) exit 2 ;;
esac
EOF
  chmod 0755 "$cli_dir/inferenced"
  binary_sha="$(sha256sum "$cli_dir/inferenced" | awk '{print $1}')"
  printf 'archive_sha256=%s\nplatform=LINUX_AMD64\nbinary_sha256=%s\n' "$identity_archive_sha" "$binary_sha" >"$cli_dir/artifact.env"
  jq -n --arg version "$identity_cli_version" --arg archive "$identity_archive_sha" \
    '{spec:{components:{core:{expected_runtime:{version:$version},installation:{binary:{sha256:$archive}}}}}}' >"$tmp/identity-profile.json"
}
identity_canonical="$(jq -eS 'del(.app_name,.app_version) | if has("app_hash") then .app_hash=(.app_hash//"") else . end | if has("initial_height") then .initial_height=(.initial_height|tostring) else . end | if .consensus.params? then .consensus_params=.consensus.params | del(.consensus) else . end' "$identity_genesis" | sha256sum | awk '{print $1}')"
prepare_identity_cli "$tmp/identity-cli-home"
jq --arg raw "$identity_raw" '.genesis.sha256=$raw' "$tmp/bootstrap.json" >"$tmp/identity-two-seed-bootstrap.json"
GDC_TEST_GENESIS_FILE="$identity_genesis" IDS_FILE="$tmp/ids" MODE=good PATH="$tmp/bin:$PATH" \
  "$OBSERVE" --bootstrap-file "$tmp/identity-two-seed-bootstrap.json" --bootstrap-url https://gonka-dev.net/gonka-devnet-community/bootstrap.json \
    --chain-id gonka-devnet-community --run-id fixture-identity-unenriched --output "$tmp/identity-unenriched-observation.json"
GDC_HOME="$tmp/identity-cli-home" GDC_TEST_GENESIS_FILE="$identity_genesis" IDS_FILE="$tmp/ids" MODE=single_software PATH="$tmp/bin:$PATH" \
  "$OBSERVE" --bootstrap-file "$tmp/identity-two-seed-bootstrap.json" --bootstrap-url https://gonka-dev.net/gonka-devnet-community/bootstrap.json \
    --chain-id gonka-devnet-community --run-id fixture-identity --output "$tmp/identity-observation.json" \
    --join-profile "$tmp/identity-profile.json"
jq -e --arg raw "$identity_raw" --arg canonical "$identity_canonical" \
  '.bootstrap.genesis_sha256==$raw and .bootstrap.chain_identity_sha256==$canonical' "$tmp/identity-observation.json" >/dev/null
expected_identity_state="$(jq -cS --arg identity "$identity_canonical" '
  {prior_network_state_id:.network_state_id,
   bootstrap:{chain_id:.bootstrap.chain_id,distribution_sha256:.bootstrap.genesis_sha256,
     chain_identity_sha256:$identity,document_sha256:.bootstrap.document_sha256},
   runtime:{core:.runtime.core,dapi:.runtime.dapi},software:(.software // null)}
' "$tmp/identity-unenriched-observation.json" | sha256sum | awk '{print $1}')"
[[ "$(jq -r .network_state_id "$tmp/identity-observation.json")" == "$expected_identity_state" ]] \
  || { echo 'canonical identity enrichment did not preserve the prior policy/source fingerprint' >&2; exit 1; }
GDC_HOME="$tmp/identity-cli-home" GDC_TEST_GENESIS_FILE="$identity_genesis" IDS_FILE="$tmp/ids" MODE=good PATH="$tmp/bin:$PATH" \
  "$OBSERVE" --bootstrap-file "$tmp/identity-two-seed-bootstrap.json" --bootstrap-url https://gonka-dev.net/gonka-devnet-community/bootstrap.json \
    --chain-id gonka-devnet-community --run-id fixture-identity-two-seed --output "$tmp/identity-two-seed-observation.json" \
    --join-profile "$tmp/identity-profile.json"
jq -e --arg raw "$identity_raw" --arg canonical "$identity_canonical" \
  '.bootstrap.genesis_sha256==$raw and .bootstrap.chain_identity_sha256==$canonical and (.seeds|length)>=2' \
  "$tmp/identity-two-seed-observation.json" >/dev/null
printf '{"wrong":"genesis"}\n' >"$tmp/wrong-genesis.json"
prepare_identity_cli "$tmp/wrong-cli-home" true
if GDC_HOME="$tmp/wrong-cli-home" GDC_TEST_BAD_GENESIS=true GDC_TEST_BAD_GENESIS_FILE="$tmp/wrong-genesis.json" \
  GDC_TEST_GENESIS_FILE="$identity_genesis" IDS_FILE="$tmp/ids" MODE=single_software PATH="$tmp/bin:$PATH" \
  "$OBSERVE" --bootstrap-file "$tmp/identity-bootstrap.json" --bootstrap-url https://gonka-dev.net/gonka-devnet-community/bootstrap.json \
    --chain-id gonka-devnet-community --run-id fixture-identity-bad --output "$tmp/identity-bad.json" \
    --join-profile "$tmp/identity-profile.json" >"$tmp/identity-bad.out" 2>"$tmp/identity-bad.err"; then
  echo 'identity confirmation accepted Genesis bytes that differ from the reviewed Bootstrap digest' >&2
  exit 1
fi
[[ ! -e "$tmp/identity-bad.json" ]] || { echo 'failed identity confirmation left a partial promoted observation' >&2; exit 1; }
if GDC_HOME="$tmp/missing-cli-home" GDC_TEST_GENESIS_FILE="$identity_genesis" IDS_FILE="$tmp/ids" MODE=single_software PATH="$tmp/bin:$PATH" \
  "$OBSERVE" --bootstrap-file "$tmp/identity-bootstrap.json" --bootstrap-url https://gonka-dev.net/gonka-devnet-community/bootstrap.json \
    --chain-id gonka-devnet-community --run-id fixture-identity-missing-cli --output "$tmp/identity-missing-cli.json" \
    --join-profile "$tmp/identity-profile.json" >"$tmp/identity-missing-cli.out" 2>"$tmp/identity-missing-cli.err"; then
  echo 'identity confirmation accepted a missing profile-bound CLI' >&2
  exit 1
fi
[[ ! -e "$tmp/identity-missing-cli.json" ]] || { echo 'missing CLI left a partial promoted observation' >&2; exit 1; }
grep -Fq 'shared inferenced CLI or metadata is missing or unsafe' "$tmp/identity-missing-cli.err"
printf 'PASS confirmation binds exact pinned CLI, raw distribution and canonical Genesis identity; failures leave no promoted observation\n'
