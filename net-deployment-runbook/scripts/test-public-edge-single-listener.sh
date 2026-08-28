#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

phase="$ROOT/scripts/phase-ops.sh"
renderer="$ROOT/04-ops/render-ops.sh"

grep -Fq 'docker compose --profile public-edge up -d --force-recreate public-grafana' "$phase"
grep -Fq 'curl -fsS http://127.0.0.1:3001/api/health' "$phase"
grep -Fq 'for attempt in \$(seq 1 60)' "$phase"
grep -Fq 'docker compose up -d --force-recreate caddy' "$phase"
! grep -Fq 'docker compose --profile public-edge up -d --force-recreate caddy public-grafana' "$phase"
! grep -Fq '{$GRAFANA_HOST} {' "$renderer"
grep -Fq 'Public TLS belongs exclusively to the configured participant edge' "$renderer"
grep -Fq '{$GRAFANA_HOST} {' "$ROOT/04-ops/edge-node/PublicCaddyfile"
grep -Fq 'reverse_proxy 127.0.0.1:3001' "$ROOT/04-ops/edge-node/PublicCaddyfile"
grep -Fq 'root * /srv/dai/edge/site' "$ROOT/04-ops/edge-node/PublicCaddyfile"
grep -Fq './site:/srv/dai/edge/site:ro' "$ROOT/04-ops/edge-node/compose.yaml"
! grep -Fq 'bootstrap:' "$ROOT/04-ops/edge-node/compose.yaml"
! grep -Fq 'join-bootstrap' "$ROOT/04-ops/edge-node/compose.yaml"
grep -Fq 'handle /v1.bootstrap.schema.json' "$ROOT/04-ops/edge-node/Caddyfile"
grep -Fq 'path_regexp network_bootstrap' "$ROOT/04-ops/edge-node/Caddyfile"
grep -Fq 'handle /v1.bootstrap.schema.json' "$ROOT/04-ops/edge-node/PublicCaddyfile"
grep -Fq 'path_regexp network_bootstrap' "$ROOT/04-ops/edge-node/PublicCaddyfile"
grep -Fq 'root * /edge/bootstrap/current' "$ROOT/04-ops/edge-node/PublicCaddyfile"
! grep -Fq 'reconcile-join-bootstrap.sh' "$ROOT/04-ops/edge-node/install-edge.sh"
grep -Fq 'Publish the static status site on the public edge' "$phase"
grep -Fq 'rsync -a --delete "$SITE_ASSETS_RENDER/" "$PUBLIC_EDGE_NODE:$site_remote/site/"' "$phase"
! grep -Fq 'join-bootstrap' "$phase"
! grep -Fq 'docker compose up -d --force-recreate bootstrap' "$phase"
! grep -Fq 'cd /srv/dai/edge && docker compose down' "$phase"

printf 'PASS public edge has one TLS listener, a Grafana route, and v1 bootstrap routes\n'
