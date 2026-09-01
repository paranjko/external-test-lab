# GATEWAY: provide inference access

Gateway exposes the OpenAI-compatible API. It owns its escrow creator,
runtime state and client credentials. It needs an authorised DevShard and an
active chain escrow; it does not need to be a validator.

## Operate

```bash
gdc gateway apply v3
gdc gateway reconcile v3
gdc gateway status
gdc gateway verify 60s
gdc gateway continuity
```

`READY` means a real authenticated inference succeeded. A listening process
or an escrow alone is not readiness.

The reconciler replaces expired or settled escrow, waits for chain and
DevShard readiness, then returns the runtime to service. During recovery the
public state must say `RECOVERING` or `UNAVAILABLE`, not `READY`.

## Migrate between DevShard protocols

The workflow implements the operational contract from the pinned
[DevShard v4 gateway migration guide](https://github.com/paranjko/gonka/blob/825c6f1616d22c10012cd5d3668452898c15f7b6/devshard/docs/devshard-v4-migration.md).

Use the retained migration workflow instead of replacing a running gateway in
place. The target starts beside the source with a different image, port and
fresh state volume, initially with `DEVSHARDS_JSON=[]`. `prepare` waits for a
safe Inference window, freezes source rotation and settlement, then creates
the route-bound target escrow through the target's authenticated admin API.
The request names the model and `/devshard/<version>` route explicitly and
references the private key by its environment variable; it never sends key
material or a `protocol_version` field. The target must pass authenticated
admin-state checks and direct inference before public traffic can move.

```bash
gdc --composition <COMPOSITION> gateway migration prepare v5
gdc --composition <COMPOSITION> gateway migration status
gdc --composition <COMPOSITION> gateway migration cutover
gdc --composition <COMPOSITION> gateway migration drain
gdc --composition <COMPOSITION> gateway migration complete
```

`cutover` changes only the public upstream. `drain` waits for both the global
and every escrow in-flight counter on the source to be present and reach zero;
missing counters or the retained escrow are not treated as an empty gateway.
Route changes stop public admission before rebinding the observer and upstream,
then restart it only after both identify the same runtime. `complete` keeps
admission closed, rechecks both drains and promotes the verified target to the
canonical gateway service without deleting the source volume.

Before `complete`, the migration can be reversed:

```bash
gdc --composition <COMPOSITION> gateway migration rollback
```

Rollback restores the prior public route and source lifecycle settings. It
does not delete the target container or either protocol-specific state volume.
The retained transition phases make a partially committed cutover reversible
and a failed canonical promotion resumable. A promotion failure restores the
source and side-by-side target when possible; otherwise the next `complete` or
`rollback` first reconciles that intermediate state instead of guessing which
runtime owns the canonical port.
Repeating `prepare` resumes the same retained target and escrow after an
interruption or rollback. It first resolves a unique existing escrow by model
and route, refuses changed image, volume, route or escrow identity, and does
not repeat an escrow-creation request whose outcome is ambiguous.
Do not infer a safe drain from public `/v1/status`; its response shape differs
between DevShard versions. The runbook uses authenticated `/v1/admin/state`
state and keeps the unauthenticated statistics port unpublished.

## Client credential for the OPS consumer

```bash
gdc gateway access-key ensure telegram
gdc gateway access-key list
gdc gateway access-key revoke telegram
```

These commands never print key material. Client keys authenticate API access;
they are not wallets or GNK tokens.
