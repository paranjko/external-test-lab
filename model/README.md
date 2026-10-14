# Model profiles

Pinned model contracts shared by the deployment runbook live here, at the
repository root. Keep this directory alongside `net-deployment-runbook/`
when copying or packaging the tools.

Select a profile by its lock basename, for example:

```sh
net-deployment-runbook/gdc.sh --model qwen2.5-7b-instruct prefetch-ml HOST
```

Moving a lock does not change its contents or qualify its model for a network.
Qualification-only profiles still require explicit qualification and network
registration; selecting a profile does not submit governance proposals.
