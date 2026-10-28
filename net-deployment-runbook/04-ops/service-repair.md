# Repair stopped serving containers

Use the GDC container controller when Core and TMKMS are already running but
installed serving containers remained stopped after a host interruption:

```sh
bash net-deployment-runbook/scripts/node-container-control.sh repair-plan SSH_ALIAS
bash net-deployment-runbook/scripts/node-container-control.sh repair SSH_ALIAS
```

Review the plan immediately before applying it. The controller re-discovers the
deployment under its lock; the plan is informational, not a frozen approval.
Only existing, exited `mlnode`, `inference`, `proxy`, `versiond-router`, `edge-api`
and `explorer` containers in the discovered validator deployment may start.
It does not create containers, pull images, change restart policies, edit
configuration, start Core/TMKMS, or operate independent projects.

Controlled-stop and ML-lending receipts prevent this repair. A stopped or missing
signer also prevents it. Use the appropriate retained recovery/lending lifecycle
instead; do not fabricate receipts. Both canonical `/srv/dai/deploy` and the
legacy `/srv/dai/deploy/SSH_ALIAS` layout are supported, with ambiguous layouts
refused.

A private `service-repair.*.json` receipt records selected container identities
and the original Core/TMKMS process identities. If an operation fails, earlier
starts may already have succeeded; inspect their state before retrying. The
controller does not stop a service automatically to hide a partial failure.
For rollback, review that exact receipt and stop only containers it selected
that this attempt actually started; never stop Core or TMKMS as part of this
repair. Preserve the receipt.

Success means containers started and the observed Core/TMKMS process identities
did not change. Separately verify model loading, DAPI registration, transport,
chain progress and the next PoC admission. It does not claim inference readiness.

Run `make test-service-repair` from the repository root for real local Docker
lifecycle coverage of both layouts, identity preservation, idempotency and
refusal cases. The test replaces SSH with a closed local adapter, inherits HOME
unchanged and never reads operator signing keys.
