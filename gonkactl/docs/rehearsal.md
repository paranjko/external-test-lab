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

The capture verifier checks versioned signed envelopes for snapshot freeze,
layout, inventory, witness and offline-reader evidence. When a trust policy is
loaded, the CLI composes this verifier from its pinned Ed25519 roots,
revocation snapshot and clock; callers do not inject a separate proof
verifier. The checks bind envelope signatures, roles, scopes, validity windows
and payloads to the immutable run context. Witness verification also checks
the raw Comet commit and validator set.

The envelope contract and verifier are implemented. A fresh synthetic CLI
capture uses the shipped command, an explicit local trust policy, real signed
envelopes and raw Comet witness material; it proves only the frozen-copy
capture prefix. It is not producer-issued incident evidence and does not
qualify a runtime. The CLI has no production trust roots, and signed
metadata-only artifact envelopes do not qualify a Core binary.

For an approved future snapshot, the operator invokes capture only with every
bound input explicitly named:

```sh
gonkactl recover epoch-length-live-update capture --apply \
  --run-id "$RUN_ID" --workspace "$WORKSPACE" --binding "$BINDING" \
  --source-manifest "$SOURCE_MANIFEST" --catalog "$CATALOG" \
  --recovery-artifact "$RECOVERY_ARTIFACT" \
  --capture-approval "$CAPTURE_APPROVAL" \
  --capture-evidence "$CAPTURE_EVIDENCE" \
  --trust-policy "$TRUST_POLICY"
```

All paths above must already be part of the immutable run binding or its
approved local policy. The command creates only the owned frozen copy and
capture receipt. It refuses missing, expired, revoked, malformed, mismatched
or unsigned inputs before copying; it does not start control, recovery or
standard runtime. Do not use this command against DevNet without the separate
snapshot authorization and the matching Core producer packet.

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

## Native execution boundary

Rehearsal containers execute the digest-pinned selected `inferenced` directly as PID 1, the selected binary is mounted read-only and checked again during runtime inspection

Bindings containing the former wrapper entrypoint are rejected, create a fresh binding rather than changing an existing journal or its evidence

The incident-only command is excluded from ordinary release builds and requires the `gnklab0002_live` build tag

Its controller uses a Go SSH client with explicit `--ssh-identity` and `--ssh-known-hosts` files, the inspected host and port are fixed by the node inventory

Each host must already have the native Linux Go agent installed at `/usr/local/libexec/gonkactl-incident`, its SHA256 must be supplied through `--agent-sha256`

The controller sends only a fixed agent executable and allowlisted tokens, the agent hashes its running executable before any operation and uses Docker HTTP API and native filesystem operations instead of shell scripts or Python

Agent installation is an explicit prerequisite, this command does not upload itself, install dependencies, reset signing state or provision a host

The native agent is a new implementation of the incident operations, earlier live recovery receipts belong to the earlier implementation and do not qualify this native revision on a live network
