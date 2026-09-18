# Devshard gateway 4.1.1 — broker guide

From any current setup (v3, v4, v4.1) to a running 4.1.1 gateway with a public
accounting link. One pass, top to bottom. Your existing gateway is not
touched; at the end you only repoint the front at the new one.

Release: [`release/gateway/v4.1.1`](https://github.com/gonka-ai/gonka/releases/tag/release/gateway/v4.1.1)
(gonka-ai/gonka, 2026-09-15). It publishes two tags of the same image:

```
ghcr.io/gonka-ai/devshard-gateway:mainnet-v0.2.15-v4.1.1
ghcr.io/gonka-ai/devshard-gateway:mainnet-v0.2.15-v4.1.1-latest
```

Both resolve to index digest `sha256:80f79d2226838eb21c951fe79c2e2c76308f0a5930eb83c37098ee95c8dc0fdc`
(checked 2026-09-16) — pin the digest, not the tag. As of 2026-09-16 there is
**no gateway v5 image**: `devshard/v5.0.0` on the releases page is the
host-side binary (pre-release), not a gateway. 4.1.1 is the current gateway.

What you get: protocol `v4.1` (route prefix `/devshard/v4.1`), a working
**accounting ledger** (per-epoch stats for external dashboards such as
vesogonka), and the same admin API as 4.x.

**Plan:** new container on a **fresh volume** next to the old one → settings →
mint → smoke → switch the front → expose accounting.

---

## 0. Before you start

You need:

- `GATEWAY_API_KEY` — the key your clients use (any string you choose).
- `DEVSHARD_ADMIN_API_KEY` — admin key (another string; keep it off the internet).
- `DEVSHARD_PRIVATE_KEY` — hex private key of the wallet that pays for escrows.
  Balance: a few GNK per escrow, one escrow per model minimum.
- A JSON-RPC endpoint. Public `https://rpc.gonka.gg/chain-rpc/` works
  (**trailing slash required**). If you run your own node, use it.

Pick the **window**: Inference phase only, not PoC / cPoC, with enough blocks
left before `next_poc_start` to mint and smoke (say ≥ 1500 blocks).

```bash
curl -sS https://rpc.gonka.gg/v1/epochs/latest \
  | jq '{phase, epoch: .epoch_stages.epoch_index, next_poc: .epoch_stages.next_poc_start, height: .block_height}'
```

---

## 1. Container

Pin the multi-arch **index** digest (plain `docker manifest inspect` prints a
single-platform digest — it works, but differs from what others see):

```bash
docker pull ghcr.io/gonka-ai/devshard-gateway:mainnet-v0.2.15-v4.1.1
docker buildx imagetools inspect ghcr.io/gonka-ai/devshard-gateway:mainnet-v0.2.15-v4.1.1 | grep -m1 Digest
```

Add to your compose (names and host ports are yours; the old gateway stays
untouched):

```yaml
  devshardctl-v411:
    image: ghcr.io/gonka-ai/devshard-gateway@sha256:<digest>
    restart: unless-stopped
    environment:
      DEVSHARD_PORT: "8080"
      DEVSHARD_API_KEYS: ${GATEWAY_API_KEY}
      DEVSHARD_ADMIN_API_KEY: ${DEVSHARD_ADMIN_API_KEY}
      DEVSHARD_PRIVATE_KEY: ${DEVSHARD_PRIVATE_KEY}
      DEVSHARDS_JSON: "[]"
      DEVSHARD_CHAIN_ID: gonka-mainnet
      DEVSHARD_CHAIN_RPC: https://rpc.gonka.gg/chain-rpc/
      DEVSHARD_CHAIN_GRPC: none                     # public RPC covers tx + query
      DEVSHARD_PUBLIC_API: https://node3.gonka.ai
      DEVSHARD_ROUTE_PREFIX: /devshard/v4.1
      DEVSHARD_STORAGE_DIR: /root/.devshardctl
      DEVSHARD_TX_GAS_LIMIT: "700000"
      DEVSHARD_CAPACITY_AWARE_LIMITS: "on"
      DEVSHARD_POC_REQUEST_MODE: relaxed
      DEVSHARD_STATS_ENABLED: "true"                # accounting ledger on :9091
      # DEVSHARD_STATS_PORT: "9091"
      # DEVSHARD_STATS_RETENTION_EPOCHS: "…"
      # DEVSHARD_STATS_SNAPSHOT_SECONDS: "…"
      DEVSHARD_ESCROW_ROTATION_ENABLED: "false"     # keep off until you have watched burn
      DEVSHARD_ESCROW_ROTATION_SETTLEMENT_ENABLED: "false"
    volumes:
      - devshard_v411_data:/root/.devshardctl      # NEW volume — never reuse a v3/v4 one
    ports:
      - "127.0.0.1:18085:8080"                     # API + admin: loopback only
      - "127.0.0.1:9091:9091"                      # accounting: loopback only

volumes:
  devshard_v411_data:
```

Own chain node with gRPC? Point `DEVSHARD_CHAIN_RPC` / `DEVSHARD_CHAIN_GRPC`
at it instead of `none` + public RPC. Do not mix the two.

```bash
docker compose up -d devshardctl-v411
export A=http://127.0.0.1:18085 H="Authorization: Bearer $DEVSHARD_ADMIN_API_KEY"
curl -fsS $A/v1/status -H "$H" | jq .runtimes
curl -fsS http://127.0.0.1:9091/api/v1/epochs | jq .       # {"epochs":[]} — ledger is empty, fine
```

---

## 2. Settings

A fresh `gateway.db` starts with every model **`admin_only`** and a
`default_model` you may not serve. Clients would get:

```text
401  model "<id>" requires an admin API key
```

Read, edit, write back the **whole** document (no PATCH):

```bash
curl -fsS $A/v1/admin/settings -H "$H" > settings.json
```

Edit these fields in `settings.json`, leave everything else as it came:

```json
{
  "default_model": "<MODEL_A>",
  "max_concurrent_requests": 512,
  "max_concurrent_requests_per_10000_weight": 5,
  "model_limits": [
    { "model_id": "<MODEL_A>", "max_concurrent_requests": 0, "max_input_tokens_in_flight": 0, "access_mode": "api_key" },
    { "model_id": "<MODEL_B>", "max_concurrent_requests": 0, "max_input_tokens_in_flight": 0, "access_mode": "api_key" }
  ],
  "escrow_rotation": { "enabled": false, "settlement_enabled": false }
}
```

- `access_mode`: `open` / `api_key` / `admin_only`. One entry per model you serve.
- `max_concurrent_requests_per_10000_weight` is how hard you push each host. Use 5 (stock).
- Keep both `escrow_rotation` flags `false`.
- Do not set `escrow_rotation.settlement_enabled` to `true`.

```bash
curl -fsS -X POST $A/v1/admin/settings -H "$H" -H 'Content-Type: application/json' --data-binary @settings.json
curl -fsS $A/v1/admin/settings -H "$H" | jq '{default_model, model_limits}'
```

---

## 3. Mint escrows

Clients are still on the old gateway; nothing changes for them yet.

```bash
curl -fsS -X POST $A/v1/admin/escrows -H "$H" -H 'Content-Type: application/json' -d '{
  "amount": 5000000000,
  "model_id": "<MODEL_A>",
  "private_key_env": "DEVSHARD_PRIVATE_KEY",
  "route_prefix": "/devshard/v4.1",
  "register": true
}'
sleep 12
# repeat per model / per extra escrow
```

- `amount` is ngonka: `5000000000` = 5 GNK, `2500000000` = 2.5 GNK.
- **Always** pass `model_id` and `route_prefix`. Without the prefix the escrow
  lands on the default slot; `protocol_version` in the body is ignored.
- One tx at a time, 8–12 s apart — a second tx too soon dies on account query.
- One escrow per model is enough to start; more = redundancy. Each escrow
  carries a nonce budget (~20k) and a GNK balance; when either runs out it
  stops serving and you mint another.

Wait ~30 s, then check:

```bash
curl -fsS $A/v1/status -H "$H" | jq '{models: .capacity.models,
  escrows: [.devshards[]? | {id, model, active, session_version, nonce}]}'
```

Every offered model should show `routable: true`, escrows `session_version: "v4.1"`.

**Tx hash but `escrow not found` / escrow missing from the list?** The chain
object exists, the gateway lost the register. Do **not** mint again. Import:

```bash
curl -fsS -X POST $A/v1/admin/devshards -H "$H" -H 'Content-Type: application/json' -d '{
  "id": "<ESCROW_ID>", "escrow_id": "<ESCROW_ID>", "model_id": "<MODEL_A>",
  "private_key_env": "DEVSHARD_PRIVATE_KEY", "route_prefix": "/devshard/v4.1",
  "register": true, "storage_path": "escrow-<ESCROW_ID>"
}'
curl -fsS -X POST $A/v1/admin/devshards/<ESCROW_ID>/activate -H "$H"
```

`409 already active` = it was loaded after all.

---

## 4. Smoke with the client key

Admin-key 200 proves nothing. Use the key your clients use, per model:

```bash
curl -fsS -X POST $A/v1/chat/completions \
  -H "Authorization: Bearer $GATEWAY_API_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"<MODEL_A>","max_tokens":16,"messages":[{"role":"user","content":"pong"}]}'
```

401 here → back to §2 (`access_mode`). `unsupported model` → no active escrow
for that model (§3).

---

## 5. Switch client traffic

Repoint your front (proxy `GATEWAY_URL`, nginx `upstream`, …) at the new
gateway. Which address depends on where the front runs — use the same rule
for the accounting upstream in §6:

| Front runs… | Gateway API upstream | Accounting upstream |
|---|---|---|
| in the same Docker Compose network | `http://devshardctl-v411:8080` | `http://devshardctl-v411:9091` |
| on the host (or another network) | `http://127.0.0.1:18085` | `http://127.0.0.1:9091` |

Recreate only the front. Keep the old gateway **running** — in-flight streams
finish there, and its escrows are still yours to handle. Do not touch its
volume.

Watch for a few minutes: request rate on the new port, `409`/`502` in its
logs, `curl $A/v1/status` nonces climbing.

---

## 6. Public accounting link

### What the ledger serves on `:9091`

| GET | Content | Size |
|-----|---------|------|
| `/api/v1/epochs` | index: per epoch `assigned_nonces`, `dispositions`, `protocol_misses`, `recording_errors` | ~1 KB |
| `/api/v1/epochs/{n}/participants` | per host × model: nonces, dispositions, misses, validations | 60 KB – 2 MB |
| `/api/v1/epochs/{n}/events` | raw per-nonce events (`escrow_id`, `participant`, `nonce`, `kind`, `at`) | 1–3 MB |
| `/api/v1/epochs/{n}/events/{participant}` | same, one host | — |

The port itself is bare: no authentication, no compression, read-only. So do
not publish `:9091` to the internet. Put your nginx / Caddy in front of it and
let the proxy do three things the ledger does not:

1. allow only `GET` (reject everything else with 405);
2. forward only the `/api/v1/epochs…` paths, nothing else from that port;
3. gzip the responses (a 2 MB `participants` becomes ~120 KB).

### URL scheme

```
https://<your-domain>/api/v1/accounting/epochs…  →  http://127.0.0.1:9091/api/v1/epochs…
```

The prefix is a convention; the dashboard takes any base URL with `/epochs…`
under it. The snippets below use `127.0.0.1:9091` (proxy on the host); if
your nginx / Caddy runs inside the Compose network, use `devshardctl-v411:9091`
instead (see the table in §5).

### nginx

```nginx
location ^~ /api/v1/accounting/epochs {
    limit_except GET { deny all; }
    rewrite ^/api/v1/accounting/(.*)$ /api/v1/$1 break;
    proxy_pass http://127.0.0.1:9091;
    proxy_set_header Host $host;
    proxy_read_timeout 60s;
    gzip on;
    gzip_proxied any;
    gzip_types application/json;
    gzip_min_length 1024;
    add_header Cache-Control "public, max-age=30";
}
```

### Caddy

```caddyfile
handle_path /api/v1/accounting/* {
    @epochs {
        method GET
        path /epochs /epochs/*
    }
    handle @epochs {
        encode gzip
        rewrite * /api/v1{uri}
        reverse_proxy 127.0.0.1:9091
    }
    respond 405
}
```

`handle_path` strips `/api/v1/accounting`, leaving `/epochs…`; the rewrite
puts `/api/v1` back so the root query reaches `/api/v1/epochs` without a
trailing slash.

### Verify

```bash
D=https://<your-domain>
curl -fsS "$D/api/v1/accounting/epochs" | jq '.epochs[] | {epoch_index, assigned_nonces}'
# participants exist only once the ledger has recorded an epoch (a few minutes of traffic)
E=$(curl -fsS "$D/api/v1/accounting/epochs" | jq -r '.epochs[-1].epoch_index // empty')
[ -n "$E" ] && curl -sS -o /dev/null -w 'participants: %{http_code} %{size_download}B\n' \
  -H 'Accept-Encoding: gzip' "$D/api/v1/accounting/epochs/$E/participants" \
  || echo 'ledger still empty — retry after some traffic'
curl -sS -o /dev/null -w 'POST must be 405/403: %{http_code}\n' -X POST "$D/api/v1/accounting/epochs"
curl -sS -o /dev/null -w 'admin must NOT be reachable: %{http_code}\n' "$D/v1/admin/settings"
```

Hand the dashboard the **base URL**: `https://<your-domain>/api/v1/accounting`.
Their backend polls `/epochs` and `/epochs/{n}/participants` every 1–3 min
server-side; browsers never hit you, no CORS needed.

Optional: per-IP rate limit (30–60 req/min is plenty), 30 s cache, a partner
token (`Authorization: Bearer <secret>` checked on the proxy — 401 the heavy
paths without it, keep `/epochs` open).

---

## Pitfalls

**Reusing a v3/v4 volume or `DEVSHARD_ROUTE_PREFIX=/devshard/v4`.** Escrows
land on the wrong slot; hosts answer `409 session version conflict`. Fresh
volume, prefix `/devshard/v4.1`.

**Traffic switched, no escrows.** `unsupported model` for everything. Mint
first (§3), switch last (§5).

**`admin_only`.** The first 401 after a "successful" mint. §2.

**`DEVSHARD_CHAIN_GRPC` left unset.** The binary persists `localhost:9090`
into `gateway.db` and probes a dead endpoint forever. Set `none` on public RPC.

**Public RPC returning HTML.** `invalid character '<'` on account/escrow
queries = the RPC answered an nginx error page or a redirect (a missing
trailing slash used to `301` and turn the POST into a GET; keep the slash
even if the endpoint accepts both today). Use `https://rpc.gonka.gg/chain-rpc/`
or your own node.

**Minting in PoC / right before `next_poc`.** Validator set is moving; wait
for Inference.

**Rotation.** When enabled it replaces a shard on low balance or high nonce
and leaves the old deposit locked, and it does not bootstrap from zero. Leave
both flags off until you have watched nonce vs GNK burn for a few epochs;
first escrows are always a manual mint. This also holds when you **add a
model** to a gateway that already rotates: a new `model_id` in settings gets
no escrow from the rotator mid-epoch — mint it by hand (§3), the rotator
picks it up from the next epoch boundary.

**`GET /v1/status` with a single escrow** may render as a legacy card without
`.devshards[]`. Check `/v1/admin/devshards` or list the ids you minted.

---

## Rollback

Point the front back at the old gateway. The 4.1.1 escrows stay on chain and
in the new gateway's volume. Do not `compose down` or remove volumes to "undo".
