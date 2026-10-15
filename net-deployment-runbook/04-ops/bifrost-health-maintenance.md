# Existing stable broker and health-probe maintenance

This procedure updates an existing broker without reconciling the rest of OPS.
It does not bootstrap Bifrost, change provider bindings, rotate user keys, or
create blockchain escrows. Use an approved, locally verified source snapshot.

Before applying, privately retain the existing broker image ID, its effective
environment, Compose project name, mount identities and the health service
configuration. Verify that the environment file matches the running broker,
especially the encryption key and database path. Never print that environment.
The supported broker runs as `65532:65532` on host networking, with the existing
database volume mounted at `/var/lib/bifrost-broker` and a read-only binding at
`/run/bifrost/broker-binding.env`. Refuse mismatched layouts instead of guessing.

Build `Dockerfile.bifrost-broker` from the verified `04-ops` source directory.
Set these non-secret parameters to the inspected existing deployment:

```sh
export BIFROST_BROKER_MAINTENANCE_IMAGE=sha256:REPLACE_WITH_TESTED_IMAGE_ID
export BIFROST_BROKER_MAINTENANCE_ENV=/srv/dai/ops/bifrost-broker.env
export BIFROST_BROKER_MAINTENANCE_BINDING=/srv/dai/ops/bifrost/broker-binding.env
export BIFROST_BROKER_MAINTENANCE_VOLUME=gdc-ops_bifrost-broker-data
docker compose -p gdc-ops -f compose.bifrost-broker-maintenance.yaml \
  up -d --no-deps bifrost-broker
```

Use the actual existing project name if different. Never add `--remove-orphans`
or run `down`: other OPS containers are deliberately absent from this file.
Verify the broker is running and that user authentication still resolves before
changing the public health service. Roll back the broker with the same command
and retained old image ID; do not restore an old database over current state.

Create the dedicated health credential through the shipped offline entrypoint:

```sh
docker compose -p gdc-ops -f compose.bifrost-broker-maintenance.yaml \
  exec -T bifrost-broker python3 /srv/broker/bifrost-broker-service.py \
  --write-health-env /var/lib/bifrost-broker/health.env
```

The destination must not exist. The file is mode0600 and contains the stable
operator key and model. Copy it privately to the health service's environment
path; never paste it into logs or an issue. An uncertain creation leaves pending
intent in SQLite and refuses retry: reconcile the management virtual-key state
before further issuance. A completed identity can be exported to a different
new private file without creating another virtual key. User key rotation does
not replace this identity. Keep the binding's model aligned with the admitted
model and the provider's allowed models before issuance.

For `gateway-health-probe.sh`, set:

- `GDC_GATEWAY_HEALTH_ROUTE=stable`;
- `GDC_GATEWAY_ENV` to the private health credential file;
- `GDC_GATEWAY_HEALTH_URL` to the canonical public origin, without `/v1`;
- `GDC_GATEWAY_STATUS_URL` to the selected admission origin;
- `GDC_GATEWAY_STATUS_ENV` to its distinct native assurance credential file.

Keep the existing reserve/reconciliation guards and output paths. Both status
and completion requests must resolve to the same selected runtime. A successful
stable check requires the expected response model, native request/escrow IDs,
the admission receipt, ordered heights, routable status and adequate reserve.
PoC fences remain unavailable; no cached success or process health substitutes
for a completion. Verify the generated JSON and public endpoint after applying,
then observe both usable and fenced windows before claiming sustained readiness.
