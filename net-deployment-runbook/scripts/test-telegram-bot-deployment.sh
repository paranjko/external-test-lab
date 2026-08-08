#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
deploy="$ROOT/scripts/deploy-telegram-bot.sh"

grep -Fq 'for host in gdc-node0 gdc-node4; do' "$deploy"
grep -Fq '[[ "$host" == "$BOT_HOST" ]] && continue' "$deploy"
grep -Fq 'docker ps -q --filter name=gonka-devnet-bot-bot | xargs -r docker stop' "$deploy"
grep -Fq "docker info >/dev/null 2>&1' >/dev/null 2>&1 || continue" "$deploy"
grep -Fq 'docker compose up -d --build --force-recreate' "$deploy"
grep -Fq 'grep -qx gonka-devnet-bot-bot-1' "$deploy"

printf 'PASS Telegram bot singleton and pool-remount deployment contract\n'
