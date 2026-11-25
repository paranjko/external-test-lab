# Devshard gateway v6.0.1

Image:
```text
ghcr.io/gonka-ai/devshard-gateway:mainnet-v0.2.16-v6.0.1
```

Pinned digest:
```text
ghcr.io/gonka-ai/devshard-gateway@sha256:c76de1bdc341273fa749597294b9b4db807c29821959424351cd171cdfd08e0f
```
Session protocol: `v6`. Route: `/devshard/v6`.

Pin the digest: the `-latest` tag moves. `mainnet-v0.2.16-v6.0.0` is
devshardctl, a different program with its own store.

## From a v6 release candidate

The store, environment and settings stay. Only the image changes.

1. Pick the moment: no confirmation PoC running, and the escrows of the
   previous epoch already settled (no row with that `chain_epoch` left in
   `GET /v1/admin/devshards`). On restart the gateway reattaches every
   escrow, and large hosts limit attaches: the first 10–15 minutes serve
   slower.
2. Save the Compose file, the current image digest and the admin settings.
3. Put the pinned digest into the service and recreate only it. Clients get
   connection errors for about 30 seconds.
```bash
docker compose -f docker-compose.yml -f docker-compose.v6.yml pull gateway-v6
docker compose -f docker-compose.yml -f docker-compose.v6.yml \
  up -d --no-deps --no-build gateway-v6
```
4. Check the log for `gateway started` with `version v6`, the same escrows in
   `GET /v1/admin/devshards`, the same admin settings, and chat through the
   front.
5. Every `rotation_models_json` entry must have `"amount": 2500000000` and
   `"temp_count": 4`. If yours differ, post the full array with these values
   through `POST /v1/admin/settings` and mirror it into the environment.

Rollback: put the previous digest back and run the same `up`.

## From 4.2.0

Run v6 with a new volume and new escrows. Keep 4.2.0 available for
rollback and settlement of its existing escrows.

### What is new

- **New store.** The gateway reads none of the 4.2.0 state. Do not import v4.2
  escrows or attach both gateways to the same storage.
- **Client access is closed by default.** A model with no `access` under
  `models` answers only the admin key. Client keys are created through the
  admin API and kept in `gateway.db` in plain text: the volume and its backups
  are secret.
- **Settings.** `POST /v1/admin/settings` changes only the fields it names.
  `PUT` replaces the whole document and drops what it omits. Use `POST`.
- **Keys by name.** `private_key_env` names the environment variable that
  holds the key.
- **Rotation.** `rotation_enabled` and `rotation_models_json` replace
  `escrow_rotation`. Escrow roles: `regular`, `temp` (bridges the epoch
  switch) and `reserve`. A planner creates and retires regular escrows inside
  the epoch.
- **Settlement of the previous epoch.** The gateway settles its own escrows
  once their epoch is over.
- **Accounting API is off by default.** It must be enabled.
- **Status.** `/v1/status` has no `limiter.models.*`. Capacity is in
  `capacity[]`; in-flight requests per model are on `/metrics`.
- **Ignored variables.** `DEVSHARD_ROUTE_PREFIX`, `DEVSHARD_CAPACITY_AWARE_LIMITS`,
  `DEVSHARD_MODEL`, `DEVSHARD_ESCROW_ID` and the Postgres settings are not read.

### 1. Prepare

- Save the current Compose configuration, image digest and full admin settings.
- Check free disk/RAM and choose two unused loopback ports: API and accounting.
- Check the chain registry for `v6`:
```bash
curl -fsS https://rpc.gonka.gg/chain-api/productscience/inference/inference/devshard_approved_versions
```
- Chain endpoints. The gateway needs a CometBFT RPC, a gRPC endpoint and the
  public API. Use your own node, or a public gRPC endpoint over TLS with
  `CHAIN_GRPC_TLS=true`. Do not carry over `DEVSHARD_CHAIN_GRPC: none` from
  4.2.0: this gateway reads it as an address. The gateway keeps working over
  RPC while gRPC is unreachable.
- On a host without a node manager set `DEVSHARD_PARAMS_SOURCE=chain`.
  Otherwise network parameters arrive about 90 seconds late and the log fills
  with failed long polls.
- Fund the wallet. When rotation starts, each model buys `target_count` +
  `reserve_count` escrows, and `temp_count` more before every epoch switch.
  With the values in section 3 that is 13 × 2.5 GNK per model before any
  refund comes back from settlement. A create the wallet cannot pay for is refused.
- Adapt everything that reads the gateway before the switch: a front that takes
  per-model limits from `/v1/status`, monitoring, exporters and operator tools.
  Per-model limit = `capacity[].current_weight` / 10 000 ×
  `capacity[].max_concurrent_requests_per_10000_weight`. Per-model in-flight =
  `devshard_gateway_inflight_requests_by_model` on `/metrics`. Do not sum
  `devshards[].active_requests`: it also counts requests that wait for timeout
  votes and runs above the limiter's figure, 1.3–1.5 times in our case.

### 2. Start the new gateway

Set `GATEWAY_V6_PORT`, `GATEWAY_V6_STATS_PORT`, `GATEWAY_V6_GOMEMLIMIT`,
`GATEWAY_V6_ROTATION_MODELS_JSON` (section 3) and the required keys in your
deployment environment. Add `docker-compose.v6.yml`:

```yaml
services:
  gateway-v6:
    image: ghcr.io/gonka-ai/devshard-gateway@sha256:c76de1bdc341273fa749597294b9b4db807c29821959424351cd171cdfd08e0f
    restart: unless-stopped
    stop_grace_period: 30s
    environment:
      GOMEMLIMIT: ${GATEWAY_V6_GOMEMLIMIT:?required}
      DEVSHARD_PORT: "8080"
      DEVSHARD_ADMIN_API_KEY: ${DEVSHARD_ADMIN_API_KEY:?required}
      DEVSHARD_PRIVATE_KEY: ${DEVSHARD_PRIVATE_KEY:?required}
      DEVSHARDS_JSON: ""
      DEVSHARD_CHAIN_ID: gonka-mainnet
      DEVSHARD_CHAIN_RPC: https://rpc.gonka.gg/chain-rpc
      DEVSHARD_CHAIN_GRPC: rpc.gonka.gg:9090
      CHAIN_GRPC_TLS: "true"
      DEVSHARD_PUBLIC_API: https://rpc.gonka.gg
      DEVSHARD_PARAMS_SOURCE: chain
      DEVSHARD_STORAGE_DIR: /root/.devshard-gateway
      DEVSHARD_SESSION_RETENTION_EPOCHS: "2"
      DEVSHARD_TX_GAS_LIMIT: "700000"
      DEVSHARD_LOG_FORMAT: json
      DEVSHARD_POC_REQUEST_MODE: relaxed
      DEVSHARD_STATS_ENABLED: "true"
      DEVSHARD_STATS_PORT: "9091"
      DEVSHARD_STATS_RETENTION_EPOCHS: "2"
      DEVSHARD_ESCROW_ROTATION_ENABLED: "false"
      DEVSHARD_ESCROW_ROTATION_SETTLEMENT_ENABLED: "false"
      DEVSHARD_ESCROW_ROTATION_PREVIOUS_EPOCH_SETTLEMENT_ENABLED: "true"
      DEVSHARD_ESCROW_ROTATION_PRE_POC_BLOCKS: "300"
      DEVSHARD_ESCROW_ROTATION_MODELS_JSON: ${GATEWAY_V6_ROTATION_MODELS_JSON:?required}
      GATEWAY_MAX_CONCURRENT_REQUESTS: "2048"
      GATEWAY_DEFAULT_MAX_TOKENS: "4096"
      GATEWAY_MAX_TOKENS_CAP: "4096"
    volumes:
      - gateway_v6_data:/root/.devshard-gateway
    ports:
      - "127.0.0.1:${GATEWAY_V6_PORT:?required}:8080"
      - "127.0.0.1:${GATEWAY_V6_STATS_PORT:?required}:9091"
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:8080/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

volumes:
  gateway_v6_data:
```

Every variable the file does not set keeps the gateway default. Do not copy
timeouts, queue sizes or concurrency values from the 4.2.0 service.

- `GOMEMLIMIT`: the default template ships 3400MiB. With about 600 requests in
  flight the process held 5–5.5 GiB, so we run 12GiB. Size it to your load and
  to the RAM you can give.
- `DEVSHARD_STATS_ENABLED: "true"` turns on the accounting API on port 9091.
  It is off by default. Keep it on.
- `GATEWAY_MAX_TOKENS_CAP`: raise it only if your clients need longer answers.

Include any additional overlays required by your deployment in every command.
Start only the new service; leave the front on 4.2.0.
```bash
docker compose -f docker-compose.yml -f docker-compose.v6.yml config --quiet
docker compose -f docker-compose.yml -f docker-compose.v6.yml pull gateway-v6
docker compose -f docker-compose.yml -f docker-compose.v6.yml \
  up -d --no-deps --no-build gateway-v6

A="http://127.0.0.1:${GATEWAY_V6_PORT:?required}"
H="Authorization: Bearer ${DEVSHARD_ADMIN_API_KEY:?required}"
curl -fsS "$A/v1/status"
```
The log must show `gateway started` with `version v6`. A `healthy` container
means the process answers, not that it serves chat.

### 3. Configure

#### Required settings

**Open the models to clients.** Create the client key first, then set
`access` for every offered model. In the other order the settings write answers
400: an `api_key` model needs an active key. Until both are done, client keys
get 401.
```bash
curl -fsS -X POST "$A/v1/admin/api-keys" -H "$H" -H 'Content-Type: application/json' \
  -d '{"label":"front","key":"<FRONT_KEY>"}'
curl -fsS -X POST "$A/v1/admin/settings" -H "$H" -H 'Content-Type: application/json' \
  -d '{"models":{"<MODEL_ID>":{"access":"api_key"}}}'
```
`<FRONT_KEY>` is the key your front already sends: at least 16 characters, not
the admin key. Without `key` the gateway generates one and returns it.

**Use the gateway defaults for concurrency per 10,000 weight. Do not set the
variables, do not add overrides and do not copy higher values from the old
gateway:**

- Inference: `max_concurrent_requests_per_10000_weight: 5`.
- PoC: `poc_max_concurrent_requests_per_10000_weight: 10`.

Check that `capacity[].max_concurrent_requests_per_10000_weight` in
`/v1/status` reads 5.

**Automatic settlement inside the current epoch must be disabled. Settlement
of the previous epoch must be enabled:**

- `DEVSHARD_ESCROW_ROTATION_SETTLEMENT_ENABLED: "false"` — a retired escrow is
  parked and is not settled in its own epoch.
- `DEVSHARD_ESCROW_ROTATION_PREVIOUS_EPOCH_SETTLEMENT_ENABLED: "true"` — the
  gateway settles parked escrows once their epoch is over.
- No `settlement_enabled` or `previous_epoch_settlement_enabled` in any
  `rotation_models_json` entry, and no `rotation_settlement_enabled` or
  `rotation_previous_epoch_settlement_enabled` in the admin settings.

**The accounting API must be enabled:** `DEVSHARD_STATS_ENABLED: "true"`.

**Every escrow is 2.5 GNK and every model keeps 4 temp escrows:**
`"amount": 2500000000` and `"temp_count": 4` in every `rotation_models_json`
entry.

#### Rotation models

`GATEWAY_V6_ROTATION_MODELS_JSON` is one JSON array with an entry per offered
model. In a Compose `.env` file put the array on one line inside single quotes.
The values to run:

```json
[{"model_id": "<MODEL_ID>", "target_count": 8, "temp_count": 4, "reserve_count": 1,
  "amount": 2500000000, "private_key_env": "DEVSHARD_PRIVATE_KEY", "max_unsettled": 512}]
```

| Field | Value | Why |
| --- | --- | --- |
| `target_count` | 8 | Regular escrows the model keeps. Size it to your load. |
| `temp_count` | 4 | Temp escrows bought 300 blocks before the epoch switch. Use 4. **Never 0**: with 0 the gateway parked every regular and reserve escrow in the window before the switch and bought nothing, and all models answered 503 `no escrow capacity` for 25 minutes. |
| `reserve_count` | 1 | A full standby escrow, taken only when no regular one can pay for a request. Once taken, the planner buys another. |
| `amount` | 2500000000 | 2.5 GNK, the deposit in ngonka. Use this value. |
| `private_key_env` | `DEVSHARD_PRIVATE_KEY` | Required in every entry. Without it no create can be signed. |
| `max_unsettled` | 512 | Parked escrows count against it until they are settled, which happens only after the epoch ends. The default (target + temp + reserve + 4) filled on the first day under load: the planner stopped creating and models answered 503 `no escrow capacity: insufficient escrow balance`. |

Later changes go through `POST /v1/admin/settings` with `rotation_models_json`
(the same array as a string). They apply without a restart and survive it.
Mirror them into the environment so a fresh store boots with the same values.
Always send the full array with `private_key_env` in every entry.

```bash
curl -fsS "$A/v1/admin/settings" -H "$H" > settings-v6-confirmed.json
```

### 4. Create and check new escrows

Rotation is still off. Create one 2.5 GNK escrow per offered model. Set
`MODEL` to the exact model ID:
```bash
curl -fsS -X POST "$A/v1/admin/escrows" -H "$H" \
  -H 'Content-Type: application/json' \
  -d "{\"model_id\":\"${MODEL:?required}\",\"amount\":2500000000,\"private_key_env\":\"DEVSHARD_PRIVATE_KEY\",\"activate\":true}"
```
402 means the wallet cannot pay the amount plus the fee; nothing was broadcast.
Save each ID and transaction hash. Confirm `code=0`, creator, epoch, model and
amount on chain before continuing.

Using the client gateway key, check each offered model:

- Non-stream response with valid content.
- SSE with content, finish reason and stream termination.
- Structured tool call.

Change the prompt between attempts: the gateway caches responses for an hour,
keyed by request body, client key and escrow.

Check `session_version: v6`, nonce advancement and `phase: active` in
`/v1/status`, and the row in `GET /v1/admin/devshards`. Check that
`GET /api/v1/epochs` answers on the accounting port. Resolve failures before
moving traffic.

### 5. Switch traffic

Pick the moment: Inference phase, no confirmation PoC running, more than 1500
blocks before the epoch switch, wallet funded.

1. Enable rotation on the new gateway and wait for the pool. Unlike 4.2.0, the
   planner funds an empty pool in the middle of an epoch; ours reached 8
   regular + 1 reserve per model in about four minutes.
```bash
curl -fsS -X POST "$A/v1/admin/settings" -H "$H" -H 'Content-Type: application/json' \
  -d '{"rotation_enabled":true}'
curl -fsS "$A/v1/admin/devshards" -H "$H"
```
2. Update inference and accounting together. For a front using these variables
   on the same Docker network:
```text
GATEWAY_URL=http://gateway-v6:8080/v1
GONKA_ACCOUNTING_URL=http://gateway-v6:9091
```
   Preserve the existing upstream mode and required overlays. Recreate only the
   front service. A restart may interrupt open SSE connections.
3. Disable rotation on 4.2.0 at once. Both gateways spend the same wallet while
   both rotate. Keep automatic settlement disabled there.
4. Verify client requests and accounting through the front. Observe
   availability, errors, latency, resources and escrow creation under normal
   traffic.
5. Update monitoring URLs, targets, exporter volume mounts and operator tools
   to the new slot. Metric names, admin API fields and the store schema differ
   from 4.2.0.

### Rollback

1. Check that the old pool can serve traffic. After an epoch switch with old
   rotation off, 4.2.0 holds no escrows of the current epoch.
2. Restore old inference and accounting upstreams; recreate only the front.
3. Restore old rotation. Post `{"rotation_enabled":false}` to the new gateway.
4. Restore monitoring and operator targets.
5. Keep the new gateway and volume until its escrows are settled.

Do not run the old binary on new-version storage or remove either volume.
