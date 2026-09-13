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

## Proposed compatible baseline composition – unqualified

`proposed-compatible-devshard-baseline-v1` is one proposed, owned Compose
composition for the next changed-input qualification. It is deliberately a
new declared revision, not a rename of `lab-mock-devshard-testenv-v5` or any
historical candidate receipt. Its required topology is a real DevShard gateway
with its versiond and versiond-router dependencies, plus explicitly declared
mock-chain, mock-DAPI and mock-OpenAI dependencies. The proposal must pin the
Compose bytes, every image or executable identity, the chain/fixture seed and
the gateway's effective catalog route before it may create resources.

The historical D12 candidate receipt identifies `/usr/local/bin/devshardctl` in service
`devshardctl`, container
`d0d9ff981691067727af6f9c42478973322dafa96c006dad6cb1e65caeeec092`, SHA-256
`d6004a1c50cb09980790b0c127fa2b63339966f1732cacac66e195616e678d6f`, from
image ID `sha256:a5522c603d59190aa6c88862fa0f488010da156586998153d6555256cd58306f`.
That historical field was captured from `/proc/1/exe`: it distinguishes the
gateway container from the versiond PID 1 `/sbin/tini` wrapper and router
HAProxy, but does not prove the `devshardd` child beneath versiond. Candidate
attempt 9 did populate the separate child observation: versiond-0 PID 64 and
versiond-1 PID 67 executed `/opt/versiond/bin/v5/devshardd`, both with
SHA-256 `3c1b8ddef0d3b8f17a37b4a9eaf2e1862c7a7b8407cb5e8920e5d606488a3f76`.
This is real candidate runtime evidence, not PID 1, a mounted path or a
baseline identity. Its restored-instance assertion still used the obsolete
absolute selector; Gonka `ea44ab00ac777a98c705e033819b50ac690a82b2` corrects
only that lookup to a basename capture. Candidate attempt 10 used that changed
input and fresh digest. Its authoritative terminal records report `PASS`,
`launch_completed`, a released lease, completed terminal cleanup and restored
runtime-child identity. The earlier incomplete observation and a separate
operator cleanup receipt are retained as history; the operator receipt proves
both exact owned Compose generations had zero matching containers, volumes and
networks after cleanup. The completed receipt is candidate-slice evidence only:
it neither changes the historical original pin nor qualifies this proposed
baseline.

The unavailable input is a materialized, known-good compatible revision of
that proposal with immutable rendered inputs and a declaration that it is a
baseline. Its owner is the IMP-002/M0-A09 qualification owner in this owned
worktree; no external owner or external-environment dependency has been
established. The absence of this input keeps M0-A09 and M0 open, but is not
`environment_unavailable` and does not authorize an unchanged-selector retry.

FR-005 qualification of this proposal requires independent retained evidence
for all of the following before it can become a baseline:

1. exact rendered Compose and configuration bytes, their declared and computed
   digest, source revision, image IDs and actual running child executable
   paths, SHA-256 values and argv or process relationship;
2. declared and effective catalog route construction, with bounded status,
   cloned headers and body for each actual probe URL;
3. fixture chain ID, genesis or seed identity, fresh capacity/process/port and
   lease preflight, and a decision receipt before resource creation;
4. SG01–SG05, v5 non-stream, SSE `[DONE]` and malformed-request observations,
   plus invalid-digest rejection before creation, missing-route and
   broken-mock non-success controls;
5. reset, recreated fresh-instance and terminal owner-labelled resource
   inventory showing cleanup; and
6. an explicit supported adapter receipt for each v3/v4 claim, or an
   evidence-backed `unqualified` gap without inferring compatibility.

The next fixture, if needed, therefore changes its input to this materialized
baseline revision and records the listed discriminating evidence. It must not
repeat the D12 candidate selector unchanged.

## Independent qualification attestation boundary

`m0stand --qualification-verify-only` verifies, but never creates, a separate
qualification decision over a frozen eligibility receipt. The decision binds
its own ID, issuer and review reference, the initially-unqualified profile
hash/environment, the eligibility receipt hash, the three retained evidence
hashes, `qualified` baseline acceptance, supported `v5`, and explicit
unqualified `v3`/`v4` scope. The derived binding receipt is no-launch: it does
not acquire a lease, create a resource, alter the profile, or replace the
historical candidate/eligibility receipts.

An issuer name is provenance, not proof of independence. M0-A09 remains open
until an independent authority supplies and accepts a decision over the frozen
evidence; the binding verifier rejects a missing/rejected decision, tampered
evidence, mismatched profile/eligibility, scope expansion, and output aliases
that could overwrite an input. The binding receipt alone is not M0-A10
acceptance.

## Proposed baseline v1 materialization

`environments/proposed-compatible-devshard-baseline-v1.json` is the initially
unqualified declaration for Gonka `ea44ab00ac777a98c705e033819b50ac690a82b2`.
The existing testenv prepare path rendered its frozen inputs with digest
`9ec5138fb932176cb006a1d327ddc1d4fe32195461959d71dfaa1895e803244b`; the
independent `m0stand --preflight-only` decision binds that digest to the profile
SHA-256 `9e54bbc146a38845d2d780e48c9ec2ba7d6c9c4ecb133322dbe685901d8d1250`
without a lease, launch attempt or created resource. The focused adapter test
also proves this no-launch boundary.

This is an admission check, not compatibility qualification. The next
changed-input fixture must use this profile and these exact prepared inputs to
record configured and effective catalog routes, image and child identities,
all FR-005 controls, fresh-instance recovery and cleanup before this profile
can be promoted from `unqualified`.

`m0stand` now requires `--profile` and validates it before composition
preflight, lease acquisition or fixture launch. Its decision receipt persists
the profile path, content SHA-256, environment ID and baseline status; the
lease `--environment-id` must match the validated profile. A focused wrapper
test proves that a profile-bound digest mismatch writes those fields while
leaving the lease root absent, and that an environment mismatch stops before
preflight. Thus a future materialized baseline revision must be supplied both
as the profile and as the exact rendered inputs consumed by the launch path.

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
