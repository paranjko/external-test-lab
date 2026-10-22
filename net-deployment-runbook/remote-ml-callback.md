# Remote ML callbacks

`gdc host setup PARENT add mlnode WORKER` must establish two routes:

- PARENT to WORKER for model and PoC requests.
- WORKER to PARENT for generated PoC batches and validation results.

The local Docker name `http://api:9100` is not a usable callback address for a
worker on another machine. GDC resolves the parent's SSH HostName from the
worker, configures DAPI with that IPv4 address, and publishes port 9100 behind
the managed firewall. Only the original JOIN peer and explicit additional
worker IPv4 /32 addresses are allowed; ports 9000 and 9200 stay private.

The callback setup supports flat and legacy parent Compose layouts, preserves
the existing Compose file list and credentials, and recreates only `api` when
its callback setting or listener binding differs. It does not restart Core,
TMKMS, monitoring, or the worker. Existing callback peers remain allowed when
another worker is added. Removing a worker does not automatically revoke its
entry in `/etc/gonka/ml-callback-peers`; review that allowlist when retiring a
Host. It is reloaded by the managed firewall after reboot or host preparation.

After setup, GDC checks the read-only `/versions` endpoint from inside the ML
container. Failure prevents reporting successful attachment. A NAT, routing,
or source-address mismatch must be resolved explicitly; the operator must not
open the callback listener to all sources. Worker images need curl, already
used by the managed ML runtime's health and model checks.

Validator GPU lending preserves the donor's configured model and complete
argument list, including explicit KV-cache budgets. It adds a distinct remote
endpoint without replacing the parent's existing models. Worker IDs are opaque;
legacy short labels are not evidence of a model mismatch. The donor's local
configuration must contain exactly one model. A retained controlled-stop
receipt allows lending only the ML runtime while Core and TMKMS remain stopped;
it does not require restarting the donor validator first.

## Repair an existing attachment

Use the corrected checkout. For a retained validator lending record, repeating
the same `gdc host setup PARENT add mlnode WORKER` repairs the callback before
reporting that the worker is already attached. To repair only the callback,
without starting the worker's backend again:

```sh
bash net-deployment-runbook/scripts/ensure-ml-callback.sh PARENT WORKER WORKER_IPV4_OR_DNS
```

This may briefly interrupt DAPI requests while the API container is recreated.
The previous environment is retained in a private `.ml-callback-backup.*`
directory under the parent deployment; an apply failure attempts to restore
it and recreate API with the old setting. Firewall peer additions remain
restricted and persistent. A failed worker readback leaves the new callback
configuration in place for inspection and returns a failure, not READY.

Check the next completed PoC for included worker output and validation votes.
HTTP reachability is not PoC acceptance or validator membership. Model-group
eligibility, confirmed weight, and governance parameters are separate gates.
