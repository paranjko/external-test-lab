# Bootstrap maintenance

## Update

### Network policies

Both commands accept `--policy auto|strict|testnet|devnet` (default `auto`).
Auto matches the chain ID case-insensitively: `testnet` takes precedence over
`devnet`; other names use strict. The effective policy is included in JSON and
text output. Explicit strict preserves the original behavior described below.

- Testnet update refreshes the identities and exact Genesis hash of the existing
  seeds, treating a changed Genesis as a network reset. At least two distinct
  RPC endpoints and node identities must agree on Genesis and the requested
  chain ID. It does not require historical participation after reset. All
  retained endpoints must pass checks. Unchanged block height is allowed;
  height regression, catching-up and transport errors are still failures.
- Devnet update discovers guardians and excludes those whose staking identity,
  participant registration or current seed endpoint checks are unavailable.
  Exclusions are reported as warnings, never silent. At least two healthy
  seeds must remain: if fewer than two guardians pass, supplement them with
  the highest-ranked healthy historical participants, stopping at two total
  seeds. Unavailable historical candidates are reported and skipped. A malformed
  staking response or ambiguous participant identity is not treated as an
  unavailable guardian. Genesis stays pinned.
- Strict refuses lineage changes, unavailable guardians and stationary chains.

Validation never refreshes identities/Genesis or drops declared seeds. Testnet
validation only relaxes the block-progress requirement; drift against the
stored bootstrap still fails. Distinct endpoints may share a host on different
ports; neither endpoint count nor agreement proves independent ownership.

### Usage

```sh
gonkactl bootstrap update gonka-devnet-community bootstrap
gonkactl bootstrap update gonka-devnet-community bootstrap net-deployment-runbook/profiles/releases/v2026.10.06.lock --json
```

Update creates or replaces `<chain_id>.json` and `<chain_id>.env` in the
chosen directory. An existing JSON supplies network lineage (subject to the
explicit testnet reset policy above) and the software
recipe; otherwise the published bootstrap supplies them. An invalid existing
JSON is refused, not overwritten with a guessed replacement. A missing or
stale ENV is repaired only after the complete candidate passes validation.
`--base-url` selects the publication origin; timeout, observation and JSON
flags have the same meanings as for validation below.

Two independent existing seed sources must agree on complete discovery
inputs. DevNet uses all current on-chain guardians, mapped through staking
consensus keys to participants and their registered API origins. The public
RPC may be a separate non-validator full node; its consensus key need not
match the participant's key. Under strict policy an unavailable guardian
is an error; devnet policy reports and excludes unavailable guardians.
There is no hard-coded guardian count.
Under strict policy only a confirmed empty list permits historical selection;
devnet also permits supplementation when fewer than two guardians are healthy.
Missing parameters never permit fallback. Other networks use historical
selection directly, except for the testnet reset policy described above.

Historical ranking uses eight completed epoch groups, independently read
from both sources. A participant must be ACTIVE and have positive validation
weight in at least six groups. Rank by qualifying group count, then retained
seed API, then account address. This measures historical participation, not
uptime. Under strict policy the top two must pass current checks; a failed winner
is not replaced by a lower-ranked participant. Devnet supplementation checks
candidates in rank order and reports unavailable candidates before trying the next.
All selected seeds pass the checks
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
remains an operator-approved trust anchor. Strict/devnet refuse lineage changes;
testnet update explicitly permits a reset using agreeing endpoint observations.

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
status, advancing block height (stationary is allowed for testnet) and every declared software image's pinned
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

The repository-local GitHub Action owns installation through the public
`https://gonka-dev.net/ctl/` user path and per-network invocation. The workflow
owns inventory traversal, report retention and Telegram notification. It
continues across failed networks, handles exit 2 explicitly and notifies
once per failed network. Validation itself is entirely in the native command;
the deleted Python monitor's `check`/`notify` interface is not retained.
No Python, SSH, Docker daemon or GDC environment is required by validation.

`--timeout` defaults to 10 seconds per request; `--observation-window`
defaults to 10 seconds. Both are bounded to one minute (the observation
window may be zero for fixtures). The command has a 15-minute overall bound.
