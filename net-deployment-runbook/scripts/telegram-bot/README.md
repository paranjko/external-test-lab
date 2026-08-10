# Telegram inference consumer

This OPS service is the first controlled user of the Community DevNet gateway.
It accepts private Telegram messages, keeps a durable conversation for each
Telegram account, and sends every model turn through chain-accounted inference.
It does not issue API keys.

The pinned Gonka gateway exposes `/v1/chat/completions`, not the OpenAI
Conversations and Responses endpoints. The bot therefore runs a loopback-only
compatibility API:

- `POST /v1/conversations` creates durable conversation state
- `POST /v1/responses` executes the next turn through the Gonka gateway
- `GET /health` reports process health
- `GET /metrics` exposes aggregate Prometheus metrics for local verification

The bot writes the same aggregate metrics to the node exporter's textfile
collector. Prometheus receives interaction counts, unique users, Telegram
Premium classification, inference outcomes, exact input/output tokens, and the
last successful inference time. Metrics never contain Telegram IDs, usernames,
conversation IDs, or message text.

## Commands

The Gateway operator first provisions the bot's dedicated client credential.
OPS then deploys and verifies the consumer:

```bash
./gdc.sh gateway access-key ensure telegram
./gdc.sh ops consumer telegram apply
./gdc.sh ops consumer telegram status
./gdc.sh ops consumer telegram verify
```

`apply` preserves `/srv/dai/gonka-devnet-bot/data/bot.sqlite3`, removes the
obsolete key-pool file, stops stale Telegram pollers on other managed hosts,
and proves a real inference before returning PASS.

The BotFather token stays in the runbook's root `.env`. Gateway and internal
adapter credentials remain mode-0600 files under the runbook state directory;
they are never written to Git or returned to Telegram users.
