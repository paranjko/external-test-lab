# Bootstrap maintenance

## Update

### Network policies

Both commands accept `--policy auto|strict|testnet|devnet` (default `auto`).
Auto matches the chain ID case-insensitively: `testnet` takes precedence over
`devnet`; other names use strict. The effective policy is included in JSON and
text output. Policies control update selection and lineage, not network health.

- Testnet update refreshes the identities and exact Genesis hash of the existing
  seeds, treating a changed Genesis as a network reset. At least two distinct
  RPC endpoints and node identities must agree on Genesis and the requested
  chain ID. It does not require historical participation after reset. All
  retained endpoints must pass identity, Genesis and connectivity checks.
- Devnet update discovers guardians and excludes those whose staking identity,
  participant registration or current seed endpoint checks are unavailable.
  Exclusions are reported as warnings, never silent. At least two reachable
  seeds must remain: if fewer than two guardians pass, supplement them with
  the highest-ranked reachable historical participants, stopping at two total
  seeds. Unavailable historical candidates are reported and skipped. A malformed
  staking response or ambiguous participant identity is not treated as an
  unavailable guardian. Genesis stays pinned.
- Strict refuses lineage changes and unavailable guardians.

Validation never refreshes identities/Genesis or drops declared seeds. Its checks
are the same under every policy; drift against the stored bootstrap still fails.
Distinct endpoints may share a host on different
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
`--base-url` selects the publication origin; timeout and JSON
flags have the same meanings as for validation below.

Two independent existing seed sources must agree on complete discovery
inputs. DevNet uses all current on-chain guardians, mapped through staking
consensus keys to participants and their registered API origins. The public
RPC may be a separate non-validator full node; its consensus key need not
match the participant's key. Under strict policy an unavailable guardian
is an error; devnet policy reports and excludes unavailable guardians.
There is no hard-coded guardian count.
Under strict policy only a confirmed empty list permits historical selection;
devnet also permits supplementation when fewer than two guardians are reachable.
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
Genesis may supply it. Software is optional for every network, including DevNet.
When declared, its complete recipe and image availability are checked; it describes
what to install, not what every seed currently runs. Running versions, application
health, synchronization and consensus progress are outside bootstrap validation.
Discovery reads chain APIs only to obtain selection inputs, not to attest health.

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
| Every declared seed | RPC node/chain identity, raw Genesis hash/chain and P2P TCP connection |
| Independent failures | Checks continue for remaining endpoints; invalid descriptors stop unsafe probes |
| Bounded reads and retries | Request timeouts, size limits, transient retries and cancellation; ordinary HTTP redirects refused |
| Machine-readable verdict | JSON is emitted for validation failures as well as successes |

Native validation additionally checks deterministic ENV projection and every declared software image's pinned
digest and platform. An absent software section is explicitly not applicable;
an invalid descriptor leaves software presence unknown. Image checks read
registry manifests and small config blobs, not image layers, and never run
containers. Bounded HTTPS redirects are permitted only for registry config
blobs, with authorization stripped; this is separate from bootstrap HTTP.

A reachable syncing node or a stalled/unhealthy network can still provide a valid
bootstrap connection point. No block-height, catching-up, participants-health API
or running-software check is performed. P2P probing is TCP reachability, not a
CometBFT handshake. PASS means bootstrap usability, not network health or successful
JOIN. The former `--observation-window` option is removed.

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

`--timeout` defaults to 10 seconds per request and is bounded to one minute.
The command has a 15-minute overall bound.
