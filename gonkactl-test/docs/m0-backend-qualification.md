# M0 Backend and Transport Qualification

## Decision status

`lab-mock-devshard-testenv-v5` is the selected M0 adapter candidate. It is
not a qualified baseline and does not establish any Community DevNet result.

The selected upstream checkout is Gonka commit
`1eaa0413f58899f48f8ba19d16f9653b16dc4987`. Its `devshard/testenv` supplies
an owned Docker topology with mock-chain, mock-DAPI, mock OpenAI, versiond,
versiond-router and devshardctl. It runs the production devshardd binary
against those mocked external dependencies; it does not reimplement the
production binaries.

## Transport and ownership

The adapter uses owned Docker Compose resources and loopback HTTP. A runner
must receive an instance lease before rendering a Compose project, allocating
ports or creating volumes. Its data, temp files and tool caches belong under
the configured persistent data root. A shared Community DevNet is attachment
only and is outside this adapter's ownership.

## Per-major contract matrix

| Protocol | M0 state | Health route | Chat contract | Meaning |
|---|---|---|---|---|
| v3 | unqualified | none asserted | none asserted | The v5 source inspection supplies no v3 contract. |
| v4 | unqualified | none asserted | none asserted | The v5 source inspection supplies no v4 contract. |
| v5 | candidate | `/v5/healthz` → 200 | `/v1/chat/completions` – probe required | Route health is not chat admission or inference evidence. |

The machine-readable version of this decision is
`environments/lab-mock-devshard-testenv-v5.json`.

## Evidence and remaining spike

The historical original-pin run remains a failed diagnostic, not a proven
Gonka failure. Its `/devshard/v2/healthz` observation cannot be reconciled
from source alone because its running binary and effective configuration were
not retained. The seed loop was already started, so a missing-start diagnosis
is ruled out.

D11 added bounded `GetHTTPObservation`, explicit admin JSON encoding failure
handling, runtime catalog URL diagnostics, same-instance identity capture and
the compose-build propagation fix. The final D11 capture rebuilt and identified
the running patched gateway, then recorded HTTP 200 observations for both the
runtime catalog URL and harness URL at `/v5/healthz`, with explicit cleanup.
This establishes route consistency for the patched candidate only. It does not
identify the historical binary/configuration, therefore IMP-010 is
**INCONCLUSIVE** for the original pin.

The first frozen patched-candidate M0-A09 control slice used source
`ae69d845ef54259736b55b19aeeee625474c8cfb`. It observed router catalog
admission after expected initial 503s, gateway health, non-stream HTTP 200,
SSE `[DONE]`, malformed HTTP 400, recovery HTTP 200 and a missing-route HTTP
404. Its mock-openai HTTP 503 control ended in the gateway client's three-minute
transport timeout. The existing upstream `TestA2_MLUpstream5xx` explicitly
accepts either HTTP >=400 or this transport timeout for that control, so this
is an accepted non-success observation rather than a new Gonka failure.
The fixture itself failed because the first receipt helper asserted before
persisting that transport error; its partial observations, runtime image
identities and zero-container cleanup are retained.

Candidate `2a6e59af16eb229792d726b004e62930b89c8eeb` retains
`ObserveGatewayChatHTTP`, allowing a future changed-input fixture to persist
the transport error before asserting it and adds the two-phase prepared
composition path. The earlier changed-input fixture passed: it records a
non-empty `broken_mock.transport_error`, successful recovery, runtime image
identities and zero-container cleanup. The candidate now also tears down that
instance, records an empty owned inventory, recreates the same preflighted
composition, requires distinct gateway/router container IDs and records new
health, canary and SSE observations. This next changed-input run has not been
authorized or executed. It remains only a bounded v5 slice, not M0-A09
closure.

## D12 fixture authority and active resume condition

The preceding no-authorization sentence is historical evidence of the earlier
D11 boundary. D12 now authorizes the test executor to recreate this owned M0
stand as needed without another project-permission request. Each attempt still
requires its own frozen input, fresh lease/capacity/process/port preflight,
bounded budget, evidence and verified task-owned cleanup. The next run is the
changed-source restored-instance selector at
`2a6e59af16eb229792d726b004e62930b89c8eeb`: it must retain the broken-mock
non-success, empty between-instance inventory, distinct gateway/router IDs,
restored health/canary/SSE and terminal cleanup. It remains unexecuted and
does not alter the original-pin IMP-010 `INCONCLUSIVE` classification.

### D12 actual attempts

The preceding “next run” language is historical. Attempt 4 preserved the
matching-digest, lease-acquired failure caused by root-owned `aggregate-spool`
data below the Gonka Docker build context; its lease was released and its
temporary data was removed. Attempt 5 changed the prepared workdir to this
owned ETL worktree, outside that build context. It passed in 383.849 seconds
with Gonka `7c827b2bba99ffcfb6faf542f71eaef6d3ac0f2c`, ETL
`fdd28c84bcbffb9db132ccb9fb4952d2acdf21d3`, and digest
`595b41429af42cbb3f85c7334be863e74dfa6c6cad63116e065568c3f6f98edd`.
Its receipt records a released exclusive lease, SG01–SG05, runtime identities,
positive and negative route observations, restored fresh-instance behavior and
zero terminal owned resources. The rendered inputs, logs and receipts remain;
root-owned transient data was removed. This is a v5 candidate slice only:
baseline is unqualified, invalid digest is `not_run` in the matching launch,
v3/v4 remain explicit gaps, and IMP-010 remains inconclusive.

The M0 executable spike must still create an owned fresh fixture and record:

1. SG01–SG05 observations and actual child identity;
2. one known-good compatible baseline, an invalid-digest control, a missing
   route control and a broken-mock control;
3. exact v5 non-stream, SSE termination and malformed-request contracts; and
4. explicit v3/v4 adapters or `unqualified` gaps – never inferred support.

Until that receipt exists, candidate/testenv outcomes remain fixture or
adapter evidence, not a product or release conclusion.

## Invalid-digest preflight control

`stand.PreflightComposition` now hashes the exact prepared `config.yaml` and
`docker-compose.yml` bytes using named length-delimited SHA-256 records.
`m0stand` writes that decision before invoking the real fixture command.
The matching/mismatch focused test passes. A real wrapped mismatch invocation
recorded `rejected_digest_mismatch`, `launch_attempted:false` and
`resources_created:false`; the Docker inventory was empty. The matching
changed-input launch used digest
`8a168364d6dc30a91abee43c3d71306930cd0e1c39d1d2a2f80102ff6172c092` and
completed the real focused fixture. This proves the bounded pre-launch
rejection boundary, not full lease, fresh-instance, SG01–SG05 or M0-A09
acceptance.

## Storage transport qualification

Storage 1.0.1 isolated API and prefix-route requests passed through both HTTP
and HTTPS. The owned containers were then cleaned up successfully. These are
**PASS** receipts for API transport, prefix routing, and container cleanup.
They are not browser evidence.

The earlier `SIGTRAP` and hanging `--dump-dom` receipts are retained, but do
not describe Chrome globally. A fresh isolated persistent-profile CDP probe
passed. The shared CDP check now proves a real generated case, BDD steps,
attachment content, two rendered History items, direct hash navigation and a
real browser reload over local HTTP and Storage HTTP/fixture-HTTPS. Each run
records its owned Chrome-child cleanup; fixture HTTPS records its certificate
exception explicitly.

## Receipt boundary

| Receipt | Status | Boundary and resume action |
|---|---|---|
| Storage API over HTTP and HTTPS, including prefix routes | **PASS** | Isolated request evidence only; retain it as transport evidence. |
| Owned Storage containers after the isolated run | **PASS** | Cleanup completed; provision a new owned fixture for any resumed browser run. |
| Browser execution | **PASS** | Isolated-profile CDP probe reaches `about:blank` and terminates its owned Chrome child. Earlier failures remain historical receipts. |
| Browser assertions and browser-generated Allure result | **PASS** | Current generated bundle assertions cover steps, attachment content, History, direct navigation and reload through local HTTP and Storage HTTP/fixture-HTTPS. |
| Existing non-browser runtime receipts | **PASS** | They support only their recorded API, routing, and cleanup observations. |

These receipts do not qualify M0-A09, do not close IMP-002, and do not
establish M0 completion. The independently accepted browser receipts satisfy
M0-A08 only; they do not substitute for the required runtime baseline evidence.
