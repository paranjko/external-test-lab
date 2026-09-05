#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

# Checked-in lineage examples are contract fixtures, not templates that tests
# may silently normalize. Validate and consume both the supported state-sync
# receipt and the explicit historical-replay refusal directly.
python3 - "$ROOT/lineage/join-lineage-preflight.v1.schema.json" \
  "$ROOT/test/fixtures/join-lineage-preflight-state-sync.json" \
  "$ROOT/test/fixtures/join-lineage-preflight-unsupported-replay.json" <<'PY'
import json
import sys
from jsonschema import Draft202012Validator

with open(sys.argv[1], encoding="utf-8") as schema_file:
    schema = json.load(schema_file)
validator = Draft202012Validator(schema)
for fixture_name in sys.argv[2:]:
    with open(fixture_name, encoding="utf-8") as fixture_file:
        fixture = json.load(fixture_file)
    errors = sorted(validator.iter_errors(fixture), key=lambda error: list(error.path))
    if errors:
        raise SystemExit(f"schema rejected checked-in fixture {fixture_name}: {errors[0].message}")
PY
jq -e '.bootstrap.mode == "state_sync" and .result.terminal_state == "prepared"' \
  "$ROOT/test/fixtures/join-lineage-preflight-state-sync.json" >/dev/null
jq -e '.bootstrap.mode == "historical_replay" and .result.category == "historical_replay_unsupported" and .result.terminal_state == "refused"' \
  "$ROOT/test/fixtures/join-lineage-preflight-unsupported-replay.json" >/dev/null

cat >"$tmp/bootstrap.json" <<'EOF'
{"$schema":"https://gonka-dev.net/v1.bootstrap.schema.json","chain_id":"gonka-fixture","genesis":{"sha256":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"},"seeds":[{"node_id":"0123456789abcdef0123456789abcdef01234567","rpc":"https://rpc-a.example.test/chain-rpc","p2p":"tcp://rpc-a.example.test:5000","api":"https://rpc-a.example.test"},{"node_id":"89abcdef0123456789abcdef0123456789abcdef","rpc":"https://rpc-b.example.test/chain-rpc","p2p":"tcp://rpc-b.example.test:5000","api":"https://rpc-b.example.test"}],"brokers":[]}
EOF
jq -n --arg bootstrap_sha "$(sha256sum "$tmp/bootstrap.json" | awk '{print $1}')" '
  {schema_version:1,kind:"gdc-network-observation",network_state_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",expires_at:"2999-01-01T00:00:00Z",bootstrap:{document_sha256:$bootstrap_sha,chain_id:"gonka-fixture",genesis_sha256:"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"},runtime:{core:{version:"0.2.15",commit:"4d687ed6782bcea3931d2d9135bf322f84e190ab"},dapi:{version:"0.2.15-post3",commit:"5dbb53ddf3ddc42655fc04dc39d96003169bdbb0"}},runtime_api_origins:[{api_url:"https://rpc-a.example.test"}],result:{state:"ready",reason:"none"}}' >"$tmp/observation.json"
mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${!#}"
printf '%s\n' "$url" >>"${CURL_SPY:-/dev/null}"
block() {
  local height="$1" block app
  case "$height" in
    5) block=1111111111111111111111111111111111111111111111111111111111111111; app=2222222222222222222222222222222222222222222222222222222222222222 ;;
    5000) block=7777777777777777777777777777777777777777777777777777777777777777; app=8888888888888888888888888888888888888888888888888888888888888888 ;;
    3000) block=3333333333333333333333333333333333333333333333333333333333333333; app=4444444444444444444444444444444444444444444444444444444444444444 ;;
    101) block=5555555555555555555555555555555555555555555555555555555555555555; app=6666666666666666666666666666666666666666666666666666666666666666 ;;
    *) exit 22 ;;
  esac
  printf '{"result":{"block_id":{"hash":"%s"},"block":{"header":{"height":"%s","app_hash":"%s"}}}}\n' "$block" "$height" "$app"
}
case "$url" in
  */status) printf '%s\n' '{"result":{"node_info":{"network":"gonka-fixture"},"sync_info":{"latest_block_height":"5000"}}}' ;;
  */last_upgrade_height) printf '%s\n' '{"lastUpgradeHeight":"100","found":true}' ;;
  */chain-api/productscience/inference/inference/params)
    printf '%s\n' '{"params":{"devshard_escrow_params":{"approved_versions":[{"name":"v3","binary":"https://example.test/devshard-v3.zip","sha256":"3333333333333333333333333333333333333333333333333333333333333333"},{"name":"v4","binary":"https://example.test/devshard-v4.zip","sha256":"4444444444444444444444444444444444444444444444444444444444444444"},{"name":"v5","binary":"https://example.test/devshard-v5.zip","sha256":"5555555555555555555555555555555555555555555555555555555555555555"}]}}}'
    ;;
  */block?height=*) block "${url##*=}" ;;
  */snapshots)
    [[ "${GDC_TEST_NO_SNAPSHOT:-false}" != true ]] || exit 22
    printf '%s\n' '{"result":{"snapshots":[{"height":200,"format":1,"chunks":2,"hash":"7777777777777777777777777777777777777777777777777777777777777777"}]}}'
    ;;
  *) exit 22 ;;
esac
EOF
chmod 0755 "$tmp/bin/curl"

run_preflight() {
  PATH="$tmp/bin:$PATH" CURL_SPY="$tmp/curl-spy" GDC_JOIN_FAULT_DOMAIN_MAP='rpc-a.example.test=domain-a,rpc-b.example.test=domain-b' \
    "$ROOT/scripts/preflight-join-lineage.sh" --bootstrap-file "$tmp/bootstrap.json" --observation "$tmp/observation.json" --receipt "$tmp/receipt.json" --env "$tmp/lineage.env"
}
run_preflight >"$tmp/out"
grep -Fqx 'https://rpc-a.example.test/chain-api/productscience/inference/inference/last_upgrade_height' "$tmp/curl-spy"
grep -Fqx 'https://rpc-a.example.test/chain-api/productscience/inference/inference/params' "$tmp/curl-spy"
grep -Fqx 'https://rpc-b.example.test/chain-api/productscience/inference/inference/params' "$tmp/curl-spy"
jq -e '
  .runtime.source.kind == "network_observation" and
  .runtime.observation_sha256 == "'"$(sha256sum "$tmp/observation.json" | awk '{print $1}')"'" and
  .runtime.core == {version:"0.2.15",commit:"4d687ed6782bcea3931d2d9135bf322f84e190ab"} and
  .bootstrap.mode == "state_sync" and
  .bootstrap.snapshot.discovery == "p2p_canary_pending" and
  (.bootstrap.snapshot.providers | length == 2) and
  (.fault_domains | length == 2) and .signer.state == "PREPARED" and
  (.devshard_compatibility.approvals | map(.name) == ["v3","v4","v5"]) and
  (.devshard_compatibility.sources | length == 2) and
  .result.terminal_state == "prepared"
' "$tmp/receipt.json" >/dev/null
# The receipt producer and the published schema are one contract.  Validate
# both the initial receipt and the canary-mutated receipt in their dedicated
# tests so a future closed-schema drift fails locally.
python3 - "$ROOT/lineage/join-lineage-preflight.v1.schema.json" "$tmp/receipt.json" <<'PY'
import json
import sys
from jsonschema import Draft202012Validator

with open(sys.argv[1], encoding="utf-8") as schema_file, open(sys.argv[2], encoding="utf-8") as receipt_file:
    schema = json.load(schema_file)
    receipt = json.load(receipt_file)
errors = sorted(Draft202012Validator(schema).iter_errors(receipt), key=lambda error: list(error.path))
if errors:
    raise SystemExit("schema rejected generated receipt: " + errors[0].message)
PY
grep -qx 'GDC_JOIN_BOOTSTRAP_MODE=state_sync' "$tmp/lineage.env"
grep -qx 'GDC_JOIN_RPC_SERVER_1=https://rpc-a.example.test/chain-rpc/' "$tmp/lineage.env"
# shellcheck source=/dev/null
source "$tmp/lineage.env"
[[ "$GDC_JOIN_SNAPSHOT_PEERS" == '0123456789abcdef0123456789abcdef01234567@tcp://rpc-a.example.test:5000,89abcdef0123456789abcdef0123456789abcdef@tcp://rpc-b.example.test:5000' ]]
jq -e 'keys == ["v3","v4","v5"] and .v4.binary == "https://example.test/devshard-v4.zip"' \
  <<<"$GDC_JOIN_GATEWAY_ADMISSION_PROTOCOLS_JSON" >/dev/null

if PATH="$tmp/bin:$PATH" GDC_JOIN_FAULT_DOMAIN_MAP='rpc-a.example.test=one,rpc-b.example.test=one' \
  "$ROOT/scripts/preflight-join-lineage.sh" --bootstrap-file "$tmp/bootstrap.json" --observation "$tmp/observation.json" --receipt "$tmp/alias.json" --env "$tmp/alias.env" >"$tmp/alias.out" 2>"$tmp/alias.err"; then
  echo 'two aliases for one RPC fault domain unexpectedly passed' >&2; exit 1
fi
grep -Fq 'lineage_rpc_fault_domain_alias:' "$tmp/alias.err"

PATH="$tmp/bin:$PATH" GDC_TEST_NO_SNAPSHOT=true GDC_JOIN_FAULT_DOMAIN_MAP='rpc-a.example.test=domain-a,rpc-b.example.test=domain-b' \
  "$ROOT/scripts/preflight-join-lineage.sh" --bootstrap-file "$tmp/bootstrap.json" --observation "$tmp/observation.json" --receipt "$tmp/no-http.json" --env "$tmp/no-http.env" >"$tmp/no-http.out"
jq -e '.bootstrap.snapshot.discovery == "p2p_canary_pending"' "$tmp/no-http.json" >/dev/null
expired="$tmp/expired-observation.json"
jq '.expires_at = "2000-01-01T00:00:00Z"' "$tmp/observation.json" >"$expired"
if PATH="$tmp/bin:$PATH" GDC_JOIN_FAULT_DOMAIN_MAP='rpc-a.example.test=domain-a,rpc-b.example.test=domain-b' \
  "$ROOT/scripts/preflight-join-lineage.sh" --bootstrap-file "$tmp/bootstrap.json" --observation "$expired" --receipt "$tmp/expired.json" --env "$tmp/expired.env" >"$tmp/expired.out" 2>"$tmp/expired.err"; then
  echo 'expired observation unexpectedly passed' >&2; exit 1
fi
grep -Fq 'lineage_observation_expired:' "$tmp/expired.err"
printf 'PASS JOIN lineage preflight requires independent RPCs and defers snapshot discovery to P2P\n'
