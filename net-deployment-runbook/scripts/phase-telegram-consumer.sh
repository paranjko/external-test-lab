#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

action="${1:-}"
[[ "$action" =~ ^(apply|status|verify)$ ]] || die 'expected: ops consumer telegram apply, status, or verify'
shift

model="${1:-$MODEL_ID}"
sla="${2:-60s}"
[[ $# -le 2 ]] || die 'verify accepts only an optional model and SLA'
[[ "$model" == "$MODEL_ID" ]] || die "Telegram consumer is configured for $MODEL_ID, not $model"
[[ "$sla" =~ ^[1-9][0-9]*s$ ]] || die 'Telegram consumer verification SLA must be a positive number of seconds'
sla_seconds="${sla%s}"

if [[ "$action" == apply ]]; then
  exec "$ROOT/scripts/deploy-telegram-bot.sh"
fi

step "Check Telegram conversation consumer on $TELEGRAM_BOT_HOST"
ssh -T "$TELEGRAM_BOT_HOST" 'set -Eeuo pipefail
  bot="$(docker ps -q --filter name=gonka-devnet-bot-bot)"
  [[ -n "$bot" ]]
  [[ "$(docker inspect -f "{{.State.Health.Status}}" "$bot")" == healthy ]]
  curl -fsS http://127.0.0.1:9464/health \
    | jq -e ".status == \"ok\" and .inference_ready == true" >/dev/null
  curl -fsS http://127.0.0.1:9464/metrics | grep -q "^gdc_telegram_bot_up 1$"'

if [[ "$action" == verify ]]; then
  step 'Prove the bot Conversations adapter completes chain-accounted inference'
  ssh -T "$TELEGRAM_BOT_HOST" bash -s -- "$model" "$sla_seconds" <<'REMOTE'
set -Eeuo pipefail
model="$1"
sla_seconds="$2"
bot="$(docker ps -q --filter name=gonka-devnet-bot-bot)"
[[ "$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$bot" | sed -n 's/^MODEL=//p')" == "$model" ]]
timeout "$sla_seconds" docker exec "$bot" python3 /app/bot.py --probe \
  | python3 -c 'import json,sys; value=json.load(sys.stdin); assert value == {"conversation_id_present": True, "output_present": True, "status": "completed", "usage_present": True}'
REMOTE
  printf 'PASS Telegram conversation consumer completed inference for %s within %s with exact usage\n' "$model" "$sla"
else
  printf 'READY Telegram conversation consumer is healthy\n'
fi
