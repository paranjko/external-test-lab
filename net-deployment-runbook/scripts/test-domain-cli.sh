#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
ln -s "$ROOT/gdc.sh" "$tmp/bin/gdc"
GDC_HOME="$tmp/operator-home" "$tmp/bin/gdc" -h >"$tmp/symlink-help"
grep -Fq 'Gonka DevNet Community manual deployment' "$tmp/symlink-help"
grep -Fq '  gdc --release v2026.07.23 genesis' "$tmp/symlink-help"
! grep -Fq '  ./gdc.sh' "$tmp/symlink-help"
GDC_HOME="$tmp/operator-home" "$ROOT/gdc.sh" -h >"$tmp/direct-help"
grep -Fq '  ./gdc.sh --release v2026.07.23 genesis' "$tmp/direct-help"

for contract in \
  './gdc.sh --release v2026.07.23 genesis <SSH_ALIAS> [--public-host <DNS>]' \
  './gdc.sh host join [--plan] [--chain-id <CHAIN_ID>] --public-host <IP_OR_DOMAIN> <SSH_ALIAS>' \
  './gdc.sh host join --resume <RUN_ID> --public-host <IP_OR_DOMAIN> <SSH_ALIAS>' \
  './gdc.sh host backup <SSH_ALIAS>' \
  './gdc.sh --release v2026.07.23 network genesis <SSH_ALIAS>' \
  './gdc.sh network reset --yes [--hosts <SSH_ALIAS[,SSH_ALIAS...]>]' \
  './gdc.sh --release v2026.07.23 network gate-b verify' \
  './gdc.sh --release v2026.07.23 network confirmation-poc verify' \
  './gdc.sh --release v2026.08.06 network upgrade verify <proposal-id>' \
  './gdc.sh --release v2026.08.06 host upgrade prepare <ssh-alias> <proposal-id>' \
  './gdc.sh --release v2026.08.06 host upgrade watch <ssh-alias> <proposal-id>' \
  './gdc.sh --release v2026.07.23 gateway apply v3' \
  './gdc.sh --composition <COMPOSITION> gateway migration prepare v5' \
  './gdc.sh --composition <COMPOSITION> gateway migration status' \
  './gdc.sh --composition <COMPOSITION> gateway migration cutover' \
  './gdc.sh --composition <COMPOSITION> gateway migration drain [SECONDS]' \
  './gdc.sh --composition <COMPOSITION> gateway migration rollback|complete' \
  './gdc.sh --composition <COMPOSITION> governance devshard submit [--protocols v3,v4,v5]' \
  './gdc.sh --release v2026.08.06 bridge contract deploy sepolia' \
  './gdc.sh --release v2026.08.06 bridge observer apply|status|verify <SSH_ALIAS>'; do
  grep -Fq "$contract" "$ROOT/gdc.sh"
done

grep -Fq 'case "$COMMAND" in' "$ROOT/gdc.sh"
grep -Fq 'format_safe_invocation' "$ROOT/gdc.sh"
grep -Fq 'INVOCATION command=%s' "$ROOT/gdc.sh"
grep -Fq 'invocation_command=%q' "$ROOT/scripts/lib.sh"
grep -Fq 'prepare-join-role-config.sh' "$ROOT/gdc.sh"
grep -Fq 'GDC_JOIN_SKIP_QUALIFICATION="$skip_qualification"' "$ROOT/gdc.sh"
grep -Fq 'GDC_JOIN_VERIFICATION="$verification"' "$ROOT/gdc.sh"
grep -Fq "skip_qualification=false verification=false plan_only=false" "$ROOT/gdc.sh"
grep -Fq 'host join does not accept an externally authored signer-fence receipt' "$ROOT/gdc.sh"
grep -Fq 'verify-join-resume-inputs.sh' "$ROOT/gdc.sh"
grep -Fq 'GDC_RESTORE_VALIDATOR_BACKUP_ARCHIVE="$join_restore_archive"' "$ROOT/gdc.sh"
grep -Fq 'host join does not accept --release' "$ROOT/gdc.sh"
grep -Fq 'observe-network-state.sh' "$ROOT/gdc.sh"
! grep -Fq 'observe-network-composition.sh' "$ROOT/gdc.sh"
grep -Fq 'export GDC_RELEASE_PROFILE' "$ROOT/gdc.sh"
join_release_tmp="$(mktemp -d)"
trap 'rm -rf "$tmp" "$join_release_tmp"' EXIT
if GDC_HOME="$join_release_tmp" "$ROOT/gdc.sh" --release v2026.07.23 host join node1 >"$join_release_tmp/out" 2>"$join_release_tmp/err"; then
  echo 'host join unexpectedly accepted a global --release selector' >&2
  exit 1
fi
grep -Fq 'host join does not accept --release' "$join_release_tmp/err"
[[ ! -e "$join_release_tmp/state/network-bootstrap.json" ]]
resume_tmp="$(mktemp -d)"
if GDC_HOME="$resume_tmp" "$ROOT/gdc.sh" host join --resume retained-run --public-host node9.example.test node9 >"$resume_tmp/out" 2>"$resume_tmp/err"; then
  echo 'mutating resume unexpectedly reached lifecycle dispatch' >&2; exit 1
fi
grep -Fq 'Usage: ' "$resume_tmp/err"
for selector in '--release=v2026.07.23' '--release v2026.07.23'; do
  read -r -a selector_args <<<"$selector"
  if GDC_HOME="$join_release_tmp" "$ROOT/gdc.sh" host join "${selector_args[@]}" node1 >"$join_release_tmp/local.out" 2>"$join_release_tmp/local.err"; then
    echo "host join unexpectedly accepted selector: $selector" >&2
    exit 1
  fi
  grep -Fq 'host join does not accept release or composition selectors' "$join_release_tmp/local.err"
  [[ ! -e "$join_release_tmp/state/network-bootstrap.json" ]]
done
grep -Fq 'GDC_JOIN_RECOVERY_NEW_RUN:-false' "$ROOT/gdc.sh"
join_run_id_line="$(grep -n 'elif \[\[ -n "\${GDC_RUN_ID:-}" \]\]; then' "$ROOT/gdc.sh" | head -1 | cut -d: -f1)"
recovery_run_line="$(grep -n 'GDC_JOIN_RECOVERY_NEW_RUN:-false' "$ROOT/gdc.sh" | head -1 | cut -d: -f1)"
[[ "$join_run_id_line" =~ ^[0-9]+$ && "$recovery_run_line" =~ ^[0-9]+$ && "$join_run_id_line" -lt "$recovery_run_line" ]] \
  || { echo 'JOIN must retain its preflight run ID before recovery new-run selection' >&2; exit 1; }
grep -Fq 'host backup requires retained operator state' "$ROOT/gdc.sh"
grep -Fq 'phase-host-backup.sh' "$ROOT/gdc.sh"
grep -Fq 'join_config_args+=(--public-host "$join_public_host")' "$ROOT/gdc.sh"
grep -Fq 'detect-public-host.sh" "$SSH_ALIAS"' "$ROOT/scripts/prepare-join-role-config.sh"
grep -Fq 'join_config_args+=(--gpu-ssh-alias "$join_gpu_alias")' "$ROOT/gdc.sh"
grep -Fq 'GDC_NODE_ML_HOSTS=%q' "$ROOT/scripts/prepare-join-role-config.sh"
grep -Fq 'GDC_JOIN_SKIP_QUALIFICATION:-false' "$ROOT/scripts/phase-join.sh"
grep -Fq 'GDC_JOIN_VERIFICATION:-false' "$ROOT/scripts/phase-join.sh"
grep -Fq 'ML qualification explicitly disabled by the joining Host operator' "$ROOT/scripts/phase-join.sh"
grep -Fq 'gdc host join --public-host <IP_or_DOMAIN> <ssh-alias>' "$ROOT/ROLE-JOIN.md"
grep -Fq 'gdc host join --restore <validator-backup.tar> --public-host <IP_or_DOMAIN> <ssh-alias>' "$ROOT/ROLE-JOIN.md"
grep -Fq 'gdc host join --verification --public-host <IP_or_DOMAIN> <ssh-alias>' "$ROOT/ROLE-JOIN.md"
grep -Fq 'must not create a second' "$ROOT/ROLE-JOIN.md"
grep -Fq 'bounded six-epoch acceptance window' "$ROOT/ROLE-JOIN.md"
! grep -Fq 'Re-run host join with --restore' "$ROOT/scripts/phase-join.sh"
grep -Fq '"$ROOT/scripts/phase-ml-attach.sh" "$NODE"' "$ROOT/scripts/phase-join.sh"
grep -Fq 'join_chain_id=gonka-devnet-community' "$ROOT/gdc.sh"
grep -Fq 'join_bootstrap_url="https://gonka-dev.net/${join_chain_id}/bootstrap.json"' "$ROOT/gdc.sh"
grep -Fq -- '--chain-id=*)' "$ROOT/gdc.sh"
grep -Fq 'network bootstrap verify FILE' "$ROOT/gdc.sh"
grep -Fq 'v1.bootstrap.schema.json https://gonka-dev.net/v1.bootstrap.schema.json' "$ROOT/ROLE-JOIN.md"
! grep -Fq 'wget https://gonka-dev.net/bootstrap/gonka-mainnet.json' "$ROOT/ROLE-JOIN.md"
! grep -Fq 'wget https://gonka-dev.net/bootstrap/gonka-testnet.json' "$ROOT/ROLE-JOIN.md"
grep -Fq 'https://gonka-dev.net/gonka-devnet-community/bootstrap.json' "$ROOT/ROLE-JOIN.md"
grep -Fq 'https://gonka-dev.net/gonka-mainnet/bootstrap.json' "$ROOT/ROLE-JOIN.md"
grep -Fq 'https://gonka-dev.net/gonka-testnet/bootstrap.json' "$ROOT/ROLE-JOIN.md"
grep -Fq 'inspect it before applying it to an operator-owned local environment.' "$ROOT/ROLE-JOIN.md"
grep -Fq 'gh attestation verify v1.bootstrap.schema.json -R paranjko/external-test-lab' "$ROOT/ROLE-JOIN.md"
grep -Fq 'gdc network bootstrap verify gonka-devnet-community.bootstrap.json' "$ROOT/ROLE-JOIN.md"
grep -Fq 'gdc host join --bootstrap-file gonka-devnet-community.bootstrap.json' "$ROOT/ROLE-JOIN.md"
grep -Fq 'JOIN_PASS' "$ROOT/ROLE-JOIN.md"
! grep -Fq 'evidence bundle' "$ROOT/ROLE-JOIN.md"
grep -Fq 'GDC_JOIN_BOOTSTRAP_SHA256' "$ROOT/scripts/prepare-join-role-config.sh"
grep -Fq 'network-bootstrap.sh" verify' "$ROOT/scripts/fetch-network-bootstrap.sh"
! grep -Fq 'test-join-role-refresh.sh' "$ROOT/Makefile"
grep -Fq '^[a-z0-9][a-z0-9_-]*$' "$ROOT/gdc.sh"
if GDC_HOME="$tmp" "$ROOT/gdc.sh" host join --chain-id ../unsafe --public-host node2.example.net gdc-node2 >"$tmp/unsafe-chain.stdout" 2>"$tmp/unsafe-chain.stderr"; then
  echo 'JOIN CLI accepted an unsafe chain ID' >&2
  exit 1
fi
grep -Fq 'host join --chain-id requires a safe chain identifier' "$tmp/unsafe-chain.stderr"
[[ ! -e "$tmp/gdc-node2/state/network-bootstrap.json" ]]
if GDC_HOME="$tmp" "$ROOT/gdc.sh" host join --chain-id=../unsafe --public-host node2.example.net gdc-node2 >"$tmp/unsafe-chain-equals.stdout" 2>"$tmp/unsafe-chain-equals.stderr"; then
  echo 'JOIN CLI accepted an unsafe --chain-id= value' >&2
  exit 1
fi
grep -Fq 'host join --chain-id requires a safe chain identifier' "$tmp/unsafe-chain-equals.stderr"
chain_probe="$tmp/chain-probe"
mkdir -p "$chain_probe/bin"
jq -n '{"$schema":"https://gonka-dev.net/v1.bootstrap.schema.json",chain_id:"wrong-chain",genesis:{sha256:("a" * 64)},seeds:[{node_id:("0" * 40),rpc:"https://one.example.test/chain-rpc",p2p:"tcp://one.example.test:5000",api:"https://one.example.test"},{node_id:("1" * 40),rpc:"https://two.example.test/chain-rpc",p2p:"tcp://two.example.test:5000",api:"https://two.example.test"}],brokers:[]}' >"$chain_probe/bootstrap.json"
cat >"$chain_probe/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output=''
url="${!#}"
while (($#)); do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "$url" >>"$CHAIN_PROBE_LOG"
[[ -n "$output" ]] || exit 22
cp "$CHAIN_PROBE_BOOTSTRAP" "$output"
printf '200'
EOF
chmod 0755 "$chain_probe/bin/curl"
for requested_chain in gonka-devnet-community gonka-testnet; do
  args=(host join --chain-id "$requested_chain" --public-host node2.example.net gdc-node2)
  [[ "$requested_chain" == gonka-devnet-community ]] && args=(host join --public-host node2.example.net gdc-node2)
  if PATH="$chain_probe/bin:$PATH" CHAIN_PROBE_LOG="$chain_probe/$requested_chain.log" CHAIN_PROBE_BOOTSTRAP="$chain_probe/bootstrap.json" GDC_HOME="$chain_probe/$requested_chain" "$ROOT/gdc.sh" "${args[@]}" >"$chain_probe/$requested_chain.out" 2>"$chain_probe/$requested_chain.err"; then
    echo "JOIN unexpectedly accepted Bootstrap with wrong chain ID for $requested_chain" >&2
    exit 1
  fi
  grep -Fxq "https://gonka-dev.net/$requested_chain/bootstrap.json" "$chain_probe/$requested_chain.log"
  grep -Fq 'ERROR JOIN preflight failed checkpoint=bootstrap-chain-id' "$chain_probe/$requested_chain.err"
  [[ ! -e "$chain_probe/$requested_chain/state/join-profile.v1.json" ]]
done
grep -Fq '[[ "${GDC_JOIN_ROLE_INPUT:-false}" != true ]] || exit 1' "$ROOT/gdc.sh"
! grep -Fq 'join-bootstrap-dispatched.manifest.sha256' "$ROOT/gdc.sh"
! grep -Fq 'join-bootstrap-dispatched.manifest.sha256' "$ROOT/scripts/phase-join.sh"
grep -Fq 'acquire_operator_lock' "$ROOT/gdc.sh"
grep -Fq 'GDC_OPERATOR_LOCK_STATE' "$ROOT/gdc.sh"
! grep -Fq 'JOIN dispatch binding disagrees with the selected role input' "$ROOT/gdc.sh"
grep -Fq 'join_config_args+=(--bootstrap-file "$join_bootstrap_file")' "$ROOT/gdc.sh"
grep -Fq '"$ROOT/scripts/ensure-inferenced-cli.sh"' "$ROOT/gdc.sh"
grep -Fq 'join_genesis="$GDC_HOME/genesis"' "$ROOT/gdc.sh"
grep -Fq 'join_secrets="$STATE/secrets"' "$ROOT/gdc.sh"
grep -Fq ' --genesis-dir "$join_genesis" --state-dir "$STATE" --secrets-dir "$join_secrets"' "$ROOT/gdc.sh"
grep -Fq 'stage-network-bootstrap.sh' "$ROOT/scripts/phase-join.sh"
grep -Fq 'GDC_JOIN_BOOTSTRAP_SCHEMA' "$ROOT/scripts/phase-join.sh"
grep -Fq '^[a-z0-9][a-z0-9_-]*$' "$ROOT/02-node/init-identity.sh"
grep -Fq '^[a-z0-9][a-z0-9_-]*$' "$ROOT/02-node/install-node.sh"
grep -Fq '^[a-z0-9][a-z0-9_-]*$' "$ROOT/02-node/render-node-env.sh"
! grep -Fq '^gdc-node[0-4]$' "$ROOT/02-node/init-identity.sh"
! grep -Fq '^gdc-node[0-4]$' "$ROOT/02-node/install-node.sh"
if GDC_HOME="$tmp" "$ROOT/gdc.sh" host join --public-host node2.example.net Validator.West >"$tmp/invalid-alias.stdout" 2>"$tmp/invalid-alias.stderr"; then
  echo 'JOIN CLI accepted a Compose-unsafe SSH alias' >&2
  exit 1
fi
grep -Fq 'invalid Host SSH alias: Validator.West' "$tmp/invalid-alias.stderr"
[[ ! -e "$tmp/Validator.West" ]]
grep -Fq 'COMMAND=node; set -- "$subcommand" "$@"' "$ROOT/gdc.sh"
grep -Fq 'ERROR gdc command failed phase=%s exit=%s run_log=%s command=%s' "$ROOT/gdc.sh"
grep -Fq 'run_phase "gateway-$gateway_action-$GDC_GATEWAY_VERSION"' "$ROOT/gdc.sh"
grep -Fq 'phase-gateway-migration.sh" prepare "$1"' "$ROOT/gdc.sh"
grep -Fq 'previous observer and upstream were restored before admission restart' \
  "$ROOT/scripts/phase-gateway-migration.sh"
grep -Fq 'admission is verified stopped' "$ROOT/scripts/phase-gateway-migration.sh"
grep -Fq "jq -e 'type == \"object\"'" "$ROOT/scripts/phase-gateway-migration.sh"
! grep -Fq -- '--fresh-state' "$ROOT/gdc.sh"
grep -Fq 'phase-gateway-observe.sh' "$ROOT/gdc.sh"
grep -Fq 'verify_evidence=' "$ROOT/scripts/phase-gateway-observe.sh"
grep -Fq 'sla="${1:-300s}"' "$ROOT/scripts/phase-gateway-observe.sh"
grep -Fq 'gateway-status-routable.sh' "$ROOT/scripts/phase-gateway-observe.sh"
grep -Fq '"$verify_evidence" "$verify_evidence/completion.json"' "$ROOT/scripts/phase-gateway-observe.sh"
! grep -Fq '"$gateway_url" "$client_key" "$MODEL_ID" "${sla%s}"' "$ROOT/scripts/phase-gateway-observe.sh"
grep -Fq 'phase-bridge-observer.sh' "$ROOT/gdc.sh"
grep -Fq 'GDC_GOVERNANCE_SUBMIT=true run_phase' "$ROOT/gdc.sh"
grep -Fq 'configure_devshard_governance_protocols "$2"' "$ROOT/gdc.sh"
grep -Fq 'GDC_GOVERNANCE_PROPOSAL_ID="$proposal_id" run_phase' "$ROOT/gdc.sh"
grep -Fq 'composition export-env "$COMPOSITION"' "$ROOT/gdc.sh"
grep -Fq 'signing_address="$(printf' "$ROOT/scripts/phase-vote-proposal.sh"
grep -Fq 'does not match its recorded account' "$ROOT/scripts/phase-vote-proposal.sh"
grep -Fq 'has incomplete local governance signing state' "$ROOT/scripts/phase-vote-proposal.sh"
! grep -Fq 'SKIP  vote from' "$ROOT/scripts/phase-vote-proposal.sh"
! grep -Fq 'READY existing vote from' "$ROOT/scripts/phase-vote-proposal.sh"
! grep -Fq 'submitted + preexisting' "$ROOT/scripts/phase-vote-proposal.sh"
grep -Fq 'governance-vote-evidence.sh" receipt' "$ROOT/scripts/phase-vote-proposal.sh"
[[ "$(grep -Fc '"$ROOT/scripts/verify-approved-devshard-version.sh"' "$ROOT/scripts/phase-ops.sh")" == 2 ]]
grep -Fq 'is not supported by the pinned gateway artifact' "$ROOT/scripts/profile.sh"
grep -Fq 'selected_gateway_protocol_contract >/dev/null' "$ROOT/04-ops/create-gateway.sh"
grep -Fq '$p.approved_versions as $versions' "$ROOT/04-ops/create-gateway.sh"
grep -Fq 'map(.name) | unique | length' "$ROOT/04-ops/create-gateway.sh"
grep -Fq '.binary == $binary and .sha256 == $sha256' "$ROOT/04-ops/create-gateway.sh"
grep -Fq 'DEVSHARD_BINARY_URL=${GATEWAY_ARCHIVE_URL}' "$ROOT/04-ops/create-gateway.sh"
grep -Fq 'DEVSHARD_BINARY_SHA256=${GATEWAY_ARCHIVE_SHA256}' "$ROOT/04-ops/create-gateway.sh"
grep -Fq "escrow_bootstrap_env='DEVSHARDS_JSON=[]'" "$ROOT/04-ops/create-gateway.sh"
grep -Fq 'GDC_GATEWAY_DEFER_ESCROW_CREATE' "$ROOT/04-ops/create-gateway.sh"
grep -Fq 'DEVSHARD_ESCROW_ROTATION_ENABLED=${GDC_GATEWAY_ESCROW_ROTATION_ENABLED:-true}' "$ROOT/04-ops/create-gateway.sh"
grep -Fq 'DEVSHARD_ESCROW_ROTATION_SETTLEMENT_ENABLED=${GDC_GATEWAY_ESCROW_ROTATION_SETTLEMENT_ENABLED:-true}' "$ROOT/04-ops/create-gateway.sh"
if GDC_HOME="$tmp/governance-home" "$ROOT/gdc.sh" \
  --composition core-v2026.08.06+devshard-v2026.08.27-rc.0 \
  governance devshard submit --protocols v3,v3 >"$tmp/governance.stdout" 2>"$tmp/governance.stderr"; then
  echo 'governance CLI accepted a duplicate DevShard protocol' >&2
  exit 1
fi
grep -Fq 'Duplicate DevShard protocol: v3' "$tmp/governance.stderr"
if grep -Eq 'ha-v4|phase-ha-v4|DevShard v4 HA' "$ROOT/scripts/phase-bridge-observer.sh"; then
  echo 'bridge observer has an artificial DevShard HA prerequisite' >&2
  exit 1
fi

printf 'PASS domain-oriented CLI contract\n'
