#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRODUCT_ROOT="$ROOT"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"
mkdir -p "$tmp/fixture/net-deployment-runbook/scripts" "$tmp/fixture/model"
cp "$ROOT/scripts/select-join-model-profile.sh" "$ROOT/scripts/network-bootstrap.sh" "$tmp/fixture/net-deployment-runbook/scripts/"
cp "$ROOT/../model/"*.lock "$tmp/fixture/model/"
ROOT="$tmp/fixture/net-deployment-runbook"
cat >"$tmp/bootstrap.json" <<'EOF'
{"$schema":"https://gonka-dev.net/v1.bootstrap.schema.json","chain_id":"fixture","genesis":{"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"seeds":[{"node_id":"0123456789abcdef0123456789abcdef01234567","rpc":"https://node.example.test/chain-rpc","p2p":"tcp://node.example.test:5000","api":"https://node.example.test"},{"node_id":"89abcdef0123456789abcdef0123456789abcdef","rpc":"https://node2.example.test/chain-rpc","p2p":"tcp://node2.example.test:5000","api":"https://node2.example.test"}],"brokers":[]}
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${!#}" == https://node.example.test/chain-api/productscience/inference/inference/models_all ]] || exit 97
printf '%s\n' "${MODEL_REGISTRY:?}"
EOF
chmod 0755 "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH"
export MODEL_REGISTRY='{"model":[{"id":"Qwen/Qwen3-0.6B","hf_repo":"Qwen/Qwen3-0.6B","hf_commit":"c1899de289a04d12100db370d81485cdf75e47ca"},{"id":"Qwen/Qwen2.5-7B-Instruct","hf_repo":"Qwen/Qwen2.5-7B-Instruct","hf_commit":"a09a35458c702b33eeacc393d103063234e8bc28"},{"id":"Qwen/Qwen3-4B-Instruct-2507","hf_repo":"Qwen/Qwen3-4B-Instruct-2507","hf_commit":"cdbee75f17c01a7cc42f958dc650907174af0554"}]}'
select_model() {
  bash "$ROOT/scripts/select-join-model-profile.sh" --bootstrap-file "$tmp/bootstrap.json" \
    --accelerator-receipt "$tmp/accelerator.json" --model-id "$model_id" --output "$tmp/selection.json" "$@"
}
printf '%s\n' '{"vendor":"nvidia","vram_mib":24564}' >"$tmp/accelerator.json"
model_id='Qwen/Qwen3-0.6B'
select_model
jq -e '.selected.profile == "qwen3-0.6b-devnet" and .selected.model_id == "Qwen/Qwen3-0.6B" and .selected.minimum_vram_mib == 15360 and .hardware.vram_checked and .hardware.vram_mib == 24564' "$tmp/selection.json" >/dev/null
candidate_id="$(jq -er '.selection_id | select(test("^[a-f0-9]{64}$"))' "$tmp/selection.json")"
select_model
[[ "$(jq -r .selection_id "$tmp/selection.json")" == "$candidate_id" ]]
jq -e '.selected.source_id == "Qwen/Qwen3-0.6B" and .selected.source_revision == "c1899de289a04d12100db370d81485cdf75e47ca"' "$tmp/selection.json" >/dev/null
mv "$tmp/fixture/model/qwen3-0.6b-devnet.lock" "$tmp/0.6b-network.lock"
select_model
jq -e '.selected.profile == "qwen3-0.6b" and .selected.minimum_vram_mib == 16384' "$tmp/selection.json" >/dev/null
cp "$tmp/0.6b-network.lock" "$tmp/fixture/model/qwen3-0.6b-devnet.lock"
cp "$tmp/0.6b-network.lock" "$tmp/fixture/model/qwen3-0.6b-devnet-duplicate.lock"
if select_model >"$tmp/out" 2>"$tmp/err"; then exit 1; fi
grep -q 'join_model_selection_profile_ambiguous:' "$tmp/err"
rm -f "$tmp/fixture/model/qwen3-0.6b-devnet-duplicate.lock"
printf '%s\n' '{"vendor":"nvidia","vram_mib":1}' >"$tmp/accelerator.json"
if select_model >"$tmp/out" 2>"$tmp/err"; then exit 1; fi
grep -q 'join_model_selection_profile_unavailable:' "$tmp/err"
printf '%s\n' '{"vendor":"nvidia","vram_mib":15360}' >"$tmp/accelerator.json"
select_model
jq -e '.selected.profile == "qwen3-0.6b-devnet" and .selected.minimum_vram_mib == 15360 and .hardware.vram_mib == 15360' "$tmp/selection.json" >/dev/null
printf '%s\n' '{"vendor":"nvidia","vram_mib":15359}' >"$tmp/accelerator.json"
if select_model >"$tmp/out" 2>"$tmp/err"; then exit 1; fi
grep -q 'join_model_selection_profile_unavailable:' "$tmp/err"
printf '%s\n' '{"vendor":"nvidia","vram_mib":24564}' >"$tmp/accelerator.json"
model_id='Qwen/Qwen2.5-7B-Instruct'
select_model
jq -e '.selected.profile == "qwen2.5-7b-instruct-devnet" and .selected.model_id == "Qwen/Qwen2.5-7B-Instruct"' "$tmp/selection.json" >/dev/null
model_id='Qwen/Qwen3-4B-Instruct-2507'
select_model
jq -e '.selected.profile == "qwen3-4b-instruct-2507-devnet" and .selected.model_id == "Qwen/Qwen3-4B-Instruct-2507"' "$tmp/selection.json" >/dev/null
mv "$tmp/fixture/model/qwen3-4b-instruct-2507-devnet.lock" "$tmp/4b-network.lock"
if select_model >"$tmp/out" 2>"$tmp/err"; then exit 1; fi
grep -q 'join_model_selection_profile_unavailable:' "$tmp/err"
cp "$tmp/4b-network.lock" "$tmp/fixture/model/qwen3-4b-instruct-2507-devnet.lock"
cp "$tmp/4b-network.lock" "$tmp/fixture/model/qwen3-4b-instruct-2507-duplicate.lock"
if select_model >"$tmp/out" 2>"$tmp/err"; then exit 1; fi
grep -q 'join_model_selection_profile_ambiguous:' "$tmp/err"
rm -f "$tmp/fixture/model/qwen3-4b-instruct-2507-duplicate.lock"
model_id='Qwen/Qwen3-0.6B'
printf '%s\n' '{"vendor":"nvidia","vram_mib":null,"inspection_state":"not_checked"}' >"$tmp/accelerator.json"
if select_model >"$tmp/out" 2>"$tmp/err"; then exit 1; fi
grep -q 'join_model_selection_hardware:' "$tmp/err"
select_model --plan
jq -e '.hardware.vram_mib == null and .hardware.vram_checked == false' "$tmp/selection.json" >/dev/null
MODEL_REGISTRY='{"model":[{"id":"Qwen/Qwen3-0.6B","hf_repo":"Qwen/Qwen3-0.6B","hf_commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}'
if select_model --plan >"$tmp/out" 2>"$tmp/err"; then exit 1; fi
grep -q 'join_model_selection_profile_unavailable:' "$tmp/err"
sed -i 's/c1899de289a04d12100db370d81485cdf75e47ca/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/g' "$tmp/fixture/model/"*.lock
select_model --plan
[[ "$(jq -er .selection_id "$tmp/selection.json")" != "$candidate_id" ]]
MODEL_REGISTRY='{"model":[{"id":"unknown","hf_repo":"unknown","hf_commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}'
if select_model --plan >"$tmp/out" 2>"$tmp/err"; then exit 1; fi
grep -q 'join_model_selection_model_not_registered:' "$tmp/err"
for profile in qwen3-0.6b qwen3-0.6b-devnet qwen2.5-7b-instruct-devnet qwen3-4b-instruct-2507-devnet; do
  "$PRODUCT_ROOT/scripts/render-genesis-software.sh" "$profile" "$tmp/$profile.fragment.json" >/dev/null
  fresh_software="$(jq -c '.spec.deployment.software' "$tmp/$profile.fragment.json")"
  jq --argjson fresh "$fresh_software" '
    .software.platform=$fresh.platform |
    .software.accelerator=$fresh.accelerator |
    .software.deployment=$fresh.deployment |
    .software.components.node=$fresh.components.node |
    .software.components.api=$fresh.components.api |
    .software.components.tmkms=$fresh.components.tmkms |
    .software.components.mlnode=$fresh.components.mlnode |
    .software.operator_cli=$fresh.operator_cli |
    .software.model=$fresh.model
  ' "$PRODUCT_ROOT/../bootstrap/gonka-devnet-community.json" >"$tmp/$profile.full-bootstrap.json"
  jq -e --slurpfile fresh "$tmp/$profile.fragment.json" '
    .software.components as $c | $fresh[0].container_images as $i |
    $c["edge-api"].image == $i.edge_api and
    $c.bridge.image == $i.bridge and
    $c.caddy.image == $i.caddy and
    $c.cadvisor.image == $i.cadvisor and
    $c.explorer.image == $i.explorer and
    $c.grafana.image == $i.grafana and
    $c["inference-proxy"].image == $i.inference_proxy and
    $c["node-exporter"].image == $i.node_exporter and
    $c["payload-postgres"].image == $i.payload_postgres and
    $c.proxy.image == $i.proxy and
    $c["proxy-policy"].image == $i.proxy_policy and
    $c.versiond.image == $i.versiond and
    $c["versiond-router"].image == $i.versiond_router
  ' "$tmp/$profile.full-bootstrap.json" >/dev/null
  jq -e -f "$PRODUCT_ROOT/scripts/bootstrap-join-software.jq" \
    "$tmp/$profile.full-bootstrap.json" >/dev/null
done
jq '.software.model.context_length += 1' "$tmp/qwen2.5-7b-instruct-devnet.full-bootstrap.json" \
  | jq -e -f "$PRODUCT_ROOT/scripts/bootstrap-join-software.jq" >/dev/null && exit 1
jq '.software.model.max_num_seqs = 33' "$tmp/qwen3-0.6b-devnet.full-bootstrap.json" \
  | jq -e -f "$PRODUCT_ROOT/scripts/bootstrap-join-software.jq" >/dev/null && exit 1
jq '.software.model.gpu_memory_utilization = 0.46' "$tmp/qwen3-0.6b-devnet.full-bootstrap.json" \
  | jq -e -f "$PRODUCT_ROOT/scripts/bootstrap-join-software.jq" >/dev/null && exit 1
jq '.software.components.bridge = {}' "$tmp/qwen2.5-7b-instruct-devnet.full-bootstrap.json" \
  | jq -e -f "$PRODUCT_ROOT/scripts/bootstrap-join-software.jq" >/dev/null && exit 1
printf 'PASS model selection checks 0.6B/7B/4B network scope, qualification refusal, registry identity, and VRAM\n'
