# Local recovery rehearsal protocol

`gonkactl recover epoch-length-live-update` prints an offline preview. It does
not query RPC, create a workspace, start processes, or modify a network.

```sh
gonkactl recover epoch-length-live-update --json
```

The new `recover` dispatcher is separate from live `network recover` contracts.
This implementation supplies local protocol primitives and fixture tests, not
a qualified repair executable. Stage and run dispatch through configured
adapters and record their own phase receipts. First verification reads pinned
logical snapshots and, for producer-bound runs, raw Commit, ValidatorSet and
Block H; report renders the result. Default runtime adapters and cleanup
composition are still unavailable. None of these local checks constitutes a
successful runtime rehearsal.

The input library verifies exact signed payloads with caller-injected pinned
Ed25519 trust roots, distinct roles/scopes, time bounds and a current local
revocation snapshot. The CLI contains no production trust roots and therefore
does not accept production capture requests. With explicit trusted dependencies,
capture verifies and copies the declared frozen export before inspecting its
logical stores. Synthetic fixture results are not capture or runtime
qualification. Signed metadata-only artifact envelopes do not
qualify a Core binary.

## Concrete offline inspector

On Linux, capture can select a pinned native inspector through
`--inspector-config <file>`. Its exact JSON bytes must match
`binding.input_digests["inspector-config"]`. The configuration has these fields:

| Fields | Meaning |
| --- | --- |
| `binary_path`, `binary_sha256` | Exact `producer-binary` path and digest from the immutable binding |
| `version`, `source_commit` | Producer provenance, not a qualification assertion |
| `temp_root` | Exact bound `inspector-temp` path: a private dedicated bounded tmpfs mount inside the workspace |
| `max_copy_bytes`, `max_dump_bytes`, `max_output_fs_bytes` | Positive copy, logical dump and physical output limits |
| `reserve_bytes`, `max_log_bytes` | Positive free-space reserve and per-stream log cap |
| `timeout_seconds` | Process deadline, from 1 through 3600 seconds |

The adapter makes a disposable copy of the captured source, checks the expected
`data/application.db`, `data/state.db` and `data/blockstore.db` layout, and adds
the inspector marker only to that disposable copy. It invokes the digest-pinned
executable directly, without a shell or inherited operator environment, using
the producer's fixed `--allowed-root`, `--node-root`, `--out`, `--backend` and
`--max-dump-bytes` flags. The copied source itself is not opened by the producer.
Raw output and local execution evidence are retained under `evidence/inspector`.

This option does not supply trust roots, bypass capture authorization, create
a tmpfs mount, or qualify a producer binary. Local asset provisioning and the
matching planned journal must precede capture; a nonempty workspace without
that journal is still refused. A missing bounded mount is a local process
prerequisite, not a missing Core export. Native-process fixture tests validate
the adapter's mechanics only.

Producer-bound Stage and Run verify **their own** raw evidence before adapter
preflight and again before intent. Preparing the independent repeat is not a
prerequisite for starting the first run. Paired evidence is required later by
first verification. Block H+1 is collected after standard-runtime startup; it
is never a pre-recovery input.

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
