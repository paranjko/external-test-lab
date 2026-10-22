#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fixture="$tmp/fixture"
mkdir -p "$fixture"
tar --exclude='./.data' -C "$ROOT" -cf - . | tar -C "$fixture" -xf -
cp -a "$(dirname "$ROOT")/model" "$tmp/model"
build="$fixture/01-identities-genesis/build-genesis.sh"
mock="$fixture/scripts/inferenced.sh"
cat >"$mock" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
home="$INFERENCED_HOME"; genesis="$home/config/genesis.json"; mkdir -p "$home/config"
case "$1 ${2:-}" in
  'init genesis')
    cat >"$genesis" <<'JSON'
{"chain_id":"old","genesis_time":"2000-01-01T00:00:00Z","app_state":{"bank":{"balances":[]},"inference":{"participant_list":[],"model_list":[{"id":"Qwen/Qwen3-0.6B","hf_repo":"Qwen/Qwen3-0.6B","hf_commit":"default","v_ram":"8","throughput_per_nonce":"1","units_of_compute_per_token":"1"}],"params":{"epoch_params":{"epoch_length":"70","epoch_shift":"0","confirmation_poc_safety_window":"10"},"poc_params":{"model_id":"Qwen/Qwen3-0.6B","seq_len":"1024","poc_v2_enabled":true,"confirmation_poc_v2_enabled":true,"models":[{"model_id":"Qwen/Qwen3-0.6B","seq_len":"1024"}]},"confirmation_poc_params":{"expected_confirmations_per_epoch":"1","slash_fraction":{"value":"0","exponent":0},"upgrade_protection_window":"20"},"devshard_escrow_params":{"allowed_creator_addresses":[],"approved_versions":[]},"genesis_guardian_params":{"guardian_addresses":[]}},"genesis_only_params":{"genesis_guardian_enabled":false,"genesis_guardian_addresses":[]}}},"genesis":{"gen_txs":[]}}
JSON
    ;;
  'keys show') printf '%s\n' 'gonkavaloper1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ;;
  'genesis add-genesis-account')
    jq --arg address "$3" --arg amount "$4" '.app_state.bank.balances += [{address:$address,coins:[{denom:"ngonka",amount:($amount|sub("ngonka$";""))}]}]' "$genesis" >"$genesis.next"
    mv "$genesis.next" "$genesis" ;;
  'genesis gentx')
    jq '.app_state.inference.participant_list=[{"address":"gonka1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}] | .app_state.genutil.gen_txs=[{"body":{"messages":[{"@type":"/cosmos.staking.v1beta1.MsgCreateValidator"}]}}]' "$genesis" >"$genesis.next"
    mv "$genesis.next" "$genesis" ;;
  'genesis collect-gentxs') ;;
  'genesis patch-genesis')
    # Reproduce the pinned CLI stage that rebuilds state and omits imported
    # native registry and consensus fields; the builder must restore overlay.
    jq 'del(.app_state.inference.devshard_approved_versions) | del(.consensus.params)' "$genesis" >"$genesis.next"
    mv "$genesis.next" "$genesis" ;;
  'genesis validate-genesis')
    jq -e 'all(.app_state.inference.model_list[]; .proposed_by == "genesis")' "$genesis" >/dev/null || {
      echo 'Core InitGenesis rejects model metadata unless proposed_by is genesis' >&2
      exit 96
    }
    if [[ "${MOCK_CORRUPT_MODEL:-false}" == true ]]; then
      jq '.app_state.inference.model_list[0].hf_commit="mismatch"' "$genesis" >"$genesis.next"
      mv "$genesis.next" "$genesis"
    fi
    ;;
  *) echo "unexpected mocked CLI call: $*" >&2; exit 97 ;;
esac
MOCK
chmod +x "$mock"

gdc="$tmp/gdc"; state="$gdc/state"
mkdir -p "$gdc/accounts" "$state/identities" "$tmp/secrets"
printf '%s\n' operator-password >"$tmp/secrets/operator.keyring"
printf '%s\n' '{"address":"gonka1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' >"$gdc/accounts/genesis-cold.json"
printf '%s\n' '{"address":"gonka1cccccccccccccccccccccccccccccccccccccccc"}' >"$gdc/accounts/gdc-gateway-cold.json"
printf '%s\n' '{"address":"gonka1dddddddddddddddddddddddddddddddddddddddd"}' >"$gdc/accounts/gdc-faucet-cold.json"
printf '%s\n' '{"node_id":"0123456789abcdef0123456789abcdef01234567","consensus_pubkey":"fixture","warm_address":"gonka1eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}' >"$state/identities/genesis.json"
printf '%s\n' 'GENESIS_NODE=genesis' 'GENESIS_PUBLIC_HOST=genesis.example.test' 'GENESIS_P2P_PORT=5000' 'CHAIN_ID=gonka-fixture' >"$tmp/inventory.env"

run_builder() {
  local name="$1"; shift
  env -i PATH="$PATH" GDC_HOME="$gdc" INFERENCED_HOME="$state/operator-home" GDC_GENESIS_INFERENCED_CLI="$mock" \
    GDC_RELEASE_PROFILE=v2026.07.23 GDC_DEPLOYMENT_PROFILE=community-lab GENESIS_V_RAM=8 GENESIS_THROUGHPUT_PER_NONCE=1 \
    GENESIS_UNITS_OF_COMPUTE_PER_TOKEN=1 GENESIS_SEQ_LEN=1024 GDC_GENESIS_GUARDIAN_ENABLED="${TEST_GUARDIAN:-false}" \
    MOCK_CORRUPT_MODEL="${MOCK_CORRUPT_MODEL:-false}" \
    bash "$build" --inventory "$tmp/inventory.env" --identities-dir "$state/identities" --secrets-dir "$tmp/secrets" \
      --genesis-time 2099-01-01T00:00:00Z --output-dir "$tmp/$name" --candidate-only "$@"
}
run_builder default
[[ ! -e "$gdc/genesis" ]] || { echo 'candidate-only build installed into GDC genesis directory' >&2; exit 1; }
jq -e '[.app_state.inference.model_list[].id] == ["Qwen/Qwen3-0.6B"]' "$tmp/default/genesis.json" >/dev/null
jq -e '.genesis_config_sha256 == ""' "$tmp/default/ceremony-record.json" >/dev/null

registry='[{"name":"v4.1","binary":"https://example.test/devshard-v4.1.zip","sha256":"1111111111111111111111111111111111111111111111111111111111111111"},{"name":"v4.2","binary":"https://example.test/devshard-v4.2.zip","sha256":"2222222222222222222222222222222222222222222222222222222222222222"},{"name":"v6","binary":"https://example.test/devshard-v6.zip","sha256":"6666666666666666666666666666666666666666666666666666666666666666"}]'
jq -n --argjson registry "$registry" '{app_state:{gov:{params:{voting:{voting_period:"72h"}}},inference:{devshard_approved_versions:$registry,params:{devshard_escrow_params:{allowed_creator_addresses:["gonka1ffffffffffffffffffffffffffffffffffffffff"],approved_versions:["v9"]},poc_params:{model_id:"Qwen/Qwen2.5-7B-Instruct",models:[{model_id:"Qwen/Qwen2.5-7B-Instruct",seq_len:"8192"},{model_id:"Qwen/Qwen3-4B-Instruct-2507",seq_len:"8192"}]},confirmation_poc_params:{expected_confirmations_per_epoch:"3"}},model_list:[{proposed_by:"legacy-uploader",id:"Qwen/Qwen2.5-7B-Instruct",hf_repo:"Qwen/Qwen2.5-7B-Instruct",hf_commit:"abc",v_ram:"16",throughput_per_nonce:"4",units_of_compute_per_token:"1"},{proposed_by:"operator-account",id:"Qwen/Qwen3-4B-Instruct-2507",hf_repo:"Qwen/Qwen3-4B-Instruct-2507",hf_commit:"def",v_ram:"8",throughput_per_nonce:"8",units_of_compute_per_token:"1"}]}},consensus_params:{block:{max_bytes:"123"}}}' >"$tmp/config.json"
run_builder imported --config-file "$tmp/config.json"
jq -e --argjson registry "$registry" '[.app_state.inference.model_list[].id] == ["Qwen/Qwen2.5-7B-Instruct","Qwen/Qwen3-4B-Instruct-2507"] and [.app_state.inference.model_list[].proposed_by] == ["genesis","genesis"] and .app_state.gov.params.voting.voting_period == "72h" and .app_state.inference.params.devshard_escrow_params.approved_versions == ["v9"] and .app_state.inference.devshard_approved_versions == $registry and .consensus.params.block.max_bytes == "123"' "$tmp/imported/genesis.json" >/dev/null
expected_config_hash="$(sha256sum "$tmp/config.json" | awk '{print $1}')"
jq -e --arg hash "$expected_config_hash" '.genesis_config_sha256 == $hash' "$tmp/imported/ceremony-record.json" >/dev/null

if MOCK_CORRUPT_MODEL=true run_builder mismatch --config-file "$tmp/config.json" >/dev/null 2>&1; then echo 'mismatch unexpectedly passed' >&2; exit 1; fi
[[ ! -e "$tmp/mismatch/genesis.json" && ! -e "$tmp/mismatch/ceremony-record.json" ]] || { echo 'mismatch wrote output artifacts' >&2; exit 1; }
jq '.app_state.inference.devshard_approved_versions={"params":{"devshard_approved_versions":[]}}' "$tmp/config.json" >"$tmp/bad-registry.json"
if run_builder bad-registry --config-file "$tmp/bad-registry.json" >/dev/null 2>&1; then echo 'invalid registry unexpectedly passed' >&2; exit 1; fi
[[ ! -e "$tmp/bad-registry/genesis.json" && ! -e "$tmp/bad-registry/ceremony-record.json" ]] || { echo 'invalid registry wrote output artifacts' >&2; exit 1; }
if [[ -n "${GDC_TEST_IMPORTED_CONFIG:-}" ]]; then
  run_builder pinned-config --config-file "$GDC_TEST_IMPORTED_CONFIG"
  jq -e --slurpfile imported "$GDC_TEST_IMPORTED_CONFIG" '
    .app_state.inference.devshard_approved_versions == $imported[0].app_state.inference.devshard_approved_versions
    and .consensus.params == $imported[0].consensus_params
    and all(.app_state.inference.model_list[]; .proposed_by == "genesis")
  ' "$tmp/pinned-config/genesis.json" >/dev/null
fi
echo 'Genesis config builder tests: PASS'
