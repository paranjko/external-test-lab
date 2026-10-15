# Isolated v6 HA storage qualification

This is a source-pinned migration test, not a live HA installer. It exports
Gonka revision `e9d56e2a4e810788ec4be39725026cd892cf1080` from a local Git
repository and applies a Go test overlay. The reference checkout is unchanged.
No stand endpoints, keys or databases are used.

```sh
GONKA_REFERENCE=/path/to/gonka make -C broker-ops test-v6-ha-migration
```

Requirements: Bash, Git, tar, Python3, Go with the frozen module's toolchain,
and a reachable Docker daemon. These executables belong to the runbook's
declared test baseline. Module and PostgreSQL image downloads may need network
access. The explicit source-qualification target is separate from ordinary
source-independent CI. Missing Docker fails; it must not produce a skipped PASS.

The fixture checks real SQLite-to-Postgres session copying, interruption after
one persisted journal chunk, idempotent resume, independent second-client reads,
epoch-conflict refusal and failure on a closed destination. It verifies retained
journal, snapshot and finalized nonce. Containers and temporary source exports
are removed by the fixture, not production resources.

Still required before live HA: payload migration and conflicting payload
preflight, process-level startup/rollback, every supported host layout, the
selected target's preserved identity and storage, real escrow placement, and
controlled replica-loss/recovery with serving evidence. A second database
client is not a second versiond replica. The payload fixture covers plain and
compressed round trips and explicitly characterizes a conflict: the frozen
importer keeps differing destination bytes and quarantines the source without
an error. A passing characterization test means this unsafe-input behavior is
reproduced, not that it is safe to activate HA. A live conflict preflight remains
required. Do not claim HA acceptance from this fixture alone or run the legacy
v4 HA scenario against the v6 stand.

## Read-only payload conflict preflight

`v6-payload-preflight.sh` checks an existing PostgreSQL payload schema against
an offline file-store snapshot using the same frozen source format. Set PGHOST,
PGPORT, PGDATABASE, PGUSER and credentials privately; use a SELECT-only database
role. Never put connection credentials in command arguments or shared logs.

```sh
GONKA_REFERENCE=/path/to/gonka bash broker-ops/v6-payload-preflight.sh \
  -source /absolute/path/to/offline-payload-snapshot
```

The wrapper builds against an isolated export, leaving the reference checkout
unchanged. It requires Git, tar and Go; initial module downloads may need network
access. The check opens a read-only repeatable-read transaction and performs no
schema creation, copying, quarantine or migration. Its JSON result counts absent
and identical destination rows. A differing prompt or response fails without
printing payload bytes or credentials. Missing schema, unreadable source,
noncanonical names, symlinks, unsupported files and duplicate plain/compressed
formats fail closed rather than silently skipping potentially relevant data.
Use a clean payload root, not a parent containing historical quarantines.

A successful comparison is not a migration permit: stop all source/destination
writers in the coordinated maintenance window, retain backups, recheck the exact
source snapshot and target identity, and keep writers stopped through migration.
The database snapshot cannot prevent changes to live files or later database
writes. This check covers payload conflicts only, not session migration, layout,
replica lifecycle, escrow placement or rollback after new PostgreSQL writes.
The named migration test also checks this utility against real PostgreSQL for
absent/identical/conflicting plain and compressed payloads and source preservation.
