# DevShard v6 stand preparation

Prepare Community DevNet on Gonka protocol **0.2.16** for the upstream
[manual feature](https://github.com/gonka-ai/gonka/blob/e9d56e2a4e810788ec4be39725026cd892cf1080/devshard/docs/release-0.2.16-v6-manual.feature).
The completion boundary here is a usable test stand. Passing the complete
feature, long workload campaigns, Telegram/faucet acceptance and dashboard
improvements remain separately reported work.

The running Cosmovisor child identifies the protocol. An old container tag or
the base image's `inferenced version` does not identify the active upgrade.
Record chain, child, gateway and wrapping identities separately.

## First stage

Use the published [lab artifacts](https://github.com/paranjko/external-test-lab/releases/tag/lab-devshard-v6-artifacts-e9d56e2a4e81-manual-matrix-dapi-edge).
Gateway and approved v6 child share source `e9d56e2a4e810788ec4be39725026cd892cf1080`.
Keep existing host wrapping unchanged for section 1. Explicitly disable
`DEVSHARD_RPC_H2_UPGRADE` on the gateway; the upstream Compose default enables
it even when an env file says otherwise. HTTP/2 on port 9443 belongs to the
later wrapping-switch stage. The public completion API stays on HTTPS 443.

Start A on node4 and B on node0 with different existing A/B credentials and
separate fresh v6 volumes. The two hosts supply different source addresses.
Retain old gateway volumes and operator-managed v4.1 services. Never open a
v5 database with v6 or replace an operator's separate gateway.

[`v6-gateway.compose.yaml`](v6-gateway.compose.yaml) starts one instance.
Set these variables in a private operator env file on each host:

| Variable | A | B |
| --- | --- | --- |
| `V6_GATEWAY_PROJECT` | `gdc-v6-a` | `gdc-v6-b` |
| `V6_GATEWAY_API_PORT` | `18187` | `18188` |
| `V6_GATEWAY_STATS_PORT` | `19191` | `19192` |
| `V6_GATEWAY_VOLUME` | `gdc-v6-a-data` | `gdc-v6-b-data` |
| `V6_GATEWAY_NETWORK` | `gdc-node4_default` | `gdc-node0_default` |
| `V6_GATEWAY_SECRET_FILE` | existing private A env file | existing private B env file |

Verify the ports are unused and the new volumes do not exist before the first
start. Render with `docker compose --env-file OPERATOR_ENV -f
v6-gateway.compose.yaml config --quiet`, then use the same arguments with
`pull` and `up -d`. Raw `config` output expands credentials and stays private.
Subsequent restarts retain each instance's own volume.

Through the authenticated loopback admin API, preserve the complete settings
object, select the test model and set its access mode to `api_key`. Keep
automatic rotation and settlement disabled while establishing the baseline.
Set `max_concurrent_requests_per_10000_weight` to 25 through that API as well
as the Compose bootstrap environment. With the observed 1,600–1,900 weight,
the upstream default of 5 rounds ordinary concurrency down to zero; 25 allows
about four requests. Preserve the PoC coefficient and phase gates. Read back
positive current weight and effective concurrency before sending a probe;
an open phase alone is insufficient. Reassess this coefficient if fleet
weights change substantially.
Create one bounded funded v6 escrow per instance, record the result before
any retry, and verify model, session version and participating hosts. An
uncertain transaction requires reconciliation, never another blind creation.

The v6 runtime retention window is three epochs, including the current one.
On this short-epoch DevNet, a successful one-off escrow is not a lasting
readiness guarantee. Continued testing needs explicitly authorized rotation
and settlement with a bounded amount and operating window. Verify the chain's
escrow amount limits first: the observed minimum is **1 GNK** (1,000,000,000
ngonka); 0.001 GNK is rejected. Bound gross new funding, not just net spend
after refunds. Count uncertain creation attempts against that budget and
reconcile them before any retry. A timer alone does not enforce a funding cap.
Do not infer funding authority from permission to edit gateway configuration,
and do not disable host retention to keep an expired test escrow alive.

Before changing A/B public routing, obtain a real authenticated completion
from each candidate in the send window. Preserve route preimages and change
only the gateway upstream. Check public JSON on A and SSE on B, unauthorized
request rejection, and independent storage/credentials. Restore the recorded
upstream for rollback; retain both generations and their evidence.
The public API origins are `https://api.gonka-dev.net/a` and
`https://api.gonka-dev.net/b`; `gonka-dev.net` is the status-site hostname.

Keep public observations aligned with the switched routes. The independent
A/B readiness services must select approved `v6`, its exact registry checksum
and their corresponding authenticated native admin-state endpoint. Point each
service's `GDC_GATEWAY_ADMISSION_APPROVED_VERSIONS_URL` at
`http://127.0.0.1:1317/productscience/inference/inference/devshard_approved_versions`.
On 0.2.16 the legacy approved-version field in `/params` is empty; the explicit
registry must be queried, validated and matched without falling back to stale
legacy values when it is unavailable. Point each
edge's native metrics upstream at the new gateway too. Preserve private env
preimages and restart only the affected readiness/proxy services; changing a
file does not update an already-running container's environment. Do not
rebind the separate stable S admission service as a shortcut.

Verify the site's public readiness projection and fresh native counters after
cutover. `UNAVAILABLE` remains correct during a PoC fence or when no usable
funded runtime exists; never force a green display. A bounded operator-funded
test window is not evidence of unattended native-rotation qualification or
permanent availability after that window expires.

## Readiness and remaining scenarios

### Budget-bounded operator rotation

`v6-budget-rotation.py` is an explicitly authorized operator workaround, not
qualification of the native rotator. Its fixed campaign binds A to node4 and
B to node0, reserves 1 GNK before every create request, and caps each instance
at 5,000 GNK gross funding. Refunds never replenish this allowance. Transaction
fees are additional. There is no calendar deadline for this campaign.

Keep native rotation disabled. Copy the script to each existing
`/srv/dai/broker-tests/v6-INSTANCE/rotation-10000gnk.py`. Initialize exactly once
with `python3 SCRIPT INSTANCE --initialize`, then run `python3 SCRIPT INSTANCE`
from a single systemd oneshot timer every 30 seconds. A durable SQLite ledger
under `rotation-10000gnk-20261013` holds reservations and responses. Never remove,
replace or reinitialize it to recover from failure. Missing state fails closed;
ambiguous transactions reserve budget and halt creation pending reconciliation.

The operator timer is named `gdc-v6-budget-INSTANCE.timer`. Stop it with
`systemctl disable --now gdc-v6-budget-INSTANCE.timer`, then wait for its active
oneshot service to finish; stopping the timer cannot undo an in-flight request.
The earlier bounded timers must remain disabled. A halted transaction stops
the new timer; reconcile its receipt before an explicitly reviewed restart.
Re-enabling a timer never resets its ledger or restores its spending allowance.

Creation occurs at most once per epoch, only in the normal funding phase with
at least 15 blocks before the switch. Settlement starts two epochs later,
never forces busy requests, and permits at most three known-busy retries.
The cap blocks all further creation; bounded settlement of existing records
may continue. No readiness or PoC gate is bypassed. Do not promise continuous
inference during protocol fences or claim a load result from this mechanism.

Run `make -C broker-ops test-v6-budget-rotation` before installing a change.

- Two independent usable gateways are the first test gate. A health response
  or a configured image alone does not establish inference readiness.
- H/HR scenarios additionally require two `versiond` replicas sharing Postgres
  behind the existing router on a host assigned escrow slots. Record explicitly
  if that cell is unavailable; do not claim full matrix readiness.
- Leave v6 wrapping, rate-limit stress, catch-up and old-version compatibility
  for their ordered scenario runs. Failures become test findings with retained
  evidence; they do not require polishing unrelated capabilities first.
- Stable public admission recovery remains tracked by issue #211. Preparation
  of A/B does not close that issue or turn historical failed runs into passes.
