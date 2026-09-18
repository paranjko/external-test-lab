# OPS: publish network status

OPS runs the status site, Grafana and the Telegram inference consumer. These
services observe the network; they do not create Hosts or change chain state.

OPS is the only role that requires `.env`. Store it with runtime data, outside
the runbook directory:

```bash
mkdir -p "$HOME/.gdc-data"
cp .env.example "$HOME/.gdc-data/.env"
```

The default data root is `$HOME/.gdc-data`. To place it elsewhere,
export `GDC_HOME=/absolute/path` before running `gdc.sh` and store the file as
`$GDC_HOME/.env`.

Set the OPS host inventory and `GDC_GRAFANA_ADMIN_PASSWORD`. Set
`TELEGRAM_BOT_TOKEN` only when the Telegram consumer is used. All other
settings already have defaults unless the deployment needs an override.
Grafana public-share identifiers and the Telegram public URL belong to OPS;
they are not published through Genesis bootstrap or stored in Host inventory.

## Deploy

```bash
gdc ops monitoring
gdc ops site
gdc ops edge
gdc ops consumer telegram apply
```

The site and Grafana remain separate from validator lifecycle. A chain reset
must leave them online and showing the current state, including an unavailable
network or gateway.

## After a merge

Nothing on a Host follows `main` on its own except the static site, which
`site-publish` deploys from CI. Every other OPS change reaches the network only
when the operator runs the phase again. Run the phase that owns the changed
paths:

| Changed under `net-deployment-runbook/` | Run |
|---|---|
| `04-ops/grafana/**`, `04-ops/edge-node/public-grafana/**`, `04-ops/prometheus/**`, `04-ops/render-ops.sh`, `04-ops/compose.yaml` (monitoring services) | `gdc ops monitoring` |
| `04-ops/site/**` | nothing: `site-publish` runs on push to `main` |
| `04-ops/edge-node/Caddyfile`, `04-ops/edge-node/PublicCaddyfile`, `04-ops/edge-node/compose.yaml`, `04-ops/edge-node/install-edge.sh` | `gdc ops edge` |
| `04-ops/edge-node/gateway-admission*`, `04-ops/gateway*`, `04-ops/create-gateway.sh` | `gdc gateway apply <version>` |
| `04-ops/faucet/**` | `gdc ops faucet` |
| `scripts/telegram-bot/**`, `scripts/deploy-telegram-bot.sh` | `gdc ops consumer telegram apply` |

`gdc ops monitoring` ends with `scripts/verify-public-grafana.sh`, which fails
when a served dashboard differs from the committed definition. The same script
can run on its own at any time to check for drift.

## Verify

```bash
curl -fsS https://gonka-dev.net/ >/dev/null
curl -fsS https://grafana.gonka-dev.net/login >/dev/null
gdc ops consumer telegram verify
```
