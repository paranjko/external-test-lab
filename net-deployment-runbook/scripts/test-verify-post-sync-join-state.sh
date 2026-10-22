#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
remote_base="/tmp/gdc-post-sync-test-$$"
trap 'rm -rf -- "$tmp" "$remote_base" "$remote_base-full-sync-main" "$remote_base-full-sync-resume" "$remote_base-state-sync-main" "$remote_base-wrong-mode" "$remote_base-wrong-seed" "$remote_base-divergent-block"' EXIT
mkdir -p "$tmp/bin" "$remote_base"

profile="$tmp/join-profile.json"
printf '%s\n' '{"spec":{"network":{"chain_id":"gonka-devnet-community","genesis_sha256":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}}}' >"$profile"
profile_sha256="$(sha256sum "$profile" | awk '{print $1}')"
seed_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
join_id=0123456789abcdef0123456789abcdef01234567
block_id=ABCDEF0123456789
app_hash=1234567890ABCDEF

cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${1:-}" == fixture ]] || { echo 'unexpected SSH alias' >&2; exit 41; }
shift
[[ "${1:-}" == bash && "${2:-}" == -s && "${3:-}" == -- ]] || { echo 'unexpected SSH command' >&2; exit 42; }
shift 3
[[ $# == 14 ]] || { echo "unexpected remote argument count: $#" >&2; exit 43; }
node="$1"; generation="$2"; remote="$3"; chain="$4"; p2p="$5"
core_version="$6"; core_commit="$7"; dapi_version="$8"; dapi_commit="$9"
deploy="${10}"; active_data="${11}"; mode="${12}"; output="${13}"; lineage="${14}"
[[ "$node" == fixture && "$remote" == "$GDC_TEST_REMOTE" ]] || exit 44
generation="$GDC_TEST_GENERATION"
deploy="$GDC_TEST_DEPLOY"
active_data="$GDC_TEST_ACTIVE_DATA"
exec bash -s -- "$node" "$generation" "$remote" "$chain" "$p2p" \
  "$core_version" "$core_commit" "$dapi_version" "$dapi_commit" \
  "$deploy" "$active_data" "$mode" "$output" "$lineage"
EOF

cat >"$tmp/bin/scp" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${1:-}" == -q && $# == 3 ]] || exit 51
source_path="$2"; destination="$3"
if [[ "$source_path" == fixture:* ]]; then
  source_path="${source_path#fixture:}"
  [[ -r "$source_path" ]] || exit 52
  cp -- "$source_path" "$destination"
elif [[ "$destination" == fixture:* ]]; then
  destination="${destination#fixture:}"
  mkdir -p "$(dirname "$destination")"
  cp -- "$source_path" "$destination"
else
  exit 53
fi
EOF

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${@: -1}"
if [[ "$url" == */status ]]; then
  if [[ "$url" == https://seed.example.test/chain-rpc/status ]]; then
    seed="${GDC_TEST_SEED_ID:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
    printf '{"result":{"node_info":{"id":"%s","network":"gonka-devnet-community"},"sync_info":{"latest_block_height":"100","catching_up":false}}}\n' "$seed"
  else
    printf '{"result":{"node_info":{"id":"0123456789abcdef0123456789abcdef01234567","network":"gonka-devnet-community"},"sync_info":{"latest_block_height":"100","catching_up":false}}}\n'
  fi
elif [[ "$url" == */block\?height=* ]]; then
  block="$GDC_TEST_BLOCK_ID"
  app_hash="$GDC_TEST_APP_HASH"
  if [[ "$url" == https://seed.example.test/chain-rpc/block\?height=* && "${GDC_TEST_DIVERGE:-false}" == true ]]; then
    block="FEDCBA9876543210"
  fi
  printf '{"result":{"block":{"header":{"height":"100","app_hash":"%s"}},"block_id":{"hash":"%s"}}}\n' "$app_hash" "$block"
else
  echo "unexpected curl URL: $url" >&2
  exit 54
fi
EOF
chmod 0755 "$tmp/bin/ssh" "$tmp/bin/scp" "$tmp/bin/curl"

write_lineage() {
  local destination="$1" mode="$2" valid="${3:-true}"
  mkdir -p "$(dirname "$destination")"
  if [[ "$mode" == full_sync ]]; then
    jq -cn --arg chain gonka-devnet-community --arg seed "$seed_id" --arg join "$join_id" --arg valid "$valid" '
      {schema_version:1,kind:"gdc-host-join-lineage-preflight",
       bootstrap:{mode:"full_sync",chain_id:$chain,genesis_sha256:("d"*64),
         seed:{node_id:$seed,rpc_url:"https://seed.example.test/chain-rpc",p2p:"tcp://seed.example.test:5000"}},
       fault_domains:[{id:"genesis-single-seed",rpc_url:"https://seed.example.test/chain-rpc",host:"seed.example.test",port:443,ip:"192.0.2.10",chain_id:$chain,genesis_sha256:("d"*64)}],
       trust_authority:{kind:(if $valid == "true" then "genesis_single_seed" else "operator_source" end),rpc_url:"https://seed.example.test/chain-rpc"},checkpoints:null}' >"$destination"
  else
    jq -cn --arg chain gonka-devnet-community '
      {schema_version:1,kind:"gdc-host-join-lineage-preflight",
       bootstrap:{mode:"state_sync",chain_id:$chain,trust:{height:50,hash:("e"*64),expires_at:"2999-01-01T00:00:00Z"},
         snapshot:{discovery:"p2p_canary_pending",providers:[{id:"p1"},{id:"p2"}]}},
       fault_domains:[{id:"origin-a",rpc_url:"https://seed.example.test/chain-rpc",host:"seed.example.test",port:443,ip:"192.0.2.10"}],
       trust_authority:{kind:"operator_source",rpc_url:"https://seed.example.test/chain-rpc"},checkpoints:[],
       signer:{state:"PREPARED"},result:{terminal_state:"prepared"}}' >"$destination"
  fi
  chmod 0600 "$destination"
}

write_receipt() {
  local receipts="$1" operation="$2" state="$3" profile_hash="$4" input="$tmp/receipt-input.json"
  mkdir -p "$receipts"
  jq -cn --arg operation "$operation" --arg state "$state" --arg profile "$profile_hash" '
    {schema_version:2,kind:"gdc-host-join-receipt",run_id:"fixture-run",operation:$operation,node_name:"fixture",state:$state,
     join_profile_sha256:$profile,network_observation_sha256:("a"*64),generation_id:"fixture-run",
     identity_fingerprints:{participant_address:"",consensus_pubkey:"",p2p_node_id:"",warm_address:""},
     signer_ever_started:false,tmkms_state:{height:0,round:0,step:0,block_id:""},
     evidence:[],outcome:"in_progress",resume_policy:"resume_same_run"}' >"$input"
  "$ROOT/scripts/record-join-receipt.sh" --receipt-dir "$receipts" --input "$input" >/dev/null
}

write_canary_receipt() {
  local destination="$1"
  jq -cn --arg chain gonka-devnet-community --arg genesis "$(jq -er '.spec.network.genesis_sha256' "$profile")" \
    --arg seed "$seed_id" --arg join "$join_id" '
    {schema_version:1,kind:"gdc-genesis-single-seed-canary",chain_id:$chain,genesis_sha256:$genesis,
     seed_node_id:$seed,seed_rpc:"https://seed.example.test/chain-rpc",join_node_id:$join,
     common_height:99,common_block:{height:99,block_id:"ABCDEF0123456789",app_hash:"1234567890ABCDEF"}}' >"$destination"
}

prepare_remote() {
  local remote="$1" deploy="$2" active_data="$3" generation="$4"
  mkdir -p "$remote" "$deploy"
  mkdir -p "$generation"
  ln -s "$generation" "$active_data"
  jq -n --arg generation "$generation" '{schema_version:1,kind:"gdc-state-sync-promotion",state:"PROMOTED",node_name:"fixture",generation:$generation}' >"$deploy/.promotion-receipt.json"
  cat >"$deploy/verify-canonical-join-state.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 7 && "$1" == "$GDC_TEST_DEPLOY" && "$2" == gonka-devnet-community && "$3" == 0123456789abcdef0123456789abcdef01234567 ]]
printf 'canonical-runtime-verified\n' >>"$GDC_TEST_EVENTS"
EOF
  chmod 0755 "$deploy/verify-canonical-join-state.sh"
  cat >"$remote/verify-join-lineage-state.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 3 && "$1" == http://127.0.0.1:26657 && "$3" == --resume-current ]]
jq -e '.bootstrap.mode == "state_sync"' "$2" >/dev/null
printf 'state-sync-proof-verified\n' >>"$GDC_TEST_EVENTS"
EOF
  chmod 0755 "$remote/verify-join-lineage-state.sh"
}

verify() {
  local run="$1" remote="$2" deploy="$3" active_data="$4" generation="$5" rc=0
  PATH="$tmp/bin:$PATH" GDC_RUN_ID=fixture-run GDC_TEST_REMOTE="$remote" \
    GDC_TEST_DEPLOY="$deploy" GDC_TEST_ACTIVE_DATA="$active_data" GDC_TEST_GENERATION="$generation" \
    GDC_TEST_BLOCK_ID="$block_id" GDC_TEST_APP_HASH="$app_hash" GDC_TEST_EVENTS="$tmp/events" \
    "$ROOT/scripts/verify-post-sync-join-state.sh" \
      --node fixture --run-dir "$run" --profile "$profile" --remote-dir "$remote" \
      --expected-chain-id gonka-devnet-community --expected-p2p-node-id "$join_id" \
      --expected-core-version 0.2.15 --expected-core-commit 1111111111111111111111111111111111111111 \
      --expected-dapi-version 0.2.15-post3 --expected-dapi-commit 2222222222222222222222222222222222222222
}

run_case() {
  local name="$1" mode="$2" operation="$3" resume="$4"
  local run="$tmp/$name/run" receipts="$tmp/$name/run/receipts" remote="$remote_base-$name"
  local deploy="$tmp/$name/deploy" active_data="$tmp/$name/data" generation="$tmp/$name/generation"
  mkdir -p "$run"
  write_lineage "$run/lineage-state-sync-receipt.json" "$mode"
  cp "$run/lineage-state-sync-receipt.json" "$run/lineage-preflight-canary.v1.json"
  if [[ "$mode" == state_sync ]]; then
    jq '.bootstrap.snapshot={discovery:"p2p_canary_caught_up",providers:[{id:"p1"},{id:"p2"}],observed_at:"2026-10-20T12:00:00Z",canary_node_id:"0123456789abcdef0123456789abcdef01234567",canary_height:99} | .signer.state="LINEAGE_VERIFIED" | .result.terminal_state="canary_verified"' \
      "$run/lineage-state-sync-receipt.json" >"$run/lineage-state-sync-receipt.tmp"
    mv "$run/lineage-state-sync-receipt.tmp" "$run/lineage-state-sync-receipt.json"
    [[ "$(sha256sum "$run/lineage-state-sync-receipt.json" | awk '{print $1}')" != "$(sha256sum "$run/lineage-preflight-canary.v1.json" | awk '{print $1}')" ]]
  fi
  prepare_remote "$remote" "$deploy" "$active_data" "$generation"
  cp "$run/lineage-state-sync-receipt.json" "$remote/lineage-receipt.json"
  if [[ "$mode" == full_sync ]]; then write_canary_receipt "$run/genesis-single-seed-canary.json"; fi
  : >"$tmp/events"
  write_receipt "$receipts" "$operation" RUN_CREATED "$profile_sha256"
  write_receipt "$receipts" "$operation" CANARY_VERIFIED "$profile_sha256"
  write_receipt "$receipts" "$operation" PROMOTED "$profile_sha256"
  write_receipt "$receipts" "$operation" CANONICAL_RUNNING "$profile_sha256"
  write_receipt "$receipts" "$operation" APPLICATION_ACTIVE "$profile_sha256"
  if [[ "$resume" == true ]]; then
    write_receipt "$receipts" "$operation" CANONICAL_VERIFIED "$profile_sha256"
    write_receipt "$receipts" "$operation" RECOVERY_ARCHIVE_READY "$profile_sha256"
    write_receipt "$receipts" "$operation" MEMBERSHIP_RECONCILED "$profile_sha256"
  fi
  verify "$run" "$remote" "$deploy" "$active_data" "$generation"
  if [[ "$mode" == full_sync ]]; then
    [[ -s "$tmp/events" && "$(<"$tmp/events")" == *canonical-runtime-verified* ]]
    local proof
    proof="$(find "$run" -maxdepth 1 -name 'full-sync-post-canonical-canary.*.json' -print -quit)"
    [[ -s "$proof" ]]
    jq -e --arg seed "$seed_id" --arg join "$join_id" '.kind=="gdc-genesis-single-seed-canary" and .seed_node_id==$seed and .join_node_id==$join and .common_height==100' "$proof" >/dev/null
  else
    grep -Fq state-sync-proof-verified "$tmp/events"
    if find "$run" -maxdepth 1 -name 'full-sync-post-canonical-canary.*.json' -print -quit | grep -q .; then
      echo 'state-sync verification unexpectedly created a full-sync canary receipt' >&2
      return 1
    fi
  fi
}

# Uninterrupted full-sync and a retained canonical-resume receipt chain both
# traverse this shared helper; state-sync retains its original proof path.
run_case full-sync-main full_sync new false
run_case full-sync-resume full_sync restore true
run_case state-sync-main state_sync new false

run_negative() {
  local name="$1" mode="$2" valid="$3" seed_id_value="$4" diverge="$5"
  local run="$tmp/$name/run" remote="$remote_base-$name" deploy="$tmp/$name/deploy"
  local active_data="$tmp/$name/data" generation="$tmp/$name/generation" rc=0
  mkdir -p "$run"
  write_lineage "$run/lineage-state-sync-receipt.json" "$mode" "$valid"
  cp "$run/lineage-state-sync-receipt.json" "$run/lineage-preflight-canary.v1.json"
  prepare_remote "$remote" "$deploy" "$active_data" "$generation"
  cp "$run/lineage-state-sync-receipt.json" "$remote/lineage-receipt.json"
  if [[ "$mode" == full_sync ]]; then write_canary_receipt "$run/genesis-single-seed-canary.json"; fi
  : >"$tmp/events"
  write_receipt "$run/receipts" new RUN_CREATED "$profile_sha256"
  write_receipt "$run/receipts" new CANARY_VERIFIED "$profile_sha256"
  write_receipt "$run/receipts" new PROMOTED "$profile_sha256"
  write_receipt "$run/receipts" new CANONICAL_RUNNING "$profile_sha256"
  write_receipt "$run/receipts" new APPLICATION_ACTIVE "$profile_sha256"
  PATH="$tmp/bin:$PATH" GDC_RUN_ID=fixture-run GDC_TEST_REMOTE="$remote" \
    GDC_TEST_DEPLOY="$deploy" GDC_TEST_ACTIVE_DATA="$active_data" GDC_TEST_GENERATION="$generation" \
    GDC_TEST_BLOCK_ID="$block_id" GDC_TEST_APP_HASH="$app_hash" GDC_TEST_EVENTS="$tmp/events" \
    GDC_TEST_SEED_ID="$seed_id_value" GDC_TEST_DIVERGE="$diverge" \
    "$ROOT/scripts/verify-post-sync-join-state.sh" \
      --node fixture --run-dir "$run" --profile "$profile" --remote-dir "$remote" \
      --expected-chain-id gonka-devnet-community --expected-p2p-node-id "$join_id" \
      --expected-core-version 0.2.15 --expected-core-commit 1111111111111111111111111111111111111111 \
      --expected-dapi-version 0.2.15-post3 --expected-dapi-commit 2222222222222222222222222222222222222222 >/dev/null 2>&1 || rc=$?
  [[ "$rc" != 0 ]]
}

run_negative wrong-mode full_sync false "$seed_id" false
run_negative wrong-seed full_sync true ffffffffffffffffffffffffffffffffffffffff false
run_negative divergent-block full_sync true "$seed_id" true

printf 'PASS post-sync JOIN verifier preserves state-sync proof and validates current single-seed full-sync lineage for main and canonical resume paths\n'
