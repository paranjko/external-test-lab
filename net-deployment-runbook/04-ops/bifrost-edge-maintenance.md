# Scoped stable-edge maintenance

Use this only for an existing `bifrost-edge` in the same Compose project.
Verify its running environment matches the private env file, its network is
`host`, and it has no data mounts. Preserve the old image ID for rollback.
Do not display environment values or change client keys.

After `make test-bifrost-protocol-edge test-bifrost-pinned-lifecycle` passes
in `net-deployment-runbook`, stage this directory's Dockerfile, edge source
and maintenance composition together on the target. Build the tested source:

```sh
export BIFROST_EDGE_MAINTENANCE_IMAGE="$(docker build -q -f Dockerfile.bifrost-edge .)"
export BIFROST_EDGE_MAINTENANCE_ENV=/srv/dai/ops/bifrost-edge.env
docker compose -p gdc-ops -f compose.bifrost-edge-maintenance.yaml \
  up -d --no-deps bifrost-edge
```

Never use `down` or `--remove-orphans` on the shared OPS project. Other
services are deliberately absent. Verify their container identities are
unchanged. Roll back with the same command and the saved old image ID.

The edge maps `X-Request-Deadline-Ms` to the pinned adapter's upstream header.
It does not bypass admission or shorten protocol fences. The health probe
allows 15 seconds for admission and 20 seconds overall, leaving time to
return a real pre-dispatch refusal. During PoC a refusal is not proof of
successful inference; rerun the JSON/SSE smoke when admission is eligible.
