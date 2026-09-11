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

Candidate `c4662d3b1ed99ad9bae13378f49cc48b4b317c6c` adds
`ObserveGatewayChatHTTP`, allowing a future changed-input fixture to persist
the transport error before asserting it. Focused harness and selector tests
pass. That future fixture must have fresh preflight and record a non-empty
`broken_mock.transport_error` or HTTP non-success plus cleanup. It is still
only a bounded v5 slice, not M0-A09 closure.

The M0 executable spike must still create an owned fresh fixture and record:

1. SG01–SG05 observations and actual child identity;
2. one known-good compatible baseline, an invalid-digest control, a missing
   route control and a broken-mock control;
3. exact v5 non-stream, SSE termination and malformed-request contracts; and
4. explicit v3/v4 adapters or `unqualified` gaps – never inferred support.

Until that receipt exists, candidate/testenv outcomes remain fixture or
adapter evidence, not a product or release conclusion.

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
