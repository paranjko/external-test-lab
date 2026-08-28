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
  './gdc.sh host join --public-host <IP_OR_DOMAIN> <SSH_ALIAS>' \
  './gdc.sh host backup <SSH_ALIAS>' \
  './gdc.sh --release v2026.07.23 network genesis <SSH_ALIAS>' \
  './gdc.sh network reset --yes [--hosts <SSH_ALIAS[,SSH_ALIAS...]>]' \
  './gdc.sh --release v2026.07.23 network gate-b verify' \
  './gdc.sh --release v2026.07.23 network confirmation-poc verify' \
  './gdc.sh --release v2026.08.06 network upgrade verify <proposal-id>' \
  './gdc.sh --release v2026.08.06 host upgrade prepare <ssh-alias> <proposal-id>' \
  './gdc.sh --release v2026.08.06 host upgrade watch <ssh-alias> <proposal-id>' \
  './gdc.sh --release v2026.07.23 gateway apply v3' \
  './gdc.sh --release v2026.08.06 governance devshard submit' \
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
grep -Fq "skip_qualification=false verification=false" "$ROOT/gdc.sh"
grep -Fq 'GDC_RESTORE_VALIDATOR_BACKUP_ARCHIVE="$join_restore_archive"' "$ROOT/gdc.sh"
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
! grep -Fq -- '--restore' "$ROOT/ROLE-JOIN.md"
grep -Fq 'gdc host join --verification --public-host <IP_or_DOMAIN> <ssh-alias>' "$ROOT/ROLE-JOIN.md"
! grep -Fq 'safe to run that form again' "$ROOT/ROLE-JOIN.md"
grep -Fq 'bounded six-epoch acceptance window' "$ROOT/ROLE-JOIN.md"
! grep -Fq 'Re-run host join with --restore' "$ROOT/scripts/phase-join.sh"
grep -Fq '"$ROOT/scripts/phase-ml-attach.sh" "$NODE"' "$ROOT/scripts/phase-join.sh"
grep -Fq 'https://gonka-dev.net/gonka-devnet-community/bootstrap.json' "$ROOT/gdc.sh"
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
grep -Fq 'network-bootstrap.py" verify' "$ROOT/scripts/fetch-network-bootstrap.sh"
! grep -Fq 'test-join-role-refresh.sh' "$ROOT/Makefile"
grep -Fq '^[a-z0-9][a-z0-9_-]*$' "$ROOT/gdc.sh"
grep -Fq '[[ "${GDC_JOIN_ROLE_INPUT:-false}" != true ]] || exit 1' "$ROOT/gdc.sh"
! grep -Fq 'join-bootstrap-dispatched.manifest.sha256' "$ROOT/gdc.sh"
! grep -Fq 'join-bootstrap-dispatched.manifest.sha256' "$ROOT/scripts/phase-join.sh"
grep -Fq 'acquire_operator_lock' "$ROOT/gdc.sh"
grep -Fq 'GDC_OPERATOR_LOCK_STATE' "$ROOT/gdc.sh"
! grep -Fq 'JOIN dispatch binding disagrees with the selected role input' "$ROOT/gdc.sh"
grep -Fq 'join_config_args+=(--bootstrap-file "$join_bootstrap_file")' "$ROOT/gdc.sh"
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
grep -Fq 'phase-gateway-observe.sh' "$ROOT/gdc.sh"
grep -Fq 'verify_evidence=' "$ROOT/scripts/phase-gateway-observe.sh"
grep -Fq 'gateway-status-routable.sh' "$ROOT/scripts/phase-gateway-observe.sh"
grep -Fq '"$verify_evidence" "$verify_evidence/completion.json"' "$ROOT/scripts/phase-gateway-observe.sh"
! grep -Fq '"$gateway_url" "$client_key" "$MODEL_ID" "${sla%s}"' "$ROOT/scripts/phase-gateway-observe.sh"
grep -Fq 'phase-bridge-observer.sh' "$ROOT/gdc.sh"
grep -Fq 'GDC_GOVERNANCE_SUBMIT=true run_phase' "$ROOT/gdc.sh"
grep -Fq 'GDC_GOVERNANCE_PROPOSAL_ID="$2" run_phase' "$ROOT/gdc.sh"
if grep -Eq 'ha-v4|phase-ha-v4|DevShard v4 HA' "$ROOT/scripts/phase-bridge-observer.sh"; then
  echo 'bridge observer has an artificial DevShard HA prerequisite' >&2
  exit 1
fi

printf 'PASS domain-oriented CLI contract\n'
