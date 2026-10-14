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
escrow amount limits first: the model-rollout parameter change raised the
minimum to **5 GNK** (5,000,000,000 ngonka), with a 10 GNK maximum. Query current
chain parameters instead of relying on this dated observation. Bound gross new funding, not just net spend
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

For bot-issued stable keys, inspect the running Bifrost provider through its
management API and trace that provider's upstream to the native gateway before
selecting canonical readiness. Stored env alone is not proof of Bifrost's
database configuration. If stable traffic uses an independent gateway, set
`GDC_STABLE_READINESS_PORT` in the edge inventory to that gateway's existing
read-only readiness listener on the public-edge host. Rendering produces
`GDC_STABLE_READINESS_UPSTREAM=127.0.0.1:PORT`. Its default remains18083 for
legacy installations. This changes only the canonical API/site/preview
admission-status endpoints, not inference, A/B admission or the legacy service.
Recheck the provider binding whenever it changes; do not select an observer
merely because another gateway is healthy. A remote gateway needs a separately
verified local read-only handoff, not an arbitrary external URL in this setting.

Validate and reload the exact candidate Caddy configuration with retained
preimages; an already-running container does not inherit an edited env file.
Compare canonical readiness with the selected listener and check that stable,
legacy and A/B inference routing is unchanged. Observer failure must remain an
HTTP error, never fall back to an unrelated healthy observer. This readiness
selection alone is not an authenticated inference success or a replacement
for the site's separate route-bound health/probe evidence.

Verify the site's public readiness projection and fresh native counters after
cutover. `UNAVAILABLE` remains correct during a PoC fence or when no usable
funded runtime exists; never force a green display. A bounded operator-funded
test window is not evidence of unattended native-rotation qualification or
permanent availability after that window expires.

## Readiness and remaining scenarios

### Preserve monitoring independently of validator and gateway lifecycles

Managed JOIN uses its retained `GDC_JOIN_MONITORING_REGISTRY_HOST` SSH alias
to select the metrics firewall source, independently of the consensus seed.
For an independent operator without the lab registry, set `GDC_MONITORING_HOST`
to the collector's public hostname or IPv4 address before JOIN. That explicit
value takes precedence. Legacy input without either value retains the gateway
or seed fallback; it does not discover an unrelated collector automatically.
The selected source must resolve to exactly one IPv4 address.

`ops monitoring` refreshes public Grafana with `install-edge.sh
--monitoring-only`. An existing edge deployment is required. This mode keeps
Caddy, Compose, `.env`, gateway route/admission credentials and ownership
unchanged; only public Grafana provisioning is refreshed. Explicit `ops edge`
still owns a full route deployment. Do not deploy an older monitoring launcher
that unconditionally reinstalls the public edge.

On an existing OPS installation, monitoring refresh also preserves OPS Compose,
`.env`, Caddyfile, gateway credentials and non-monitoring systemd services. It
updates Grafana provisioning and Prometheus configuration/targets only, retaining
JOIN-owned targets. Existing image selections and Grafana credentials therefore
remain in effect; changing those shared settings is a separate deployment.
An incomplete existing OPS configuration refuses refresh. Fresh installation
still provisions the initial OPS stack. The launcher recreates only monitoring
containers and starts an absent Caddy without recreating an existing listener.

Host `node-exporter` and `cAdvisor` remain active when a validator is stopped
or lends its GPU. An intentionally stopped chain may have a down chain-metrics
target, but that is not permission to stop host or container monitoring.
The real Docker lending regression checks this isolation in flat and legacy
layouts. Test workloads must not reclaim the monitoring ports by stopping
these services.

### Bounded stable-route observation

`v6-stable-receipt.py` can collect one explicitly authorized inference
observation through the stable credential adapter. It is not a rotation tool
or a replacement for the legacy exact-once health receipt. First verify the
running Bifrost provider and native route as described above. Create an
operator-owned regular JSON file with mode0600 and exactly these fields:
`completion_url`, `admission_url`, `accounting_url`, `key`, `model`, `gateway`.
The key must be a current stable `sk-gdc-` credential; do not put it in shell
arguments or public evidence. Gateway is the verified native target A or B.

Use the canonical HTTPS `/v1/chat/completions` URL for completion. Admission
must observe that same native target and model. Accounting must be its private
`/api/v1/epochs/current/participants?model=URL_ENCODED_MODEL_ID` endpoint;
never publish the accounting listener. Plain HTTP is accepted only on loopback.
Run `python3 v6-stable-receipt.py --config PRIVATE.json --execute` only after
funding/admission gates and applicable inference authority pass. Without the
explicit flag the command refuses before reading the key. It never creates,
settles or rotates an escrow, follows redirects, or retries a failed request.

The sanitized result is OBSERVED only with matching native request/escrow
identity, before/after admission, and one finished_used counter increment in
the same epoch. It deliberately retains `exclusive_attribution_proven=false`:
aggregate counters cannot prove exclusive attribution during concurrent traffic.
Do not rename this result TRAFFIC_READY, use it as settlement proof, or overwrite
the legacy gateway-health receipt with it. A failed observation exits nonzero.
Run `make -C net-deployment-runbook test-v6-stable-receipt` from the repository
root; the same target is included in the gateway CI group.

To expose this limited observation on the site, run the authorized probe with
`--health-output EDGE_DIRECTORY/status/gateway-stable-health.json`. Keep the
private config outside that public status directory. The output parent must
already exist; the probe atomically replaces a mode0644 sanitized file, including
UNAVAILABLE results. It does not install or enable a timer. Use a single writer
and retain the legacy probe's separate output unchanged.

Set `GDC_STABLE_HEALTH_MODE=native_observation` in the edge inventory only after
verifying the provider/readiness binding. The renderer and Compose pass both
this selection and the selected readiness upstream to Caddy. After an explicit
configuration deployment, canonical and preview `/status/gateway-health` read
only the edge's stable file; a missing file returns404, never legacy fallback.
The site requires fresh observations and matching current admission, and labels
success STABLE_OBSERVED, not TRAFFIC_READY. Its normal traffic acceptance gate
remains closed because aggregate accounting lacks exclusive attribution.
Set the mode back to `legacy` and apply the retained configuration for rollback;
neither selection changes inference routes or resumes rotation. A failed output
write exits nonzero and leaves the old file to expire under the freshness check.

### Budget-bounded operator rotation

`v6-budget-rotation.py` is an explicitly authorized operator workaround, not
qualification of the native rotator. Its fixed campaign binds A to node4 and
B to node0, reserves the explicit requested amount before every create request, and caps each instance
at 5,000 GNK gross funding. Refunds never replenish this allowance. Transaction
fees are additional. There is no calendar deadline for this campaign.

Keep native rotation disabled. Copy the script to each existing
`/srv/dai/broker-tests/v6-INSTANCE/rotation-10000gnk.py`. Initialize exactly once
with `python3 SCRIPT INSTANCE --initialize`, then run
`python3 SCRIPT INSTANCE --amount AMOUNT_IN_NGONKA --model ADMITTED_MODEL_ID`
from a single systemd oneshot timer every 30 seconds. A durable SQLite ledger
under `rotation-10000gnk-20261013` holds reservations and responses. Never remove,
replace or reinitialize it to recover from failure. Missing state fails closed;
ambiguous transactions reserve budget and halt creation pending reconciliation.

The legacy binding cap is denominated in GNK; historical funding amounts are
already in ngonka. The script sums every recorded amount, including settled
and uncertain reservations, against the unchanged per-instance allowance.
There is no ledger rewrite or conversion. Mixed historical 1 GNK and new 5 GNK
rows therefore consume their actual amounts. An insufficient remainder stops
creation; it never rounds down the requested amount or borrows from the other
instance. Each tick reads min/max from the local chain REST API without sending
the gateway credential there. Missing or invalid parameters fail closed.

The former command without explicit amount/model refuses to run. Update the
oneshot command only after reconciling the existing ledger and confirming model
admission. Keep timers paused during the model rollout. Installing this script
is not approval to resume funding, and a model-list entry alone is not proof
that the new model group can serve requests.

The operator timer is named `gdc-v6-budget-INSTANCE.timer`. Stop it with
`systemctl disable --now gdc-v6-budget-INSTANCE.timer`, then wait for its active
oneshot service to finish; stopping the timer cannot undo an in-flight request.
The earlier bounded timers must remain disabled. A halted transaction stops
the new timer; reconcile its receipt before an explicitly reviewed restart.
Re-enabling a timer never resets its ledger or restores its spending allowance.

For an escrow whose settlement failed locally but is now demonstrably settled,
run `python3 SCRIPT INSTANCE --reconcile-settled ESCROW_ID` while the timer is
stopped. This submits no chain or gateway transaction. It requires a currently
found, settled chain record with the ledger's ID, amount and epoch, plus an
explicitly inactive gateway record. It appends a reconciliation observation;
the original funding row, settlement failure and gross reservation remain.
Repeated successful reconciliation retains the first observation unchanged.
Missing/pruned chain records are refused: absence is not settlement proof.
Do not manufacture a settled receipt or reset the ledger to bypass this guard.

Creation occurs at most once per epoch, only in the normal funding phase with
at least 15 blocks before the switch. Settlement starts two epochs later,
never forces busy requests, and permits at most three known-busy attempts.
Escrows still busy after those attempts remain for manual reconciliation;
they do not stop funding unrelated healthy epochs. Their reserved amounts
remain charged to the gross cap. Ambiguous settlement outcomes still halt.
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

## Delivery boundary and next increment

This increment delivers the pinned A/B stand configuration, authenticated
public routing, fail-closed readiness, bounded operator funding and the
monitoring safeguards above. It does not upgrade the frozen artifact whenever
the upstream development branch moves. Record new artifact qualification as
a separate baseline and preserve the original results.

Continue the following work separately after integration:

| Follow-up | Required evidence | Tracking |
| --- | --- | --- |
| Recover unattended A/B funding after settlement failures | Reconcile the chain outcome against the durable ledger before any retry; never reset the budget or force a busy settlement; repeat JSON/SSE smoke in an eligible window | [Stand preparation](https://github.com/paranjko/external-test-lab/issues/225) |
| Stable public inference availability | Verify the bot credential path, approved tuple, positive capacity and runtime eligibility; report PoC fences truthfully | [Stable admission](https://github.com/paranjko/external-test-lab/issues/211) |
| Finish monitoring rollout | Redeploy the integrated monitoring source without changing gateway routes; verify future managed JOIN collector selection and retain host metrics on an intentionally stopped validator | [Monitoring](https://github.com/paranjko/external-test-lab/issues/222) |
| Complete the manual matrix | Prepare shared-Postgres H/HR replicas and run wrapping, catch-up, load and compatibility scenarios with separate verdicts | [Stand preparation](https://github.com/paranjko/external-test-lab/issues/225) |

Merge readiness of this source change is not a continuous-availability or
full-matrix PASS. A failed smoke remains a failed observation even if the
configuration and local regression suite are ready to integrate.
