#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

retired_host_filter='GDC_SKIP_''HOSTS'
retired_host_helper='host_is_''skipped'
if grep -REq "$retired_host_filter|$retired_host_helper" \
  "$ROOT/.env.example" "$ROOT/gdc.sh" "$ROOT/scripts" "$ROOT/04-ops" \
  "$ROOT/profiles" "$ROOT"/ROLE-*.md "$ROOT/README.md"; then
  echo 'Per-host topology exclusion must not be part of the runbook contract' >&2
  exit 1
fi

for document in README.md ROLE-OPS.md ROLE-GENESIS.md ROLE-JOIN.md ROLE-HOST.md ROLE-UPGRADE.md ROLE-GATEWAY.md ROLE-DEVELOPER.md; do
  [[ -s "$ROOT/$document" ]] || { echo "missing role document: $document" >&2; exit 1; }
done
grep -Fq '[ROLE-OPS.md](ROLE-OPS.md)' "$ROOT/README.md"
grep -Fq '[ROLE-GENESIS.md](ROLE-GENESIS.md)' "$ROOT/README.md"
grep -Fq '[ROLE-JOIN.md](ROLE-JOIN.md)' "$ROOT/README.md"
grep -Fq '[ROLE-HOST.md](ROLE-HOST.md)' "$ROOT/README.md"
grep -Fq '[ROLE-UPGRADE.md](ROLE-UPGRADE.md)' "$ROOT/README.md"
grep -Fq '[ROLE-GATEWAY.md](ROLE-GATEWAY.md)' "$ROOT/README.md"
grep -Fq '[ROLE-DEVELOPER.md](ROLE-DEVELOPER.md)' "$ROOT/README.md"
grep -Fq 'gdc --release v2026.07.23 genesis gdc-node0' "$ROOT/ROLE-GENESIS.md"
grep -Fq 'alias gdc="$PWD/external-test-lab/net-deployment-runbook/gdc.sh"' "$ROOT/ROLE-JOIN.md"
grep -Fq 'gdc host join --public-host <IP_or_DOMAIN> <ssh-alias>' "$ROOT/ROLE-JOIN.md"
grep -Fq 'GDC_HOME=$HOME/.gdc-data' "$ROOT/ROLE-JOIN.md"
if grep -Eq 'GDC_DATA_ROOT|GDC_OPERATOR_MODE|GDC_JOIN_GATEWAY_CLIENT_KEY_FILE|Gate [AB]|Post-merge' "$ROOT/ROLE-JOIN.md"; then
  echo 'JOIN documentation must not expose internal controls or processes' >&2
  exit 1
fi
if grep -Eq 'bag reporting|tar -czf' "$ROOT/ROLE-JOIN.md"; then
  echo 'JOIN documentation must not expose internal evidence-collection procedures' >&2
  exit 1
fi
grep -Fq 'OPS is the only role that requires `.env`' "$ROOT/ROLE-OPS.md"
if grep -Eq 'GDC_GRAFANA_ADMIN_PASSWORD|GDC_ENV|\.env\.example|gpu-profile|p2p-port|acme-email|ACME_EMAIL' "$ROOT/ROLE-GENESIS.md"; then
  echo 'Genesis role must not require hidden configuration or internal deployment settings' >&2
  exit 1
fi
if grep -Eq 'cp .*\.env|requires `?\.env|prepared from .*\.env' \
  "$ROOT/ROLE-GENESIS.md" "$ROOT/ROLE-JOIN.md" \
  "$ROOT/ROLE-HOST.md" "$ROOT/ROLE-GATEWAY.md" "$ROOT/ROLE-DEVELOPER.md"; then
  echo 'Only OPS may require environment-file setup' >&2
  exit 1
fi
grep -Fq 'if [[ "$COMPONENT" == monitoring ]]' "$ROOT/scripts/phase-ops.sh"
grep -Fq "ops monitoring requires GDC_GRAFANA_ADMIN_PASSWORD owned by OPS" "$ROOT/scripts/phase-ops.sh"
grep -Fq 'GRAFANA_ADMIN_PASSWORD:-unused-outside-monitoring' "$ROOT/04-ops/compose.yaml"
if grep -Eq 'require ACME_EMAIL|ACME_EMAIL is required' "$ROOT/scripts/lib.sh" "$ROOT/04-ops/compose.yaml" "$ROOT/04-ops/edge-node/compose.yaml"; then
  echo 'ACME contact email must remain optional' >&2
  exit 1
fi
grep -Fq 'network-bootstrap.sh" verify' "$ROOT/scripts/fetch-network-bootstrap.sh"
grep -Fq 'network bootstrap download failed url=' "$ROOT/scripts/fetch-network-bootstrap.sh"
grep -Fq 'stage-network-bootstrap.sh' "$ROOT/scripts/phase-join.sh"
! grep -Rq 'join-bootstrap\|topology.env\|profile/genesis.env' "$ROOT/scripts" --exclude='test-*' --exclude='release-candidate.py'

# A JOIN owns preparation of only its own network Host.  phase-prepare derives
# a split ML Host from topology and opens the callback ingress before the
# runtime is asked to generate PoC artifacts.
grep -Fq 'Prepare $NODE for independent join' "$ROOT/scripts/phase-join.sh"
grep -Fq 'GDC_PREPARE_HOSTS="$NODE" "$ROOT/scripts/phase-prepare.sh"' "$ROOT/scripts/phase-join.sh"
grep -Fq 'explicit_hosts=false' "$ROOT/scripts/phase-prepare.sh"
grep -Fq 'SSH is unavailable; cannot prepare the requested Host' "$ROOT/scripts/phase-prepare.sh"

# OPS renders public endpoint observation without treating the local operator
# state or validator accounts as the network source of truth.
if grep -Eq 'state/joined|accounts-dir|ACCOUNTS' "$ROOT/04-ops/render-ops.sh"; then
  echo 'OPS renderer must not depend on local joined state or validator accounts' >&2
  exit 1
fi
if grep -Eq 'reconcile_monitoring_agents|install-agent.sh' "$ROOT/scripts/phase-ops.sh"; then
  echo 'OPS phase must not install or reconcile node monitoring agents' >&2
  exit 1
fi
grep -Fq 'chainRpcHost:$chainRpcHost' "$ROOT/04-ops/render-ops.sh"
grep -Eq 'const chainRpcHost[[:space:]]*=' "$ROOT/04-ops/site/src/app.js"
grep -Fq 'json("/status/participants")' "$ROOT/04-ops/site/src/app.js"
for ops_only in GRAFANA_PUBLIC_DASHBOARD_UID GRAFANA_PUBLIC_DASHBOARD_SHARE_UID GRAFANA_PUBLIC_DASHBOARD_TOKEN TELEGRAM_BOT_URL TELEGRAM_BOT_HOST; do
  if sed -n '/^write_inventory()/,/^}/p' "$ROOT/scripts/lib.sh" | grep -q "inventory_value $ops_only"; then
    echo "common Host inventory contains OPS-only field: $ops_only" >&2
    exit 1
  fi
done
! grep -q 'GDC_TELEGRAM_BOT_HOST' "$ROOT/scripts/prepare-join-role-config.sh"
! grep -q 'GDC_TELEGRAM_BOT_HOST' "$ROOT/scripts/write-genesis-role-config.sh"
printf 'PASS role documentation and OPS observation boundary\n'
