# Local recovery rehearsal protocol

`gonkactl recover epoch-length-live-update` prints an offline preview. It does
not query RPC, create a workspace, start processes, or modify a network.

```sh
gonkactl recover epoch-length-live-update --json
```

The new `recover` dispatcher is separate from live `network recover` contracts.
This implementation supplies local protocol primitives and fixture tests, not
a qualified repair executable. Stage, run, verify, report and cleanup CLI
adapters are unavailable and explicitly refuse execution. The library verifier
and lifecycle journal are tested independently; their existence is not a
successful runtime rehearsal.

The input library verifies exact signed payloads with caller-injected pinned
Ed25519 trust roots, distinct roles/scopes, time bounds and a current local
revocation snapshot. The CLI contains no production trust roots and therefore
does not accept production capture requests. A local fixture adapter validates
the declared export bytes without copying files; its result is not a capture
or runtime qualification. Signed metadata-only artifact envelopes do not
qualify a Core binary.

The protocol is documented in
[`internal/rehearsal/contract`](../internal/rehearsal/contract/README.md).
Each operation records an immutable intent before effects and a terminal result
afterwards. Uncertain mutations quarantine the run and prohibit replay. Run
identities, input hashes and receipt predecessor chains cannot be changed on
resume. Logical diffs distinguish absent from empty values, require a complete
store inventory and exact pre/post allowlists, and compare independently
computed migration deltas from separate runs.

Local checks:

```sh
make -C gonkactl recovery-contract
make -C gonkactl recovery-lifecycle
make -C gonkactl check
```

`recovery-core-rehearsal`, `recovery-incident-rehearsal`, and consequently
`recovery-acceptance` remain non-passing until qualified Core artifacts and
isolated runtime adapters exist. Missing qualification is reported as BLOCKED,
never as a skipped successful acceptance test.
