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

The upstream testenv documentation identifies the Docker services and the
v5 gate. The preserved run log at the selected checkout reported routed v5
health while chat admission remained `catalog_pending`.

The current IMP-010 source trace found `/devshard/v2/healthz` consistently in
the pinned source and the effective route. It also found the seed loop is
started, so a missing seed-loop start is ruled out. The root cause remains
**INCONCLUSIVE** because the receipt does not yet bind a same-instance status
and response body to the executable and container identity that served it.
Resume IMP-010 by capturing those four facts from one owned request and one
running instance: request target, status and body, executable identity, and
container identity.

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

These receipts do not qualify M0-A09 or M0-A08, do not close IMP-002 or
IMP-004, and do not establish M0 completion.
