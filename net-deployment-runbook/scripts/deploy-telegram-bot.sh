#!/usr/bin/env bash
set -Eeuo pipefail

# Run the non-critical Telegram key issuer on the configured bot host. The
# gateway host owns the authorised pool; only that pool is copied to the bot.
# copied from there. Never overwrite a target's live idempotence database.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOT_SOURCE="$ROOT/scripts/telegram-bot"
BOT_DIR=/srv/dai/gonka-devnet-bot
ENV_FILE="${GDC_ENV:-$ROOT/.env}"
CALLER_BOT_API_BASE_URL="${GDC_TELEGRAM_BOT_API_BASE_URL:-}"
CALLER_BOT_API_BASE_URL_SET=false
[[ ${GDC_TELEGRAM_BOT_API_BASE_URL+x} ]] && CALLER_BOT_API_BASE_URL_SET=true
[[ -s "$ENV_FILE" ]] || { echo "missing environment file: $ENV_FILE" >&2; exit 1; }
source "$ROOT/scripts/lib.sh"
load_project
BOT_HOST="$TELEGRAM_BOT_HOST"
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

ssh -T "$GATEWAY_NODE" "test -s '$BOT_DIR/gateway-key-pool.json' && test -d '$BOT_DIR/data'"
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

# Telegram permits exactly one getUpdates consumer for a bot token. Stop every
# non-target poller before the target is verified; otherwise both containers
# receive HTTP 409 and neither can issue a key. Keep the stopped container and
# its durable assignment database intact for an explicit operator migration.
for host in "${GDC_NODES[@]}"; do
  [[ "$host" == "$BOT_HOST" ]] && continue
  # node4 is intentionally absent during node0-only bootstrap.  Stop an old
  # poller only on a provisioned Docker host; reachability of a future host is
  # neither a bootstrap prerequisite nor a reason to fail key issuance.
  ssh -T "$host" 'docker info >/dev/null 2>&1' >/dev/null 2>&1 || continue
  ssh -T "$host" 'set -Eeuo pipefail
    docker ps -q --filter name=gonka-devnet-bot-bot | xargs -r docker stop >/dev/null'
done

# Copy the finite authorised pool from the gateway host. The bot configuration
# is rendered from the runbook's single root .env; target data is preserved.
ssh -T "$GATEWAY_NODE" "sudo tar -C '$BOT_DIR' -czf - gateway-key-pool.json" \
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
  # Recreate even when source files are unchanged: replacing the pool with
  # install/tar changes its inode, while an existing bind mount keeps the old
  # inode and would keep validating revoked keys.
  sudo env KEY_POOL_HOST_PATH='$BOT_DIR/gateway-key-pool.json' docker compose up -d --build --force-recreate >/dev/null"

ssh -T "$BOT_HOST" 'set -Eeuo pipefail
  bot="$(docker ps -q --filter name=gonka-devnet-bot-bot)"
  [[ -n "$bot" && "$(docker inspect -f "{{.State.Running}}" "$bot")" == true ]]
  docker exec "$bot" python3 -c "import json, os; from urllib.request import urlopen; assert json.load(urlopen(\"https://api.telegram.org/bot\" + os.environ[\"TELEGRAM_BOT_TOKEN\"] + \"/getMe\", timeout=15))[\"ok\"]"
  docker exec "$bot" python3 -c "from bot import key_works, load_pool; assert key_works(load_pool()[0])"
  jq -e ".keys | type == \"array\" and length > 0" /srv/dai/gonka-devnet-bot/gateway-key-pool.json >/dev/null'
for host in "${GDC_NODES[@]}"; do
  if [[ "$host" == "$BOT_HOST" ]]; then
    ssh -T "$host" 'docker ps --format "{{.Names}}" | grep -qx gonka-devnet-bot-bot-1'
  else
    ssh -T "$host" 'docker info >/dev/null 2>&1' >/dev/null 2>&1 || continue
    ssh -T "$host" '! docker ps --format "{{.Names}}" | grep -qx gonka-devnet-bot-bot-1'
  fi
done
printf 'PASS Telegram key bot runs on %s\n' "$BOT_HOST"
