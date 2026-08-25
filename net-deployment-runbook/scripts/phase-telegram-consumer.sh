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
ssh -T "$TELEGRAM_BOT_HOST" bash -s -- "$action" <<'REMOTE'
set -Eeuo pipefail
action="$1"
  bot="$(docker ps -q --filter name=gonka-devnet-bot-bot)"
  [[ -n "$bot" ]] || { printf "ERROR Telegram consumer container is not running\n" >&2; exit 1; }
  health="$(docker inspect -f "{{.State.Health.Status}}" "$bot")"
  [[ "$health" == healthy ]] || { printf "ERROR Telegram consumer container health=%s\n" "$health" >&2; exit 1; }
  payload="$(curl -fsS http://127.0.0.1:9464/health)" \
    || { printf "ERROR Telegram consumer health endpoint is unavailable\n" >&2; exit 1; }
  if ! jq -e '.status == "ok"' <<<"$payload" >/dev/null; then
    printf "ERROR Telegram consumer process is not ready health=%s\n" "$payload" >&2
    exit 1
  fi
  if [[ "$action" != verify ]] && ! jq -e '.inference_ready == true' <<<"$payload" >/dev/null; then
    printf "ERROR Telegram consumer inference is not ready health=%s\n" "$payload" >&2
    exit 1
  fi
  curl -fsS http://127.0.0.1:9464/metrics | grep -q "^gdc_telegram_bot_up 1$" \
    || { printf "ERROR Telegram consumer up metric is absent\n" >&2; exit 1; }
REMOTE

if [[ "$action" == verify ]]; then
  step 'Prove the bot Conversations adapter completes chain-accounted inference'
  ssh -T "$TELEGRAM_BOT_HOST" bash -s -- "$model" "$sla_seconds" <<'REMOTE'
set -Eeuo pipefail
model="$1"
sla_seconds="$2"
bot="$(docker ps -q --filter name=gonka-devnet-bot-bot)"
[[ "$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$bot" | sed -n 's/^MODEL=//p')" == "$model" ]]
probe="$(timeout "$sla_seconds" docker exec "$bot" python3 /app/bot.py --probe 2>&1)" || {
  printf "ERROR Telegram consumer inference probe failed response=%s\n" \
    "$(jq -c '{status,reason}' <<<"$probe" 2>/dev/null || printf '%s' 'unparseable')" >&2
  exit 1
}
jq -e '. == {"conversation_id_present": true, "output_present": true, "status": "completed", "usage_present": true}' \
  <<<"$probe" >/dev/null || {
  printf "ERROR Telegram consumer inference probe returned unexpected response=%s\n" \
    "$(jq -c '{status,reason}' <<<"$probe" 2>/dev/null || printf '%s' 'unparseable')" >&2
  exit 1
}
payload="$(curl -fsS http://127.0.0.1:9464/health)"
jq -e --argjson sla "$sla_seconds" '
  .status == "ok"
  and .inference_ready == true
  and (.last_success_age_seconds | type == "number" and . <= $sla)
' <<<"$payload" >/dev/null || {
  printf "ERROR Telegram consumer probe completed but readiness was not updated health=%s\n" "$payload" >&2
  exit 1
}
REMOTE
  printf 'PASS Telegram conversation consumer completed inference for %s within %s with exact usage\n' "$model" "$sla"
else
  printf 'READY Telegram conversation consumer is healthy\n'
fi
