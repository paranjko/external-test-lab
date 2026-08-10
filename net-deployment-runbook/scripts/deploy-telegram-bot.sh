#!/usr/bin/env bash
set -Eeuo pipefail

# Deploy the OPS-owned Telegram conversation client. It receives one dedicated
# gateway client credential and never owns or distributes a key pool.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
BOT_SOURCE="$ROOT/scripts/telegram-bot"
BOT_DIR=/srv/dai/gonka-devnet-bot
ENV_FILE="${GDC_ENV:-$GDC_HOME/.env}"
CALLER_API_BASE_URL="${GDC_TELEGRAM_BOT_API_BASE_URL:-}"
CALLER_API_BASE_URL_SET=false
[[ ${GDC_TELEGRAM_BOT_API_BASE_URL+x} ]] && CALLER_API_BASE_URL_SET=true
[[ -s "$ENV_FILE" ]] || { echo "missing environment file: $ENV_FILE" >&2; exit 1; }
load_project
BOT_HOST="$TELEGRAM_BOT_HOST"
[[ -n "${TELEGRAM_BOT_TOKEN:-}" && "$TELEGRAM_BOT_TOKEN" != replace-with-BotFather-token ]] || {
  echo "TELEGRAM_BOT_TOKEN must be configured in $ENV_FILE" >&2; exit 1;
}
if [[ "$CALLER_API_BASE_URL_SET" == true ]]; then
  BOT_API_BASE_URL="$CALLER_API_BASE_URL"
else
  BOT_API_BASE_URL="${GDC_TELEGRAM_BOT_API_BASE_URL:-https://api.gonka-dev.net/v1}"
fi
BOT_STATE_DB=/data/bot.sqlite3
BOT_METRICS_FILE=/metrics/telegram-bot.prom
BOT_KEY_FILE="$SECRETS/gateway.telegram-client-key"
BOT_INTERNAL_TOKEN_FILE="$SECRETS/telegram.conversation-api-token"
VERIFY_TIMEOUT_SECONDS="${GDC_TELEGRAM_CONSUMER_VERIFY_TIMEOUT_SECONDS:-180}"

[[ -f "$BOT_SOURCE/compose.yaml" && -f "$BOT_SOURCE/bot.py" ]] || {
  echo "embedded Telegram bot source is incomplete: $BOT_SOURCE" >&2; exit 1;
}
[[ -s "$BOT_KEY_FILE" ]] || { echo "missing dedicated Telegram gateway credential: $BOT_KEY_FILE" >&2; exit 1; }
[[ -s "$BOT_INTERNAL_TOKEN_FILE" ]] || { echo "missing Telegram conversation API token: $BOT_INTERNAL_TOKEN_FILE" >&2; exit 1; }
[[ "$VERIFY_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
  echo 'GDC_TELEGRAM_CONSUMER_VERIFY_TIMEOUT_SECONDS must be a positive integer' >&2; exit 2;
}
BOT_GATEWAY_API_KEY="$(<"$BOT_KEY_FILE")"
BOT_INTERNAL_API_TOKEN="$(<"$BOT_INTERNAL_TOKEN_FILE")"

remote="/tmp/gdc-telegram-bot-$$"
runtime_env="$(mktemp)"
trap 'rm -f "$runtime_env"' EXIT
umask 077
printf '%s\n' \
  "TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN" \
  "GATEWAY_API_BASE_URL=$BOT_API_BASE_URL" \
  "GATEWAY_API_KEY=$BOT_GATEWAY_API_KEY" \
  "INTERNAL_API_TOKEN=$BOT_INTERNAL_API_TOKEN" \
  "INTERNAL_API_BASE_URL=http://127.0.0.1:9464" \
  "MODEL=$MODEL_ID" \
  "HEALTH_MAX_AGE_SECONDS=${GDC_TELEGRAM_CONSUMER_HEALTH_MAX_AGE_SECONDS:-900}" \
  "STATE_DB=$BOT_STATE_DB" \
  "METRICS_FILE=$BOT_METRICS_FILE" >"$runtime_env"

ssh -T "$BOT_HOST" "sudo install -d -m 0750 '$BOT_DIR' '$BOT_DIR/data'; sudo install -d -m 0755 /var/lib/node_exporter/textfile_collector"
ssh "$BOT_HOST" "rm -rf '$remote' && mkdir -p '$remote'"
rsync -a --delete --exclude .env --exclude data --exclude __pycache__ \
  "$BOT_SOURCE/" "$BOT_HOST:$remote/source/"
scp -q "$runtime_env" "$BOT_HOST:$remote/bot.env"

# Telegram permits one getUpdates consumer per bot token. Stop stale pollers
# but preserve their data for operator inspection; only the configured OPS host
# is allowed to run the service.
for host in "${GDC_NODES[@]}"; do
  [[ "$host" == "$BOT_HOST" ]] && continue
  ssh -T "$host" 'docker info >/dev/null 2>&1' >/dev/null 2>&1 || continue
  ssh -T "$host" 'set -Eeuo pipefail
    docker ps -q --filter name=gonka-devnet-bot-bot | xargs -r docker stop >/dev/null
    sudo rm -f /var/lib/node_exporter/textfile_collector/telegram-bot.prom'
done

ssh -T "$BOT_HOST" "set -Eeuo pipefail
  sudo cp -a '$remote/source/.' '$BOT_DIR/'
  sudo install -o root -g root -m 0600 '$remote/bot.env' '$BOT_DIR/bot.env'
  rm -rf '$remote'
  sudo chown -R root:root '$BOT_DIR'
  sudo chown -R 10001:10001 '$BOT_DIR/data'
  sudo chown 10001:10001 /var/lib/node_exporter/textfile_collector
  sudo rm -f '$BOT_DIR/gateway-key-pool.json' '$BOT_DIR/.env'
  cd '$BOT_DIR'
  sudo docker compose up -d --build --force-recreate >/dev/null"

consumer_ready=false
deadline=$((SECONDS + VERIFY_TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
  if ssh -T "$BOT_HOST" 'set -Eeuo pipefail
    bot="$(docker ps -q --filter name=gonka-devnet-bot-bot)"
    [[ -n "$bot" && "$(docker inspect -f "{{.State.Health.Status}}" "$bot")" == healthy ]]
    curl -fsS http://127.0.0.1:9464/metrics | grep -q "^gdc_telegram_bot_up 1$"
    docker exec "$bot" python3 -c "import json, os; from urllib.request import urlopen; assert json.load(urlopen(\"https://api.telegram.org/bot\" + os.environ[\"TELEGRAM_BOT_TOKEN\"] + \"/getMe\", timeout=15))[\"ok\"]"
    docker exec "$bot" python3 /app/bot.py --probe \
      | jq -e ".status == \"completed\" and .output_present == true and .usage_present == true" >/dev/null'; then
    consumer_ready=true
    break
  fi
  printf 'WAIT  Telegram conversation consumer is not yet ready\n'
  sleep 3
done
[[ "$consumer_ready" == true ]] || die "Telegram conversation consumer was not ready within ${VERIFY_TIMEOUT_SECONDS}s"

for host in "${GDC_NODES[@]}"; do
  if [[ "$host" == "$BOT_HOST" ]]; then
    ssh -T "$host" 'docker ps --format "{{.Names}}" | grep -qx gonka-devnet-bot-bot-1'
  else
    ssh -T "$host" 'docker info >/dev/null 2>&1' >/dev/null 2>&1 || continue
    ssh -T "$host" '! docker ps --format "{{.Names}}" | grep -qx gonka-devnet-bot-bot-1'
  fi
done
printf 'PASS Telegram conversation consumer runs on %s\n' "$BOT_HOST"
