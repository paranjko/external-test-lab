# Telegram inference consumer

This OPS service is the first controlled user of the Community DevNet gateway.
It accepts private Telegram messages, keeps a durable conversation for each
Telegram account, and sends every model turn through chain-accounted inference.
New turns alternate between the public A and B gateway routes with their own
dedicated client keys. A confirmed pre-dispatch rejection can use the other
route once within the original deadline; ambiguous dispatched failures never
retry automatically.
Stable API key issuance is a separate private command through the authenticated host-loopback broker, `/api_key` or `/api-key` requests a key, a later new request replaces it, neither command uses the model or gives the bot management credentials

The wiring and isolated key lifecycle have local proof, real-chat delivery and deployed public credential routing require their own live acceptance

Before creating a completion, the consumer reads the gateway's bounded
`/v1/admission-status` contract. If the current chain phase has no eligible
capacity, it sends one temporary-unavailability reply instead of waiting for a
completion timeout or sending a request that cannot dispatch.

The pinned Gonka gateway exposes `/v1/chat/completions`, not the OpenAI
Conversations and Responses endpoints. The bot keeps a loopback-only
compatibility API for local operators:

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

The Gateway operator first provisions the bot's A and B dedicated client
credentials. OPS then deploys and verifies the consumer:

```bash
./gdc.sh gateway access-key ensure telegram
./gdc.sh ops consumer telegram apply
./gdc.sh ops consumer telegram status
./gdc.sh ops consumer telegram verify
```

`apply` preserves `/srv/dai/gonka-devnet-bot/data/bot.sqlite3`, removes the
obsolete key-pool file, stops stale Telegram pollers on other managed hosts,
and proves a real inference before returning PASS.

For the approved private-chat acceptance only, the authenticated loopback API
also has a short-lived A/B route control. It can make a selected bot route
pre-dispatch unavailable and force the next selection, then is cleared after
the test. It never changes a gateway or Host, has a maximum five-minute TTL,
and must be restored before proving normal rotation.

The BotFather token stays in the private `$GDC_HOME/.env`. Gateway A/B and internal
adapter credentials remain mode-0600 files under the runbook state directory;
they are never written to Git or returned to Telegram users.

## Test GNK faucet

The same private bot accepts `/faucet <Gonka address>`. It validates the
lowercase Gonka Bech32 checksum locally, then calls the existing public faucet
through its authenticated `/faucet/v1/telegram-claim` path. The faucet signer
and its keyring remain on the faucet Host; the bot receives only a separate
mode-0600 capability token created by `scripts/make-secrets.sh`.

Deploy the existing faucet first, then redeploy the existing consumer so both
services receive the shared capability token:

```bash
./gdc.sh ops faucet
./gdc.sh ops consumer telegram apply
```

Expected bot replies distinguish `submitted` from confirmed-on-chain, pending
or unavailable confirmation. A Telegram update has one durable idempotency
key, so a delivery timeout is reconciled with the existing faucet intent rather
than creating another transfer. Repeat top-ups use new updates and remain
subject to its fixed rolling `24-hour` monetary allowance and separate per-user anti-spam bound, unresolved transactions continue reserving allowance beyond that window, changing addresses does not create another allowance

The default user policy is closed with `100 GNK` per rolling day, `/faucet status` reports only the caller's allowance, administrators use `/admins list|add|remove`, `/faucet open|close` and `/faucet limit <positive GNK> [24h]`, policy and administrator changes survive restart

See the [durable faucet operator guide](../../04-ops/faucet/README.md) for exact commands, bootstrap, retained state, integer accounting and the distinction between isolated checks and actual Telegram-to-chain proof

The user faucet does not use, expose or alter the private gateway-reserve route
