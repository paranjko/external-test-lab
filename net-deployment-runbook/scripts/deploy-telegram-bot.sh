#!/usr/bin/env bash
set -Eeuo pipefail

# Run the non-critical Telegram key issuer on node4. Gateway credentials stay
# on node0; only the finite pre-authorised pool is copied from there. Never
# overwrite node4's live idempotence database with a stale node0 copy.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOT_SOURCE="$ROOT/scripts/telegram-bot"
BOT_DIR=/srv/dai/gonka-devnet-bot

[[ -f "$BOT_SOURCE/compose.yaml" && -f "$BOT_SOURCE/bot.py" ]] || {
  echo "embedded Telegram bot source is incomplete: $BOT_SOURCE" >&2; exit 1;
}

ssh -T gdc-node0 "test -s '$BOT_DIR/.env' && test -s '$BOT_DIR/gateway-key-pool.json' && test -d '$BOT_DIR/data'"
ssh -T gdc-node4 "sudo install -d -m 0750 '$BOT_DIR'"

remote=/tmp/gdc-telegram-bot-$$
ssh gdc-node4 "rm -rf '$remote' && mkdir -p '$remote'"
rsync -a --delete --exclude .env --exclude data --exclude __pycache__ \
  "$BOT_SOURCE/" "gdc-node4:$remote/source/"

# Stop the old long-poll consumer before deploying. This prevents duplicate
# Telegram update consumption while node4 keeps its own durable assignment DB.
ssh -T gdc-node0 'set -Eeuo pipefail
  bot="$(docker ps -q --filter name=gonka-devnet-bot-bot)"
  [[ -n "$bot" ]] && docker stop "$bot" >/dev/null || true'

# Stream the current bot secret and authorised pool directly between SSH
# sessions. The node4 data directory is deliberately not part of this stream.
ssh -T gdc-node0 "sudo tar -C '$BOT_DIR' -czf - .env gateway-key-pool.json" \
  | ssh -T gdc-node4 "sudo tar -C '$BOT_DIR' -xzf -"
ssh -T gdc-node4 "set -Eeuo pipefail
  sudo cp -a '$remote/source/.' '$BOT_DIR/'
  rm -rf '$remote'
  sudo chown -R root:root '$BOT_DIR'
  # The container intentionally runs as uid/gid 10001.  It needs write access
  # only to its SQLite state and read access only to the mounted pool; the
  # BotFather token stays root-readable in .env for Docker Compose.
  sudo chown -R 10001:10001 '$BOT_DIR/data'
  sudo chown root:10001 '$BOT_DIR/gateway-key-pool.json'
  sudo chmod 0600 '$BOT_DIR/.env'
  sudo chmod 0440 '$BOT_DIR/gateway-key-pool.json'
  cd '$BOT_DIR'
  sudo env KEY_POOL_HOST_PATH='$BOT_DIR/gateway-key-pool.json' docker compose --env-file .env up -d --build >/dev/null"

ssh -T gdc-node4 'set -Eeuo pipefail
  bot="$(docker ps -q --filter name=gonka-devnet-bot-bot)"
  [[ -n "$bot" && "$(docker inspect -f "{{.State.Running}}" "$bot")" == true ]]
  docker exec "$bot" python3 -c "import json, os; from urllib.request import urlopen; assert json.load(urlopen(\"https://api.telegram.org/bot\" + os.environ[\"TELEGRAM_BOT_TOKEN\"] + \"/getMe\", timeout=15))[\"ok\"]"
  docker exec "$bot" python3 -c "from bot import key_works, load_pool; assert key_works(load_pool()[0])"
  jq -e ".keys | type == \"array\" and length > 0" /srv/dai/gonka-devnet-bot/gateway-key-pool.json >/dev/null'
ssh -T gdc-node0 '! docker ps --format "{{.Names}}" | grep -qx gonka-devnet-bot-bot-1'
printf 'PASS Telegram key bot runs only on gdc-node4; node0 polling is stopped\n'
