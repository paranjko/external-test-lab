#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/ssh" <<'SSH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$#" == 3 && "$1" == -T && "$2" == node-a && "$3" == "sudo -n bash -s -- 'node-a' '0123456789abcdef0123456789abcdef01234567' 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' 'chain-a'" ]] || {
  echo 'unexpected SSH invocation' >&2; exit 90;
}
cat >/dev/null
case "${GDC_TEST_REMOTE_RESULT:-pass}" in
  pass) echo 'PASS JOIN IDENTITY_READY target verified node=node-a; no deployment, chain state, or signature found' ;;
  dirty) echo 'JOIN_IDENTITY_READY_TARGET_NOT_CLEAN deployment_exists=/srv/dai/deploy' >&2; exit 1 ;;
  *) exit 255 ;;
esac
SSH
chmod 0755 "$tmp/bin/ssh"

make_case() {
  local base="$1" run_id=resume-fixture node_id=0123456789abcdef0123456789abcdef01234567
  local consensus=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= participant=gonka1abcdefghijklmnopqrstuvwxyz warm=gonka1zyxwvutsrqponmlkjihgfedcba
  mkdir -p "$base/run/receipts" "$base/state" "$base/identities" "$base/accounts"
  printf '{"chain_id":"chain-a","initial_height":"1","app_hash":null,"app_state":{}}\n' >"$base/genesis.json"
  local raw_sha canonical_sha
  raw_sha="$(sha256sum "$base/genesis.json" | awk '{print $1}')"
  canonical_sha="$(jq -eS 'del(.app_name,.app_version) | if has("app_hash") then .app_hash=(.app_hash // "") else . end | if has("initial_height") then .initial_height=(.initial_height|tostring) else . end | if .consensus.params? then .consensus_params=.consensus.params | del(.consensus) else . end' "$base/genesis.json" | sha256sum | awk '{print $1}')"
  jq -cn --arg raw "$raw_sha" '{chain_id:"chain-a",bootstrap_mode:"genesis-single-seed",genesis:{sha256:$raw},seeds:[{node_id:"0123456789abcdef0123456789abcdef01234567",rpc:"https://seed.example.test/chain-rpc",p2p:"tcp://seed.example.test:5000"}]}' >"$base/bootstrap.json"
  local bootstrap_sha
  bootstrap_sha="$(sha256sum "$base/bootstrap.json" | awk '{print $1}')"
  jq -cn --arg genesis "$canonical_sha" --arg distribution "$raw_sha" --arg bootstrap "$bootstrap_sha" --arg run "$run_id" '
    {run_id:$run,spec:{target:{node_name:"node-a",public_host:"node-a.example.test",platform:"linux-amd64"},
      network:{chain_id:"chain-a",genesis_sha256:$genesis,bootstrap_genesis_sha256:$distribution,bootstrap_sha256:$bootstrap},
      state_acquisition:{mode:"pending",providers:[],minimum_providers:0},
      components:{core:{expected_runtime:{version:"0.0.0",commit:("a"*40)},installation:{image:{repository:"core",digest:("sha256:"+("1"*64))}}},
        dapi:{expected_runtime:{version:"0.0.0",commit:("b"*40)},installation:{image:{repository:"api",digest:("sha256:"+("2"*64))}},installation:{binary:{url:"https://api.example.test/dapi",sha256:("3"*64)}}}},
      deployment:{host_envelope:{tmkms_image:"tmkms",postgres_image:"postgres",edge_api_image:"edge",versiond_image:"versiond",proxy_image:"proxy",explorer_image:"explorer",mlnode_image:"mlnode",mlnode_proxy_image:"ml-proxy",caddy_image:"caddy",grafana_image:"grafana",node_exporter_image:"node-exporter",cadvisor_image:"cadvisor",dashboard_port:3000,edge_api_compose_profile:"edge-api",edge_api_service_name:"edge-api",model_id:"Qwen/Qwen3-0.6B",model_revision:("c"*40),mlnode_vllm_args:"",mlnode_context_length:4096,mlnode_max_num_seqs:1,mlnode_gpu_memory_utilization:"0.9",mlnode_dtype:"auto",mlnode_tensor_parallel_size:1,join_effective_epochs:1,join_effective_timeout_seconds:60}}}}' >"$base/run/join-profile.v1.json"
  jq -cn --arg run "$run_id" --arg sha "$(printf x | sha256sum | awk '{print $1}')" \
    '{run_id:$run,schema_version:1,kind:"gdc-network-observation",result:{state:"ready",reason:"none"},observation:{sha256:$sha}}' >"$base/run/network-observation.v1.json"
  jq -cn --arg chain "chain-a" --arg genesis "$canonical_sha" --arg distribution "$raw_sha" \
    --arg node "$node_id" --arg rpc "https://seed.example.test/chain-rpc" --arg p2p "tcp://seed.example.test:5000" \
    --arg observation "$(printf observation | sha256sum | awk '{print $1}')" '
    {bootstrap:{mode:"full_sync",chain_id:$chain,genesis_sha256:$genesis,distribution_sha256:$distribution,
      seed:{node_id:$node,rpc_url:$rpc,p2p:$p2p}},trust_authority:{kind:"genesis_single_seed",rpc_url:$rpc},
     runtime:{observation_sha256:$observation},fault_domains:[{id:"genesis-single-seed",rpc_url:$rpc,chain_id:$chain,genesis_sha256:$genesis}],checkpoints:null}
  ' >"$base/state/lineage-preflight.json"
  printf 'GDC_JOIN_BOOTSTRAP_MODE=full_sync\n' >"$base/state/lineage-preflight.env"
  jq -cn --arg node_id "$node_id" --arg consensus "$consensus" --arg participant "$participant" --arg warm "$warm" \
    '{node_name:"node-a",node_id:$node_id,consensus_pubkey:$consensus,warm_address:$warm,warm_pubkey_b64:"AQ=="}' >"$base/identities/node-a.json"
  jq -cn --arg address "$participant" '{address:$address}' >"$base/accounts/node-a-cold.json"
  local profile_sha observation_sha
  profile_sha="$(sha256sum "$base/run/join-profile.v1.json" | awk '{print $1}')"
  observation_sha="$(sha256sum "$base/run/network-observation.v1.json" | awk '{print $1}')"
  for state in RUN_CREATED BOOTSTRAP_VERIFIED NETWORK_OBSERVED JOIN_PROFILE_READY TARGET_CLASSIFIED HOST_BASE_PREPARED IDENTITY_READY; do
    jq -cn --arg run "$run_id" --arg node "node-a" --arg profile "$profile_sha" --arg observation "$observation_sha" \
      --arg state "$state" --arg node_id "$node_id" --arg consensus "$consensus" --arg participant "$participant" --arg warm "$warm" '
      {schema_version:2,kind:"gdc-host-join-receipt",run_id:$run,generation_id:$run,operation:"new",node_name:$node,
       state:$state,join_profile_sha256:$profile,network_observation_sha256:$observation,
       identity_fingerprints:{participant_address:$participant,consensus_pubkey:$consensus,p2p_node_id:$node_id,warm_address:$warm},
       signer_ever_started:false,tmkms_state:{height:0,round:0,step:0,block_id:""},evidence:[],outcome:"in_progress",resume_policy:"resume_same_run"}' >"$base/input.json"
    "$ROOT/scripts/record-join-receipt.sh" --receipt-dir "$base/run/receipts" --input "$base/input.json" >/dev/null
  done
}

base="$tmp/success"
make_case "$base"
export GDC_JOIN_RESUME=true GDC_JOIN_RESUME_IDENTITY_READY=true STATE="$base/state" GDC_JOIN_LINEAGE_RECEIPT="$base/state/lineage-preflight.json"
GDC_JOIN_LINEAGE_RECEIPT_SHA256="$(sha256sum "$GDC_JOIN_LINEAGE_RECEIPT" | awk '{print $1}')"
GDC_JOIN_BOOTSTRAP_SHA256="$(sha256sum "$base/bootstrap.json" | awk '{print $1}')"
export GDC_JOIN_LINEAGE_RECEIPT_SHA256 GDC_JOIN_BOOTSTRAP_SHA256
result="$(PATH="$tmp/bin:$PATH" "$ROOT/scripts/verify-join-identity-ready-resume.sh" node-a resume-fixture \
  "$base/run" "$base/run/join-profile.v1.json" "$base/run/network-observation.v1.json" "$base/bootstrap.json" \
  "$base/genesis.json" "$base/identities/node-a.json" "$base/accounts/node-a-cold.json")"
jq -e '.participant_address == "gonka1abcdefghijklmnopqrstuvwxyz" and .remote_boundary == "clean_identity_ready"' <<<"$result" >/dev/null

if GDC_TEST_REMOTE_RESULT=dirty PATH="$tmp/bin:$PATH" "$ROOT/scripts/verify-join-identity-ready-resume.sh" node-a resume-fixture \
  "$base/run" "$base/run/join-profile.v1.json" "$base/run/network-observation.v1.json" "$base/bootstrap.json" \
  "$base/genesis.json" "$base/identities/node-a.json" "$base/accounts/node-a-cold.json" >"$tmp/dirty.out" 2>"$tmp/dirty.err"; then
  echo 'dirty target unexpectedly permitted IDENTITY_READY continuation' >&2; exit 1
fi
grep -Fq 'no render or install was attempted' "$tmp/dirty.err"

cp -a "$base" "$tmp/tampered"
jq '.node_name="other"' "$tmp/tampered/identities/node-a.json" >"$tmp/tampered/identity.tmp"
mv "$tmp/tampered/identity.tmp" "$tmp/tampered/identities/node-a.json"
if PATH="$tmp/bin:$PATH" "$ROOT/scripts/verify-join-identity-ready-resume.sh" node-a resume-fixture \
  "$tmp/tampered/run" "$tmp/tampered/run/join-profile.v1.json" "$tmp/tampered/run/network-observation.v1.json" "$tmp/tampered/bootstrap.json" \
  "$tmp/tampered/genesis.json" "$tmp/tampered/identities/node-a.json" "$tmp/tampered/accounts/node-a-cold.json" >"$tmp/tampered.out" 2>"$tmp/tampered.err"; then
  echo 'mismatched retained identity unexpectedly permitted continuation' >&2; exit 1
fi
grep -Fq 'retained local identity does not match' "$tmp/tampered.err"

# The target checker accepts the canonical init-only layout and refuses
# legacy per-alias runtime residue. It is root-only, so run that portion only
# in the privileged integration harness; regular CI still exercises the
# receipt verifier with a mocked, strict SSH boundary.
if [[ "$EUID" == 0 ]]; then
remote_root="$tmp/remote-root"
mkdir -p "$remote_root/identity/p2p" "$remote_root/identity/warm/keyring-file" \
  "$remote_root/signer/tmkms/secrets" "$remote_root/signer/tmkms/state" "$remote_root/signer/tmkms/schema" \
  "$remote_root/identity-bootstrap/02-node" "$remote_root/inference/config" "$remote_root/inference/data" \
  "$remote_root/backups" "$remote_root/hf-cache" "$remote_root/monitoring-agent" "$remote_root/ops" "$remote_root/shared" "$tmp/check-bin"
cat >"$tmp/check-bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$*" in 'ps -q --no-trunc'|'ps -aq --no-trunc --filter label=com.docker.compose.project=node-a') exit 0 ;;
  *) echo "unexpected docker invocation: $*" >&2; exit 90 ;;
esac
DOCKER
chmod 0755 "$tmp/check-bin/docker"
openssl genpkey -algorithm ED25519 -out "$tmp/ed25519.pem" 2>/dev/null
openssl pkey -in "$tmp/ed25519.pem" -pubout -outform DER >"$tmp/ed25519-public.der" 2>/dev/null
openssl pkey -in "$tmp/ed25519.pem" -outform DER >"$tmp/ed25519-private.der" 2>/dev/null
tail -c 32 "$tmp/ed25519-private.der" >"$tmp/p2p-seed"
tail -c 32 "$tmp/ed25519-public.der" >"$tmp/p2p-public"
cat "$tmp/p2p-seed" "$tmp/p2p-public" >"$tmp/p2p-key.raw"
node_id="$(sha256sum "$tmp/p2p-public" | awk '{print substr($1,1,40)}')"
jq -cn --arg key "$(base64 -w0 "$tmp/p2p-key.raw")" '{priv_key:{type:"tendermint/PrivKeyEd25519",value:$key}}' >"$remote_root/identity/p2p/node_key.json"
cp "$remote_root/identity/p2p/node_key.json" "$remote_root/inference/config/node_key.json"
base64 -w0 "$tmp/p2p-seed" >"$remote_root/signer/tmkms/secrets/priv_validator_key.softsign"
softsign_public="$(tail -c 32 "$tmp/ed25519-public.der" | base64 -w0)"
printf '{"height":"0","round":0,"step":0}\n' >"$remote_root/signer/tmkms/state/priv_validator_state.json"
touch "$remote_root/identity/warm/keyring-file/keyring.json" "$remote_root/signer/tmkms/tmkms.toml"
touch "$remote_root/signer/tmkms/secrets/kms-identity.key"
for name in app.toml client.toml config.toml priv_validator_key.json; do printf '{}\n' >"$remote_root/inference/config/$name"; done
jq -cn '{chain_id:"chain-a",initial_height:1,app_hash:null,app_state:{genutil:{gen_txs:[]},auth:{accounts:[]},staking:{validators:[]}}}' >"$remote_root/inference/config/genesis.json"
mkdir -p "$remote_root/data.generations"
printf 'preserve\n' >"$remote_root/hf-cache/cache-marker"
printf 'preserve\n' >"$remote_root/ops/operator-marker"
printf 'preserve\n' >"$remote_root/backups/archive-marker"
printf 'preserve\n' >"$remote_root/monitoring-agent/config-marker"
PATH="$tmp/check-bin:$PATH" "$ROOT/scripts/check-join-identity-ready-target.sh" node-a "$node_id" "$softsign_public" chain-a --root "$remote_root" >/dev/null
[[ -s "$remote_root/hf-cache/cache-marker" && -s "$remote_root/ops/operator-marker" \
  && -s "$remote_root/backups/archive-marker" && -s "$remote_root/monitoring-agent/config-marker" ]] \
  || { echo 'independent host data was changed during read-only target check' >&2; exit 1; }
mkdir -p "$remote_root/node-a/data"
if PATH="$tmp/check-bin:$PATH" "$ROOT/scripts/check-join-identity-ready-target.sh" node-a "$node_id" "$softsign_public" chain-a --root "$remote_root" >"$tmp/legacy.out" 2>"$tmp/legacy.err"; then
  echo 'legacy validator runtime residue unexpectedly accepted by IDENTITY_READY checker' >&2; exit 1
fi
grep -Fq 'legacy_runtime_residue=' "$tmp/legacy.err"
else
  printf 'SKIP root-only target-layout fixture (requires isolated privileged harness)\n'
fi

# Invoke the real GDC dispatcher and real phase entry from an isolated
# operator tree. Only receipt/target checking and Bootstrap staging are
# fixture adapters; the phase must load the retained one-host role.
cli_fixture="$tmp/cli-runbook"
operator="$tmp/operator"
node_home="$operator/node-a"
mkdir -p "$cli_fixture" "$node_home/state/identities" "$node_home/accounts" "$node_home/genesis" \
  "$node_home/runs/resume-fixture/join-node-a" "$node_home/state/role-inputs"
tar --exclude='./.data' -C "$ROOT" -cf - . | tar -C "$cli_fixture" -xf -
cp "$ROOT/gdc.sh" "$cli_fixture/gdc.sh"
cat >"$cli_fixture/scripts/verify-join-resume-inputs.sh" <<'VERIFY_RESUME'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'verified\n' >>"${GDC_TEST_DISPATCH:?}"
printf '{"operation":"new","receipt_chain":{"last_state":"IDENTITY_READY"}}\n'
VERIFY_RESUME
cat >"$cli_fixture/scripts/verify-join-identity-ready-resume.sh" <<'VERIFY_IDENTITY'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$#" == 9 && "$7" == "$GDC_HOME/genesis/genesis.json" \
  && "$8" == "$STATE/identities/node-a.json" && "$9" == "$GDC_HOME/accounts/node-a-cold.json" ]] || exit 92
[[ "${GDC_JOIN_BOOTSTRAP_SHA256:-}" == "$(sha256sum "$6" | awk '{print $1}')" \
  && "${GDC_JOIN_BOOTSTRAP_SCHEMA:-}" == https://gonka-dev.net/v1.bootstrap.schema.json ]] || exit 93
printf 'identity-verified\n' >>"${GDC_TEST_DISPATCH:?}"
printf '{"participant_address":"gonka1abcdefghijklmnopqrstuvwxyz","node_id":"0123456789abcdef0123456789abcdef01234567","consensus_pubkey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","warm_address":"gonka1zyxwvutsrqponmlkjihgfedcba","chain_id":"chain-a","genesis_sha256":"%s","remote_boundary":"clean_identity_ready"}\n' \
  "$(jq -r '.spec.network.genesis_sha256' "$4")"
VERIFY_IDENTITY
cat >"$cli_fixture/scripts/stage-network-bootstrap.sh" <<'STAGE_BOOTSTRAP'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$#" == 8 && "$1" == --bootstrap-file && -r "$2" \
  && "$3" == --genesis-dir && "$5" == --state-dir && "$7" == --secrets-dir ]] || exit 91
printf 'reached\n' >"${GDC_TEST_PHASE_ENTRY:?}"
printf 'STAGE_BOOTSTRAP_STUB_REACHED\n'
exit 93
STAGE_BOOTSTRAP
cat >"$cli_fixture/scripts/join-profile.sh" <<'PROFILE'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${1:-}" == validate ]]
PROFILE
cat >"$cli_fixture/scripts/network-bootstrap.sh" <<'BOOTSTRAP'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "${1:-}" == verify && -r "${2:-}" ]]
BOOTSTRAP
chmod 0755 "$cli_fixture/scripts/verify-join-resume-inputs.sh" \
  "$cli_fixture/scripts/verify-join-identity-ready-resume.sh" "$cli_fixture/scripts/stage-network-bootstrap.sh" \
  "$cli_fixture/scripts/join-profile.sh" "$cli_fixture/scripts/network-bootstrap.sh"
cp "$base/run/join-profile.v1.json" "$node_home/runs/resume-fixture/join-node-a/join-profile.v1.json"
cp "$base/run/network-observation.v1.json" "$node_home/runs/resume-fixture/join-node-a/network-observation.v1.json"
cp "$base/bootstrap.json" "$node_home/state/network-bootstrap.json"
cp "$base/genesis.json" "$node_home/genesis/genesis.json"
cp "$base/identities/node-a.json" "$node_home/state/identities/node-a.json"
cp "$base/accounts/node-a-cold.json" "$node_home/accounts/node-a-cold.json"
cp "$base/state/lineage-preflight.json" "$node_home/state/lineage-preflight.json"
cp "$base/state/lineage-preflight.env" "$node_home/state/lineage-preflight.env"
cp -a "$base/run/receipts" "$node_home/runs/resume-fixture/join-node-a/receipts"
chmod 0600 "$node_home/runs/resume-fixture/join-node-a/"*.json "$node_home/state/network-bootstrap.json" \
  "$node_home/genesis/genesis.json" "$node_home/state/identities/node-a.json" "$node_home/accounts/node-a-cold.json" \
  "$node_home/state/lineage-preflight.json" "$node_home/state/lineage-preflight.env"
printf '%s\n' resume-fixture >"$node_home/state/active-run-id"
role="$node_home/state/role-inputs/join-node-a"
cat >"$role" <<EOF
GDC_NODE_ALIASES='node-a'
GDC_NODE_PUBLIC_HOSTS='node-a=node-a.example.test'
GDC_NODE_P2P_PORTS='node-a=5000'
GDC_JOIN_BOOTSTRAP_FILE='$node_home/state/network-bootstrap.json'
GDC_JOIN_BOOTSTRAP_SHA256='$(sha256sum "$node_home/state/network-bootstrap.json" | awk '{print $1}')'
GDC_JOIN_BOOTSTRAP_SCHEMA='https://gonka-dev.net/v1.bootstrap.schema.json'
GDC_JOIN_NETWORK_HOST='seed.example.test'
GDC_JOIN_ROLE_INPUT=true
EOF
chmod 0600 "$role"
printf '%s\n' "$role" >"$node_home/state/active-role-config"
cat >"$operator/.env" <<'OTHER_ENV'
GDC_NODE_ALIASES='node-a'
GDC_NODE_PUBLIC_HOSTS='node-a=127.0.0.1'
GDC_NODE_P2P_PORTS='node-a=5000'
GDC_JOIN_ROLE_INPUT=false
OTHER_ENV
chmod 0600 "$operator/.env"
if GDC_DATA_ROOT="$operator" GDC_HOME="$operator" GDC_ENV="$operator/.env" \
  GDC_TEST_DISPATCH="$tmp/dispatch.calls" GDC_TEST_PHASE_ENTRY="$tmp/phase-entry" \
  "$cli_fixture/gdc.sh" host join --resume resume-fixture \
    --public-host node-a.example.test node-a >"$tmp/dispatch.out" 2>"$tmp/dispatch.err"; then
  echo 'identity-ready phase fixture unexpectedly continued past the staging sentinel' >&2; exit 1
else
  phase_rc=$?
  [[ "$phase_rc" == 93 ]] || {
    cat "$tmp/dispatch.out" "$tmp/dispatch.err" >&2
    echo "unexpected phase entry exit=$phase_rc" >&2
    exit 1
  }
fi
grep -Fq 'identity-verified' "$tmp/dispatch.calls"
[[ -s "$tmp/phase-entry" ]]
grep -Fq 'STAGE_BOOTSTRAP_STUB_REACHED' "$tmp/dispatch.out"
! grep -Fq 'JOIN requires a generated one-host role input' "$tmp/dispatch.err"

echo 'PASS IDENTITY_READY retained receipt, canonical init-only target, and legacy refusal fixtures'
