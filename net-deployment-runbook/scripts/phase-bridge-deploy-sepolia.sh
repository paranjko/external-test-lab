#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

RUN="$ROOT/artifacts/runs/$(date -u +%Y%m%dT%H%M%SZ)-bridge-deploy-sepolia"
mkdir -p "$RUN"
install_evidence_exit_trap 'Sepolia bridge deployment'
record_phase_profile bridge-deploy-sepolia

contract_root="$ROOT/../../gonka/proposals/ethereum-bridge-contact"
[[ -d "$contract_root" && -s "$contract_root/package-lock.json" ]] || die 'ethereum bridge checkout with package-lock.json is required'
rpc_url="${GDC_SEPOLIA_RPC_URL:-${SEPOLIA_RPC_URL:-}}"
[[ "$rpc_url" =~ ^https:// ]] || die 'set GDC_SEPOLIA_RPC_URL to the Sepolia execution RPC URL'

private_key=''
if [[ -n "${GDC_SEPOLIA_PRIVATE_KEY_FILE:-}" ]]; then
  [[ -f "$GDC_SEPOLIA_PRIVATE_KEY_FILE" ]] || die 'GDC_SEPOLIA_PRIVATE_KEY_FILE does not exist'
  mode="$(stat -c '%a' "$GDC_SEPOLIA_PRIVATE_KEY_FILE")"
  [[ "$mode" == 600 || "$mode" == 400 ]] || die 'GDC_SEPOLIA_PRIVATE_KEY_FILE must have mode 0600 or 0400'
  private_key="$(<"$GDC_SEPOLIA_PRIVATE_KEY_FILE")"
elif [[ -n "${GDC_SEPOLIA_PRIVATE_KEY:-}" ]]; then
  private_key="$GDC_SEPOLIA_PRIVATE_KEY"
else
  die 'set GDC_SEPOLIA_PRIVATE_KEY_FILE (preferred) or GDC_SEPOLIA_PRIVATE_KEY in .env'
fi
[[ "$private_key" =~ ^0x[0-9a-fA-F]{64}$ ]] || die 'Sepolia private key must be a 32-byte 0x-prefixed hex value'

step 'Verify the Sepolia execution network before deployment'
network_json="$RUN/sepolia-network.json"
curl -fsS --max-time 20 "$rpc_url" -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' >"$network_json"
jq -e '.result == "0xaa36a7"' "$network_json" >/dev/null || die 'execution RPC is not Sepolia chain ID 11155111'

step 'Capture current Gonka Genesis lineage and BLS epoch key'
capture_canonical_genesis "https://$NODE0_PUBLIC_HOST/chain-rpc/genesis" "$RUN/genesis.json" || die 'could not capture canonical Gonka Genesis'
genesis_sha256_value="$(genesis_sha256 "$RUN/genesis.json")"
epoch_json="$RUN/current-epoch.json"
group_json="$RUN/current-epoch-group.json"
curl -fsS "https://$NODE0_PUBLIC_HOST/chain-api/productscience/inference/inference/get_current_epoch" >"$epoch_json"
epoch="$(jq -er '.epoch | tonumber' "$epoch_json")"
curl -fsS "https://$NODE0_PUBLIC_HOST/chain-api/productscience/inference/bls/epoch_data/$epoch" >"$group_json"
group_key_b64="$(jq -er '.epoch_data.group_public_key' "$group_json")"
[[ -n "$group_key_b64" ]] || die 'current epoch has no BLS group public key'

work="$(mktemp -d "$ROOT/.bridge-deploy.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
cp -a "$contract_root"/. "$work"/
umask 077
printf '%s\n' "PRIVATE_KEY=$private_key" "SEPOLIA_RPC_URL=$rpc_url" "GONKA_CHAIN_ID=$CHAIN_ID" 'ETHEREUM_CHAIN_ID=11155111' "GENESIS_GROUP_PUBLIC_KEY=$group_key_b64" "GENESIS_HOST=$NODE0_PUBLIC_HOST" >"$work/.env"
chmod 600 "$work/.env"

step 'Install pinned bridge project dependencies'
(cd "$work" && npm ci --ignore-scripts >"$RUN/npm-ci.log" 2>&1)
step 'Deploy the Genesis-specific BridgeContract to Sepolia'
(cd "$work" && npx hardhat run deploy.js --network sepolia >"$RUN/deploy.log" 2>&1)
address="$(awk '/BridgeContract deployed to:/ {print $NF}' "$RUN/deploy.log" | tail -n1)"
tx_hash="$(awk '/Transaction submitted:/ {print $NF}' "$RUN/deploy.log" | tail -n1)"
[[ "$address" =~ ^0x[0-9a-fA-F]{40}$ ]] || die 'deployment output did not contain a contract address'
[[ "$tx_hash" =~ ^0x[0-9a-fA-F]{64}$ ]] || die 'deployment output did not contain a transaction hash'

step 'Bootstrap the current Gonka epoch and enable normal bridge operation'
(cd "$work" && HARDHAT_NETWORK=sepolia node submit-epoch.js "$address" "$epoch" "$group_key_b64" 0x >"$RUN/bootstrap-epoch.log" 2>&1)
(cd "$work" && HARDHAT_NETWORK=sepolia node enable-normal-operation.js "$address" >"$RUN/normal-operation.log" 2>&1)
cat >"$work/inspect-deployment.mjs" <<'EOF'
import hardhat from 'hardhat';
import { createHash } from 'node:crypto';
const address = process.argv[2];
const connection = await hardhat.network.connect();
const { ethers } = connection;
const provider = ethers.provider;
const bridge = await ethers.getContractAt('BridgeContract', address);
const code = await provider.getCode(address);
const state = await bridge.getCurrentState();
const owner = await bridge.owner();
const gonkaChainId = await bridge.GONKA_CHAIN_ID();
const ethereumChainId = await bridge.ETHEREUM_CHAIN_ID();
console.log(JSON.stringify({
  address,
  owner,
  bytecode_sha256: createHash('sha256').update(code.slice(2), 'hex').digest('hex'),
  gonka_chain_id: gonkaChainId,
  ethereum_chain_id: ethereumChainId,
  state: state === 1n ? 'NORMAL_OPERATION' : 'ADMIN_CONTROL'
}));
EOF
(cd "$work" && HARDHAT_NETWORK=sepolia node inspect-deployment.mjs "$address") >"$RUN/contract-state.json"
expected_gonka_domain="$(printf '%s' "$CHAIN_ID" | sha256sum | awk '{print $1}')"
jq -e --arg expected_gonka "0x$expected_gonka_domain" \
  '.address == $address and .state == "NORMAL_OPERATION" and .ethereum_chain_id == "0x0000000000000000000000000000000000000000000000000000000000aa36a7" and .gonka_chain_id == $expected_gonka and (.owner | test("^0x[0-9a-fA-F]{40}$")) and (.bytecode_sha256 | test("^[0-9a-f]{64}$"))' \
  --arg address "$address" "$RUN/contract-state.json" >/dev/null || die 'deployed contract state/domains do not match Community DevNet Sepolia'
owner="$(jq -er .owner "$RUN/contract-state.json")"
bytecode_sha256="$(jq -er .bytecode_sha256 "$RUN/contract-state.json")"

cat >"$RUN/context.env" <<EOF
$(profile_summary)
chain_id=$CHAIN_ID
genesis_sha256=$genesis_sha256_value
sepolia_chain_id=11155111
contract_address=$address
deployment_tx=$tx_hash
genesis_epoch=$epoch
contract_owner=$owner
bytecode_sha256=$bytecode_sha256
EOF
printf '%s\n' "$address" >"$RUN/bridge-address.txt"

if grep -q '^GDC_SEPOLIA_CONTRACT=' "$ENV_FILE"; then
  sed -i.bak "s|^GDC_SEPOLIA_CONTRACT=.*|GDC_SEPOLIA_CONTRACT=$address|" "$ENV_FILE"
  rm -f "$ENV_FILE.bak"
else
  printf 'GDC_SEPOLIA_CONTRACT=%s\n' "$address" >>"$ENV_FILE"
fi

cat >"$RUN/verdict.md" <<EOF
# Sepolia bridge deployment: PASS

BridgeContract $address was deployed to Sepolia (chain ID 11155111), bootstrapped
with Gonka epoch $epoch, and switched to NORMAL_OPERATION. The deployment is
bound to chain ID $CHAIN_ID and Genesis SHA-256 $genesis_sha256_value.

This PASS does not claim Community DevNet governance registration or beacon
checkpoint configuration; those are separate gates.
EOF
printf 'PASS Sepolia deployment evidence: %s\n' "$RUN"
