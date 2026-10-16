#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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
export MODEL_REGISTRY='{"model":[{"id":"Qwen/Qwen3-0.6B","hf_repo":"Qwen/Qwen3-0.6B","hf_commit":"c1899de289a04d12100db370d81485cdf75e47ca"}]}'
select_model() {
  bash "$ROOT/scripts/select-join-model-profile.sh" --bootstrap-file "$tmp/bootstrap.json" \
    --accelerator-receipt "$tmp/accelerator.json" --model-id Qwen/Qwen3-0.6B --output "$tmp/selection.json" "$@"
}
printf '%s\n' '{"vendor":"nvidia","vram_mib":24564}' >"$tmp/accelerator.json"
select_model
jq -e '.selected.model_id == "Qwen/Qwen3-0.6B" and .hardware.vram_checked and .hardware.vram_mib == 24564' "$tmp/selection.json" >/dev/null
candidate_id="$(jq -er '.selection_id | select(test("^[a-f0-9]{64}$"))' "$tmp/selection.json")"
select_model
[[ "$(jq -r .selection_id "$tmp/selection.json")" == "$candidate_id" ]]
jq -e '.selected.source_id == "Qwen/Qwen3-0.6B" and .selected.source_revision == "c1899de289a04d12100db370d81485cdf75e47ca"' "$tmp/selection.json" >/dev/null
printf '%s\n' '{"vendor":"nvidia","vram_mib":1}' >"$tmp/accelerator.json"
if select_model >"$tmp/out" 2>"$tmp/err"; then exit 1; fi
grep -q 'join_model_selection_profile_unavailable:' "$tmp/err"
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
printf 'PASS model selection checks registry identity and VRAM, plans leave hardware unverified\n'
