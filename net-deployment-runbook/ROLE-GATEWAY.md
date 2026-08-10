# GATEWAY: provide inference access

Gateway exposes the OpenAI-compatible API. It owns its escrow creator,
runtime state and client credentials. It needs an authorised DevShard and an
active chain escrow; it does not need to be a validator.

## Operate

```bash
./gdc.sh gateway apply v3
./gdc.sh gateway reconcile v3
./gdc.sh gateway status
./gdc.sh gateway verify 60s
./gdc.sh gateway continuity
```

`READY` means a real authenticated inference succeeded. A listening process
or an escrow alone is not readiness.

The reconciler replaces expired or settled escrow, waits for chain and
DevShard readiness, then returns the runtime to service. During recovery the
public state must say `RECOVERING` or `UNAVAILABLE`, not `READY`.

## Client credential for the OPS consumer

```bash
./gdc.sh gateway access-key ensure telegram
./gdc.sh gateway access-key list
./gdc.sh gateway access-key revoke telegram
```

These commands never print key material. Client keys authenticate API access;
they are not wallets or GNK tokens.
