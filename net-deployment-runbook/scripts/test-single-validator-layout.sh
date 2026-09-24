#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# These are active normal lifecycle consumers.  A separate incident rehearsal
# and the migration readers retain bounded legacy-path recognition; neither is
# a deployment writer for the single-validator Host contract.
consumers=(
  02-node/install-node.sh
  02-node/gdc-poc-winddown-watch@.service
  02-node/install-explorer.sh
  02-node/render-node-env.sh
  02-node/start-node.sh
  03-join/restart-api-after-sync.sh
  04-ops/agent/collect-versions.sh
  04-ops/agent/install-agent.sh
  04-ops/edge-node/install-edge.sh
  scripts/lib.sh
  scripts/phase-genesis.sh
  scripts/phase-join.sh
  scripts/phase-node.sh
  scripts/phase-ops.sh
  scripts/phase-upgrade.sh
  scripts/phase-host-upgrade-prepare.sh
  scripts/phase-ha-v4.sh
  scripts/phase-bridge-observer.sh
  scripts/recover-running-host-state.sh
  scripts/recover-running-host-deployment-secrets.sh
  scripts/write-upgrade-marker.sh
  scripts/host-peers.sh
  scripts/restore-validator-identity-remote.sh
)

for relative in "${consumers[@]}"; do
  file="$ROOT/$relative"
  [[ -r "$file" ]] || { echo "layout test consumer is missing: $relative" >&2; exit 1; }
  if rg -n '/srv/dai/(deploy|data|signer)/\$(node|NODE|alias|target_node|EDGE_NODE)' "$file"; then
    echo "single-validator lifecycle consumer retains an alias-scoped remote path: $relative" >&2
    exit 1
  fi
done

grep -Fqx 'ExecStart=/srv/dai/deploy/poc-winddown-watch.sh /srv/dai/deploy/.env' \
  "$ROOT/02-node/gdc-poc-winddown-watch@.service" \
  || { echo 'PoC wind-down service retains an alias-scoped deployment path' >&2; exit 1; }

grep -Fq '[[ "$data" == /srv/dai/data/inference' "$ROOT/scripts/host-peers.sh" \
  || { echo 'peer control does not bind the flat chain-data location' >&2; exit 1; }

for required in /srv/dai/deploy /srv/dai/data /srv/dai/identity /srv/dai/signer; do
  rg -Fq "$required" "$ROOT/02-node/render-node-env.sh" "$ROOT/scripts/phase-join.sh" \
    || { echo "flat validator layout is not rendered: $required" >&2; exit 1; }
done

printf 'PASS active lifecycle consumers use the flat single-validator remote layout\n'
