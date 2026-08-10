#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for contract in \
  './gdc.sh --release v2026.07.23 genesis <SSH_ALIAS> [--public-host <DNS>]' \
  './gdc.sh host join [--skip-qualification] [--public-host <DNS>] <SSH_ALIAS> [<GPU_SSH_ALIAS>]' \
  './gdc.sh --release v2026.07.23 network genesis <SSH_ALIAS>' \
  './gdc.sh --release v2026.07.23 gateway apply v3' \
  './gdc.sh --release v2026.08.06 governance devshard submit' \
  './gdc.sh --release v2026.08.06 bridge contract deploy sepolia' \
  './gdc.sh --release v2026.08.06 bridge observer apply|status|verify <SSH_ALIAS>'; do
  grep -Fq "$contract" "$ROOT/gdc.sh"
done

grep -Fq 'case "$COMMAND" in' "$ROOT/gdc.sh"
grep -Fq 'prepare-join-role-config.sh' "$ROOT/gdc.sh"
grep -Fq 'GDC_JOIN_SKIP_QUALIFICATION="$skip_qualification"' "$ROOT/gdc.sh"
grep -Fq 'join_config_args+=(--public-host "$join_public_host")' "$ROOT/gdc.sh"
grep -Fq 'detect-public-host.sh" "$SSH_ALIAS" "$PUBLIC_HOST"' "$ROOT/scripts/prepare-join-role-config.sh"
grep -Fq 'join_config_args+=(--gpu-ssh-alias "$join_gpu_alias")' "$ROOT/gdc.sh"
grep -Fq 'GDC_NODE_ML_HOSTS="${updated_ml_hosts}${updated_ml_hosts:+ }$SSH_ALIAS=$GPU_SSH_ALIAS"' "$ROOT/scripts/prepare-join-role-config.sh"
grep -Fq 'GDC_JOIN_SKIP_QUALIFICATION:-false' "$ROOT/scripts/phase-join.sh"
grep -Fq 'ML qualification explicitly disabled by the joining Host operator' "$ROOT/scripts/phase-join.sh"
grep -Fq './gdc.sh host join --skip-qualification [--public-host <dns-name>] <ssh-alias> [<gpu-ssh-alias>]' "$ROOT/ROLE-JOIN.md"
grep -Fq '"$ROOT/scripts/phase-ml-attach.sh" "$NODE"' "$ROOT/scripts/phase-join.sh"
grep -Fq 'https://node0.gonka-dev.net/join-bootstrap' "$ROOT/scripts/prepare-join-role-config.sh"
grep -Fq 'sha256sum -c required.sha256' "$ROOT/scripts/prepare-join-role-config.sh"
grep -Fq 'COMMAND=node; set -- "$subcommand" "$@"' "$ROOT/gdc.sh"
grep -Fq 'run_phase "gateway-$gateway_action-$GDC_GATEWAY_VERSION"' "$ROOT/gdc.sh"
grep -Fq 'phase-gateway-observe.sh' "$ROOT/gdc.sh"
grep -Fq 'verify_evidence=' "$ROOT/scripts/phase-gateway-observe.sh"
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
