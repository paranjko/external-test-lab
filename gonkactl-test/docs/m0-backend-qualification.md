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
health while chat admission remained `catalog_pending`. Source inspection
shows why this is not yet a compatible baseline: the selected height-sync
tests call `WaitGatewayChatReady` before their first named chat, but that
waiter requires `height_seed=ok`; the pinned session starts the seed only on
the first outbound inference, heartbeat or catch-up. A route-health success
therefore cannot break the cycle. The M0 executable spike must create an
owned fresh fixture and record:

1. SG01–SG05 observations and actual child identity;
2. one known-good compatible baseline, an invalid-digest control, a missing
   route control and a broken-mock control;
3. exact v5 non-stream, SSE termination and malformed-request contracts; and
4. explicit v3/v4 adapters or `unqualified` gaps – never inferred support.

Until that receipt exists, candidate/testenv outcomes remain fixture or
adapter evidence, not a product or release conclusion.

## Pinned fixture correction required

The correction belongs to the pinned Gonka testenv source, not this External
Test Lab adapter. Split runtime/catalog readiness from seed readiness. The
height-sync case must execute an explicitly named first-request canary after
catalog/runtime admission, tolerate only the documented bounded seed 503s,
then require `height_seed=ok` before assertions that need a seeded floor.
`env check` must remain request-free by default. This implements the
FR-004 boundary instead of silently disabling `DEVSHARD_REQUIRE_HEIGHT_SEED`
or treating `/v5/healthz` as chat proof.
