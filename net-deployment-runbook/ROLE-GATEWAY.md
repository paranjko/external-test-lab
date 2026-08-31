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

## Observe a side-by-side DevShard migration

Run the source and target gateways with different ports and storage volumes,
then use the migration observer before changing client traffic:

```bash
gdc --composition <TARGET_COMPOSITION> gateway migrate preflight v4 v5
gdc --composition <TARGET_COMPOSITION> gateway migrate verify v4 v5
gdc --composition <TARGET_COMPOSITION> gateway migrate drain v4 v5
```

`preflight` binds both approved binaries and checks the safe Inference window.
`verify` additionally requires separate target state, frozen escrow lifecycle,
positive target capacity and direct authenticated inference. After a separate
traffic cutover, `drain` passes only when the source has no global or
per-escrow requests in flight. These commands are read-only: they do not stage
a gateway, create an escrow or change the public route.

The target may use a public RPC with a trailing slash and `gRPC=none`, or the
real RPC and gRPC endpoints of a colocated chain node. An unauthenticated
statistics listener outside loopback fails the check.

## Client credential for the OPS consumer

```bash
gdc gateway access-key ensure telegram
gdc gateway access-key list
gdc gateway access-key revoke telegram
```

These commands never print key material. Client keys authenticate API access;
they are not wallets or GNK tokens.
