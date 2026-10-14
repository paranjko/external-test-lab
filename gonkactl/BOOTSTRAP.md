# Bootstrap maintenance

## Update

```sh
gonkactl bootstrap update gonka-devnet-community bootstrap
gonkactl bootstrap update gonka-devnet-community bootstrap net-deployment-runbook/profiles/releases/v2026.10.06.lock --json
```

Update creates or replaces `<chain_id>.json` and `<chain_id>.env` in the
chosen directory. An existing JSON supplies network lineage and the software
recipe; otherwise the published bootstrap supplies them. An invalid existing
JSON is refused, not overwritten with a guessed replacement. A missing or
stale ENV is repaired only after the complete candidate passes validation.
`--base-url` selects the publication origin; timeout, observation and JSON
flags have the same meanings as for validation below.

Two independent existing seed sources must agree on complete discovery
inputs. DevNet uses all current on-chain guardians, mapped through staking
consensus keys to participants and their registered API origins. The public
RPC may be a separate non-validator full node; its consensus key need not
match the participant's key. An unavailable guardian
is an error, not permission to omit it. There is no hard-coded guardian count.
Only a confirmed empty list permits historical selection; missing parameters
do not. Other networks use historical selection directly.

Historical ranking uses eight completed epoch groups, independently read
from both sources. A participant must be ACTIVE and have positive validation
weight in at least six groups. Rank by qualifying group count, then retained
seed API, then account address. This measures historical participation, not
uptime. The top two must pass current checks; a failed winner is not silently
replaced by a lower-ranked participant. All selected seeds pass the checks
described below before writing.

The optional profile is a **local literal lock file**, never shell code.
The existing-host-stack overlay supports a complete linux/amd64 CUDA recipe.
It updates explicit release fields, preserves the model and unmentioned
services, and refreshes ordered Compose checksums if the immutable source
commit changes. A release.lock alone cannot invent a missing complete recipe;
when local software is absent, published software with the same chain and
Genesis may supply it. Without a profile, existing software still must match
observed runtime. DevNet refuses an absent software recipe.

Update requires matching node/API versions and source commits plus RPC
application versions on at least two independent selected seeds. Every
declared API is checked. Auxiliary-service runtime digests are not exposed
by this public API: their approved pins come from the recipe/profile and are
checked for registry availability, not attested as running containers.

### Writing and recovery

Validation precedes replacement. Identical JSON values preserve existing
formatting; unchanged pairs are not rewritten. `changed` in the JSON report
states whether this invocation wrote a new pair. Ordinary write failures
restore previous bytes and permissions, including absence of newly created
files. No chain writes, deployment or publication occurs.

The directory contains an owned `.gonkactl-<chain_id>.lock` and, while
committing, `.gonkactl-<chain_id>.txn`. A process lock excludes another writer.
The journal records old and new bytes before replacement; rerunning update
rolls back an interrupted partial pair or finalizes a complete pair. Native
validation takes a shared process lock and refuses an active writer or a
pending journal, without creating lock files itself. Foreign edits during recovery are
preserved and require operator inspection, never forced overwrite.

Two flat files cannot be renamed atomically together: do not run legacy
readers or other writers concurrently with update. Each file is flushed and
renamed separately. Directory durability is synced on Unix; Windows recovery
covers process interruption but does not claim POSIX directory-fsync
guarantees. A durability error after both replacements is reported with
`changed: true`. A crash can leave owned temporary `.gonkactl-<chain_id>-*`
files; retain them while inspecting a pending transaction. Do not delete a
recovery journal to bypass a refusal.

## Validate

The source implementation exposes:

```sh
gonkactl bootstrap validate gonka-devnet-community --json
gonkactl bootstrap validate gonka-devnet-community --compare-published bootstrap --json
gonkactl bootstrap validate gonka-devnet-community --path bootstrap --json
```

The default reads the published JSON, ENV and schema. `--compare-published`
also compares both published files byte-for-byte with the named directory;
this is the mode needed by the network bootstrap monitor. `--path` instead
checks a local pair against the embedded schema and cannot be combined with
`--compare-published`. None of these modes writes bootstrap files.

## Monitor compatibility boundary

### Trust boundary

Chain ID and the pinned Genesis digest are consistency checks, not proof that
an RPC serves the canonical chain history. An RPC can claim a chain ID and
return a known Genesis without following that chain. Agreement between two
distinct discovery endpoints reduces single-source errors but does not prove
independent ownership or protect against colluding sources. Validation does
not verify signed chain history or implement a light client. Bootstrap lineage
remains an operator-approved trust anchor; mismatches are refused, not replaced.

### Compatibility

Compatibility means preserving checks and a small report contract, not
embedding the existing Python monitor or its CI environment in the executable.

| Monitor responsibility | Native validation |
| --- | --- |
| Published schema identity, local-only references and permitted extensions | Published validation uses the downloaded schema plus semantic checks |
| Repository/publication drift | `--compare-published` checks exact JSON and ENV bytes |
| Every declared seed | RPC node/chain identity, raw Genesis hash/chain, P2P connection and declared participants API |
| Independent failures | Checks continue for remaining endpoints; invalid descriptors stop unsafe probes |
| Bounded reads and retries | Request timeouts, size limits, transient retries and cancellation; ordinary HTTP redirects refused |
| Machine-readable verdict | JSON is emitted for validation failures as well as successes |

Native validation additionally checks deterministic ENV projection, sync
status, advancing block height and every declared software image's pinned
digest and platform. An absent software section is explicitly not applicable;
an invalid descriptor leaves software presence unknown. Image checks read
registry manifests and small config blobs, not image layers, and never run
containers. Bounded HTTPS redirects are permitted only for registry config
blobs, with authorization stripped; this is separate from bootstrap HTTP.

The JSON envelope has `schema_version`, `observed_at` and `results`. Each
result retains `chain_id`, `bootstrap_url`, `ok` and `checks`; each check has
`stage`, `url`, `ok` and an optional bounded `error`. Consumers must tolerate
additional fields and check stages. Exit codes are 0 for success, 1 for a
failed validation report, and 2 for input or execution errors. Exit 2 need
not produce a report and must not be interpreted as a healthy network.

The future CI wrapper owns inventory traversal, per-network invocation,
report aggregation/retention, `GITHUB_OUTPUT` and Telegram notification. It
must continue across failed networks, handle exit 2 explicitly and notify
once per failed network. The current workflow is unchanged in this feature;
the new command is not a drop-in replacement for its `check`/`notify` syntax.
No Python, SSH, Docker daemon or GDC environment is required by validation.

`--timeout` defaults to 10 seconds per request; `--observation-window`
defaults to 10 seconds. Both are bounded to one minute (the observation
window may be zero for fixtures). The command has a 15-minute overall bound.
