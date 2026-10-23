# Frozen v6 admission binding

This path renders and installs the admission contract independently of the
legacy operator profile. It does not fund escrows, enable rotation, change
models, restart services or update Bifrost providers. Installation alone does
not restore inference.

## Prepare the binding

From the runbook directory, create a private JSON binding with exactly these
fields: `upstream`, `observer`, `chain_api`, `chain_rpc`, `approved_versions`
and integer `port`. Select URLs from the actual deployment, not from an old
profile. HTTPS is required except for loopback HTTP; credentials must not
appear in URLs.

- `upstream` is the selected v6 completion service base, with no `/v1` suffix.
  It must not loop through admission or Bifrost back to itself.
- `observer` is the authenticated sanitized observer status URL, not the
  native gateway admin endpoint.
- `chain_api` is the REST base before `/productscience/inference/inference/`.
- `chain_rpc` is the RPC base before `/status`.
- `approved_versions` is the complete approved-version registry URL on the
  intended chain; do not substitute parameters from another network.
- `port` is the selected private admission listener port.

The renderer obtains the v6 ZIP identity from the repository's frozen artifact
definition. It does not discover or approve a newer binary.

Store only the observer bearer token in a mode-0600 regular file. It must be
different from the native admin key. The observer retains the native admin
key and uses `GDC_GATEWAY_ADMIN_STATE_URL` to query the selected v6 gateway's
`/v1/admin/devshards`. Admission receives only the observer token.

```sh
python3 scripts/render-v6-admission.py \
  --binding /private/v6-binding.json \
  --observer-token-file /private/observer-token \
  --output /private/v6-admission.env
```

The output must not already exist. It is created with mode0600; the terminal
summary contains its checksum, not its contents. Do not print or commit the
generated environment or credentials.

## Existing-edge installation and coordinated activation

Before installation, retain private preimages and modes of the admission code,
environment, observer configuration and affected provider configuration. Record
the existing Compose checksum, project identity, image identities and protected
gateway/Caddy configuration. Verify the listener belongs to this deployment.

Use the checksum reviewed before deployment; do not silently recalculate it
after a mismatch. Invoke the installer from the tested source checkout:

```sh
sudo 04-ops/edge-node/install-gateway-admission.sh \
  /private/v6-admission.env --preserve-compose REVIEWED_COMPOSE_SHA256
```

Replace the final argument with the reviewed 64-character checksum. This mode
refuses changed Compose content and invalid managed targets, preserves the
existing Compose file and installs only admission code/environment and its
status directory. It is not a transactional deployment controller: a failed
installation requires inspection and restoration from the private preimages.
Do not use the one-argument fresh-install mode on a customized existing edge.

Activation is a separately coordinated operation. Align the observer with the
same native v6 gateway, recreate only the admission service in the existing
Compose project, then route the selected Bifrost provider through admission.
Verify the provider has `max_retries` equal to integer0 before changing its
binding. Preserve client keys and unrelated providers. Do not restart the
whole stack or replace Caddy configuration to perform this cutover.

Keep the old provider binding available for rollback. If verification fails,
restore affected configuration and service state; do not replay failed
inferences, reset funding ledgers or bypass approval/capacity/PoC gates.

## Verification

Run `make test-v6-admission-deployment` and the required full
source/publication checks. The deployment fixture runs the actual
installer and installed process in isolation, with synthetic chain/runtime
responses; it is not live DevNet acceptance.

After authorized activation and funding readiness, use the existing smoke
client with its private stable key for JSON and SSE completions. Match each
response's admission receipt and native identity to exactly one final audit
record, including concurrent requests. Verify early SSE content, complete
stream termination and honest failed/disconnected-stream records. Confirm the
public health receipt describes the same serving path, not aggregate traffic
on a bypass route. Preserve rejection versus dispatched-failure distinctions.

Record an entire epoch, including the send window and PoC fence. A successful
render, process start, metrics scrape or health HTTP200 is not proof that a
completion succeeded. Existing-wrapping and v6-wrapping qualification remain
separate acceptance stages.
