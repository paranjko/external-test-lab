#!/usr/bin/env bash
set -Eeuo pipefail

# Run the non-critical Telegram key issuer on node4 by default. The
# one-participant bootstrap may explicitly keep it on node0 until node4 exists.
# Gateway credentials stay on node0; only the finite pre-authorised pool is
# copied from there. Never overwrite a target's live idempotence database.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOT_SOURCE="$ROOT/scripts/telegram-bot"
BOT_DIR=/srv/dai/gonka-devnet-bot
BOT_HOST="${GDC_TELEGRAM_BOT_HOST:-gdc-node4}"
ENV_FILE="${GDC_ENV:-$ROOT/.env}"
CALLER_BOT_API_BASE_URL="${GDC_TELEGRAM_BOT_API_BASE_URL:-}"
CALLER_BOT_API_BASE_URL_SET=false
[[ ${GDC_TELEGRAM_BOT_API_BASE_URL+x} ]] && CALLER_BOT_API_BASE_URL_SET=true
[[ "$BOT_HOST" == gdc-node0 || "$BOT_HOST" == gdc-node4 ]] || {
  echo 'GDC_TELEGRAM_BOT_HOST must be gdc-node0 or gdc-node4' >&2; exit 2;
}
[[ -s "$ENV_FILE" ]] || { echo "missing environment file: $ENV_FILE" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
[[ -n "${TELEGRAM_BOT_TOKEN:-}" && "$TELEGRAM_BOT_TOKEN" != replace-with-BotFather-token ]] || {
  echo "TELEGRAM_BOT_TOKEN must be configured in $ENV_FILE" >&2; exit 1;
}
if [[ "$CALLER_BOT_API_BASE_URL_SET" == true ]]; then
  BOT_API_BASE_URL="$CALLER_BOT_API_BASE_URL"
else
  BOT_API_BASE_URL="${GDC_TELEGRAM_BOT_API_BASE_URL:-https://api.gonka-dev.net/v1}"
fi
BOT_KEY_POOL_FILE=/run/secrets/gateway-key-pool.json
BOT_STATE_DB=/data/bot.sqlite3

[[ -f "$BOT_SOURCE/compose.yaml" && -f "$BOT_SOURCE/bot.py" ]] || {
  echo "embedded Telegram bot source is incomplete: $BOT_SOURCE" >&2; exit 1;
}

ssh -T gdc-node0 "test -s '$BOT_DIR/gateway-key-pool.json' && test -d '$BOT_DIR/data'"
ssh -T "$BOT_HOST" "sudo install -d -m 0750 '$BOT_DIR'"

remote=/tmp/gdc-telegram-bot-$$
runtime_env="$(mktemp)"
trap 'rm -f "$runtime_env"' EXIT
umask 077
printf '%s\n' \
  "TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN" \
  "API_BASE_URL=$BOT_API_BASE_URL" \
  "KEY_POOL_FILE=$BOT_KEY_POOL_FILE" \
  "STATE_DB=$BOT_STATE_DB" >"$runtime_env"
ssh "$BOT_HOST" "rm -rf '$remote' && mkdir -p '$remote'"
rsync -a --delete --exclude .env --exclude data --exclude __pycache__ \
  "$BOT_SOURCE/" "$BOT_HOST:$remote/source/"

# Stop the old long-poll consumer before deploying. This prevents duplicate
# Telegram update consumption while the target keeps its durable assignment DB.
ssh -T gdc-node0 'set -Eeuo pipefail
  bot="$(docker ps -q --filter name=gonka-devnet-bot-bot)"
  [[ -n "$bot" ]] && docker stop "$bot" >/dev/null || true'

# Copy the finite authorised pool from the gateway host. The bot configuration
# is rendered from the runbook's single root .env; target data is preserved.
ssh -T gdc-node0 "sudo tar -C '$BOT_DIR' -czf - gateway-key-pool.json" \
  | ssh -T "$BOT_HOST" "sudo tar -C '$BOT_DIR' -xzf -"
scp -q "$runtime_env" "$BOT_HOST:$remote/bot.env"
ssh -T "$BOT_HOST" "set -Eeuo pipefail
  sudo cp -a '$remote/source/.' '$BOT_DIR/'
  sudo install -o root -g root -m 0600 '$remote/bot.env' '$BOT_DIR/bot.env'
  rm -rf '$remote'
  sudo chown -R root:root '$BOT_DIR'
  # The container intentionally runs as uid/gid 10001.  It needs write access
  # only to its SQLite state and read access only to the mounted pool; the
  # BotFather token stays root-readable in .env for Docker Compose.
  sudo chown -R 10001:10001 '$BOT_DIR/data'
  sudo chown root:10001 '$BOT_DIR/gateway-key-pool.json'
  sudo chmod 0440 '$BOT_DIR/gateway-key-pool.json'
  sudo rm -f '$BOT_DIR/.env'
  cd '$BOT_DIR'
  sudo env KEY_POOL_HOST_PATH='$BOT_DIR/gateway-key-pool.json' docker compose up -d --build >/dev/null"

ssh -T "$BOT_HOST" 'set -Eeuo pipefail
  bot="$(docker ps -q --filter name=gonka-devnet-bot-bot)"
  [[ -n "$bot" && "$(docker inspect -f "{{.State.Running}}" "$bot")" == true ]]
  docker exec "$bot" python3 -c "import json, os; from urllib.request import urlopen; assert json.load(urlopen(\"https://api.telegram.org/bot\" + os.environ[\"TELEGRAM_BOT_TOKEN\"] + \"/getMe\", timeout=15))[\"ok\"]"
  docker exec "$bot" python3 -c "from bot import key_works, load_pool; assert key_works(load_pool()[0])"
  jq -e ".keys | type == \"array\" and length > 0" /srv/dai/gonka-devnet-bot/gateway-key-pool.json >/dev/null'
if [[ "$BOT_HOST" != gdc-node0 ]]; then
  ssh -T gdc-node0 '! docker ps --format "{{.Names}}" | grep -qx gonka-devnet-bot-bot-1'
fi
printf 'PASS Telegram key bot runs on %s\n' "$BOT_HOST"
