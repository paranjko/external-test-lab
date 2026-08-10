#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
deploy="$ROOT/scripts/deploy-telegram-bot.sh"

grep -Fq 'for host in "${GDC_NODES[@]}"; do' "$deploy"
grep -Fq '[[ "$host" == "$BOT_HOST" ]] && continue' "$deploy"
grep -Fq 'docker ps -q --filter name=gonka-devnet-bot-bot | xargs -r docker stop' "$deploy"
grep -Fq 'textfile_collector/telegram-bot.prom' "$deploy"
grep -Fq "docker info >/dev/null 2>&1' >/dev/null 2>&1 || continue" "$deploy"
grep -Fq 'docker compose up -d --build --force-recreate' "$deploy"
grep -Fq 'grep -qx gonka-devnet-bot-bot-1' "$deploy"
grep -Fq 'BOT_KEY_FILE="$SECRETS/gateway.telegram-client-key"' "$deploy"
grep -Fq 'BOT_INTERNAL_TOKEN_FILE="$SECRETS/telegram.conversation-api-token"' "$deploy"
grep -Fq 'GATEWAY_API_KEY=$BOT_GATEWAY_API_KEY' "$deploy"
grep -Fq 'INTERNAL_API_TOKEN=$BOT_INTERNAL_API_TOKEN' "$deploy"
grep -Fq 'Telegram conversation consumer is not yet ready' "$deploy"
grep -Fq 'python3 /app/bot.py --probe' "$deploy"
grep -Fq 'HEALTH_MAX_AGE_SECONDS=' "$deploy"
! grep -Eq 'gateway-key-pool|POOL_SOURCE|key issuer' "$deploy"

grep -Fq '@telegram_consumer path /status/telegram-consumer' "$ROOT/04-ops/edge-node/PublicCaddyfile"
grep -Fq '@telegram_metrics_from_monitoring' "$ROOT/04-ops/edge-node/PublicCaddyfile"
grep -Fq 'remote_ip {$MONITORING_CIDR}' "$ROOT/04-ops/edge-node/PublicCaddyfile"
grep -Fq 'job_name: telegram-consumer' "$ROOT/04-ops/render-ops.sh"
grep -Fq 'json("/status/telegram-consumer")' "$ROOT/04-ops/site/app.js"

grep -Fq './gdc.sh ops consumer telegram apply' "$ROOT/gdc.sh"
grep -Fq 'phase-telegram-consumer.sh' "$ROOT/gdc.sh"
grep -Fq 'gateway access-key ensure telegram' "$ROOT/gdc.sh"
grep -Fq 'phase-gateway-access-key.sh' "$ROOT/gdc.sh"
! grep -Eq 'telegram-key-probe|telegram-bot\)' "$ROOT/gdc.sh"

printf 'PASS Telegram conversation consumer deployment contract\n'
