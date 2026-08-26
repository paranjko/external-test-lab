#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

runbook="$tmp/runbook"
home="$tmp/home"
fake_bin="$tmp/bin"
candidate=v2026.08.25-rc.0
source_profile=v2026.08.06
mkdir -p "$fake_bin" "$home/receipts/gate-b" "$home/state/lineage"
cp -a "$ROOT" "$runbook"
cp "$runbook/profiles/releases/$source_profile.lock" \
  "$runbook/profiles/releases/$candidate.lock"
cat >>"$runbook/profiles/releases/$candidate.lock" <<'EOF'
LAB_CANDIDATE=true
UPGRADE_FROM_PROFILE=v2026.08.06
CANDIDATE_DEVSHARD_SOURCE_REF=refs/heads/release/devshard-v5
CANDIDATE_DEVSHARD_COMMIT=1111111111111111111111111111111111111111
CANDIDATE_DEVSHARD_PROTOCOL_VERSION=v5
CANDIDATE_DEVSHARD_SUPPORTED_PROTOCOLS='v3 v5'
CANDIDATE_LOCAL_GATEWAY_IMAGE=devshard-gateway:test
CANDIDATE_POSTGRES_IMAGE=postgres:16-alpine
EOF

genesis="$tmp/genesis.json"
cat >"$genesis" <<'EOF'
{"chain_id":"gonka-devnet-community","app_state":{"inference":{"params":{"confirmation_poc_params":{"upgrade_protection_window":"1"}}}}}
EOF
genesis_hash="$(GDC_HOME="$home" bash -c 'source "$1/scripts/lib.sh"; genesis_sha256 "$2"' _ "$runbook" "$genesis")"

jq -n --arg hash "$genesis_hash" --arg profile "$source_profile" \
  '{verdict:"PASS",genesis_sha256:$hash,effective_validator_count:5,release_profile:$profile}' \
  >"$home/receipts/gate-b/receipt.json"
jq -n --arg hash "$genesis_hash" \
  '{schema_version:1,chain_id:"gonka-devnet-community",genesis_sha256:$hash,
    participants:[{address:"gonka1fixture",validator_key:"fixture-key",
      runtime_id:"qwen3-0.6b:gonka1fixture",public_host:"node.example"}]}' \
  >"$home/state/lineage/current-topology.json"

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output=''
write_status=false
url="${!#}"
while (( $# > 0 )); do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    -w) write_status=true; shift 2 ;;
    *) shift ;;
  esac
done
case "$url" in
  */chain-rpc/genesis)
    payload='{"result":{"genesis":{"chain_id":"gonka-devnet-community","app_state":{"inference":{"params":{"confirmation_poc_params":{"upgrade_protection_window":"1"}}}}}}}'
    ;;
  */chain-rpc/status)
    payload='{"result":{"sync_info":{"latest_block_height":"20"}}}'
    ;;
  */v1/versions)
    payload="{\"node_version\":{\"version\":\"${GONKA_RELEASE:?}\",\"commit\":\"${GONKA_COMMIT:?}\"}}"
    ;;
  *) payload='{}' ;;
esac
if [[ -n "$output" ]]; then
  printf '%s\n' "$payload" >"$output"
else
  printf '%s\n' "$payload"
fi
[[ "$write_status" == false ]] || printf '200'
EOF
chmod +x "$fake_bin/curl"

cat >"$runbook/scripts/verify-upgrade-proposal-binding.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '10\n'
EOF
chmod +x "$runbook/scripts/verify-upgrade-proposal-binding.sh"

cat >"$runbook/scripts/phase-public-network-verify.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
run="$GDC_HOME/runs/$GDC_RUN_ID/public-network-verify"
mkdir -p "$run"
jq -n --arg profile "$GDC_RELEASE_PROFILE" \
  '{schema_version:1,verdict:"PASS",release_profile:$profile}' >"$run/receipt.json"
EOF
chmod +x "$runbook/scripts/phase-public-network-verify.sh"

expected_release="$(awk -F= '$1 == "GONKA_RELEASE" {print $2; exit}' "$runbook/profiles/releases/$candidate.lock")"
expected_commit="$(awk -F= '$1 == "GONKA_COMMIT" {print $2; exit}' "$runbook/profiles/releases/$candidate.lock")"
PATH="$fake_bin:$PATH" GDC_HOME="$home" \
  GDC_CHAIN_PUBLIC_BASE=https://chain.example GONKA_RELEASE="$expected_release" \
  GONKA_COMMIT="$expected_commit" \
  "$runbook/gdc.sh" --release "$candidate" network upgrade verify 7 \
  >"$tmp/stdout" 2>"$tmp/stderr"

run_id="$(<"$home/state/active-run-id")"
manifest="$home/runs/$run_id/manifest.env"
lineage="$home/runs/$run_id/public-upgrade-verify-7/lineage.env"
receipt="$home/runs/$run_id/public-upgrade-verify-7/receipt.json"
grep -qx "release_profile=$candidate" "$manifest"
grep -qx "release_profile=$candidate" "$lineage"
jq -e --arg candidate "$candidate" --arg source "$source_profile" '
  .verdict == "PASS" and .verification_scope == "cosmovisor-binaries"
  and .upgrade_target_profile == $candidate and .gate_b_release_profile == $source
' "$receipt" >/dev/null
grep -Fq 'PASS public upgrade verification scope=cosmovisor-binaries' "$tmp/stdout"
! grep -Fq 'run manifest belongs to another release profile' "$tmp/stderr"

printf 'PASS candidate CLI loads its lock and preserves outer evidence identity\n'
