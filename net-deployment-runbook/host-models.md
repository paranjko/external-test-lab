# Host model support

Update the supported model map of one existing broker worker without replacing images, touching keys or restarting consensus

This interface uses an explicit JSON model map, not qualification-only `--model` overlays

```bash
gdc host models plan HOST --node-id WORKER_ID --models models.json --output plan.json
gdc host models apply HOST --plan plan.json
gdc host models rollback HOST --plan plan.json
```

`models.json` contains the complete desired map, including retained models

```json
{"Qwen/example":{"args":["--revision","0123456789abcdef0123456789abcdef01234567"]}}
```

Use only governance-registered models and their exact revisions and reviewed runtime arguments

The ten-minute plan binds the SSH Host, chain, running DAPI binary, container, worker configuration and stored configuration hash, apply rejects drift and repeated attempts

Flat `/srv/dai/deploy`, per-host `/srv/dai/deploy/HOST` and legacy `/srv/dai/node` layouts are discovered from the actual DAPI bind mount, changes preserve other workers and the mounted file inode

Models assigned in the current epoch or retained for older work cannot be changed or removed, active inference locks also prevent an update

Successful configuration is not serving acceptance, model allocations and PoC are controlled by the chain and require separate governance and runtime verification

Backups and attempt receipts remain in `.gdc-model-updates` beside the deployed configuration, an uncertain outcome stops without automatic retry or rollback

Rollback requires an unchanged applied configuration and refuses to remove a model that has since become assigned, restore its allocations first before attempting rollback

## Explicit worker transition

Adding support does not replace an existing epoch assignment

To move an idle worker to one already declared model, prepare a single-model map with the same reviewed arguments and explicitly choose a new worker ID

```bash
gdc host models plan HOST --node-id OLD_WORKER_ID --models one-model.json \
  --replace-id NEW_WORKER_ID --output transition.json
gdc host models apply HOST --plan transition.json
```

This retires the old broker record and registers its replacement on the same ML endpoint with concurrency one, so the old epoch assignment is not inherited

There is a local ML service interruption while the replacement loads, transition one Host at a time and verify serving and subsequent PoC before declaring success

The guard requires idle inference, no locks or preserved obligations, and fresh empty escrow/session snapshots from every running DevShard version, public statistics are accepted only for their reported protocol identity and other versions are queried directly

These observations are not an atomic network-wide escrow lock, coordinate concurrent traffic and escrow creation with the operator

When the operator explicitly retires old model capacity, `plan --replace-id NEW_WORKER_ID --retire-preserved` can release a preserved local worker only if every preserved model has an explicit on-chain PoC target share of zero. This interrupts that old model's reserved serving capacity for the current episode. Preview and apply independently require an idle backend, an inference window without confirmation PoC, no inference locks, and fresh empty escrow/session snapshots for every runtime. Nonzero or unknown shares are refused. The option does not settle escrows, modify chain snapshots, or delete model data

A cached DAPI `VALIDATING` status may be accepted only for the single local ML backend when its independent PoC endpoint reports exactly idle with no configuration or work statistics, the chain is in inference with no confirmation PoC, and at least 30 blocks remain before the next PoC. Both preview and apply repeat these checks. Remote ML layouts and generating or unknown states do not use this fallback; locks, preserved obligations and escrow checks still apply

The command preserves the mounted config inode, other workers, keys, chain data and model cache, backups and partial-attempt receipts are retained

A partial failure stops without automatic retry, inspect the receipt and live state before recovery, a reverse transition requires its own reviewed plan rather than blind rollback

If removal was a confirmed no-op and the original worker identity and disk bytes still match the plan, `apply --plan transition.json --retry-unchanged` permits one linked retry without deleting the first receipt, all other uncertain outcomes remain blocked
