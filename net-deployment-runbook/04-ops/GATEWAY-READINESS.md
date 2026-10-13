# Independent gateway B readiness

GDC reconciles the private B admission service without changing native
completion/status/metrics routes, faucet or the chain release profile

The service binds B's private gateway target and model to the official
DevShard v5.0.2 archive URL and SHA-256, checked against current governance
and generation/runtime state on each request

Use an inventory with exactly one B entry in GDC_GATEWAY_SETTINGS_TARGETS,
the existing private B gateway.env and its devnet_ client keys

```sh
GDC_RUN_ID=readiness-review ./gdc.sh ops gateway-readiness preview
```

Inspect the retained preview, target and hashes, obtain exact live confirmation,
then reuse its run ID with GDC_GATEWAY_READINESS_APPROVED_PREVIEW_SHA256

```sh
GDC_RUN_ID=readiness-review ./gdc.sh ops gateway-readiness apply
```

Preview stages source in a private run-specific directory, but does not change
the managed service, credentials or live routing

Apply refuses a stale preimage, foreign listener or symlink target, retains
private preimages, reconciles the systemd service and verifies authenticated
B identity readback, unchanged reapply does not restart the service

GDC_GATEWAY_B_READINESS_PORT defaults to18086, ports used by faucet,
shared observer, native gateway and B route proxy are refused

The participant edge renders the matching private upstream only for B's
configured Host, other edges use a closed sink

Deploy the changed participant edge through its existing GDC preview/apply
workflow with its separate confirmed delta, expose only authenticated
GET /gateway-b/v1/admission-status to the trusted public edge and loopback

Native admin credentials remain private, wrong client keys get401,
untrusted sources and methods get403, zero/stale/paused/mismatched states
are unavailable rather than READY

Run make test-gateway-readiness and make test-gateway-readiness-lifecycle
from the runbook, then the required full product and publication gates
