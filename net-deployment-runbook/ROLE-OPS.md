# OPS: publish network status

OPS runs the status site, Grafana and the Telegram inference consumer. These
services observe the network; they do not create Hosts or change chain state.

OPS is the only role that requires `.env`. Store it with runtime data, outside
the runbook directory:

```bash
mkdir -p ../net-deployment-data
cp .env.example ../net-deployment-data/.env
```

The default data root is `../net-deployment-data`. To place it elsewhere,
export `GDC_HOME=/absolute/path` before running `gdc.sh` and store the file as
`$GDC_HOME/.env`.

Set the OPS host inventory and `GDC_GRAFANA_ADMIN_PASSWORD`. Set
`TELEGRAM_BOT_TOKEN` only when the Telegram consumer is used. All other
settings already have defaults unless the deployment needs an override.
Grafana public-share identifiers and the Telegram public URL belong to OPS;
they are not published through Genesis bootstrap or stored in Host inventory.

## Deploy

```bash
./gdc.sh ops monitoring
./gdc.sh ops site
./gdc.sh ops edge
./gdc.sh ops consumer telegram apply
```

The site and Grafana remain separate from validator lifecycle. A chain reset
must leave them online and showing the current state, including an unavailable
network or gateway.

## Verify

```bash
curl -fsS https://gonka-dev.net/ >/dev/null
curl -fsS https://grafana.gonka-dev.net/login >/dev/null
./gdc.sh ops consumer telegram verify
```
