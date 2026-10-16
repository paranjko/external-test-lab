# gonkactl-trace (experimental)

Read-only incident reconstruction for Gonka: collect RPC responses and selected
logs, retain their provenance, and build a standalone HTML report. This draft
preserves the investigation tooling developed around [incident #143](https://github.com/paranjko/external-test-lab/issues/143).
It is not the `gonkactl` operator CLI or the `gonkactl-test` qualification harness.
It does not repair a network or establish incident causality automatically.

The HTML report is the primary interface. It displays participant membership,
voting power, signatures, validator updates, and available PoC decision evidence.
English and Russian are selectable. Perfetto and OTLP are separate projections
of the retained analysis, not the engine that renders the HTML report.

## Packaged beta

Version `1.0.0-beta.2` provides Linux and macOS binaries for amd64/arm64 and a
Windows amd64 ZIP. The [trace page](https://gonka-dev.net/trace/) links the
versioned assets and the download → verify → inspect → execute installer flow.
Use that page's pinned checksums and trusted-system-shell instructions; do not
pipe downloaded text to a shell. Approve the installation destination first.
Before any execution, verify the installed binary against the binary extracted
from the verified archive and check file/parent ownership and permissions.
Reject untrusted-writable paths. Replace the absolute placeholder below only
with that approved executable path; neither PATH lookup nor version output
establishes provenance. All executable examples in this guide use this rule.

```sh
/approved/absolute/path/gonkactl-trace --version
/approved/absolute/path/gonkactl-trace report mainnet HEAD~10
```

The POSIX installer requires curl or wget, tar (unzip for Windows POSIX shells),
and one of sha256sum, shasum or openssl. It verifies the selected archive before
installing, defaults to `$HOME/.local/bin`, and prints PATH guidance without
editing profiles. Set `GONKACTL_INSTALL_DIR` to an absolute directory, or save
the verified script and run `/bin/sh /verified/path/install.sh --dry-run` /
`/bin/sh /verified/path/install.sh --quiet` after inspection. Native Windows
users verify the pinned manifest and ZIP and use the approved absolute binary
path; adding a directory to PATH is not a provenance check.

`make release-archives` builds all five archives plus `SHA256SUMS` and
`build.json` in an empty `.cache/release/`. Set `TRACE_RELEASE_DIR` to retain a
second build. Release tooling uses Python 3's standard library and Go 1.27.2
in CI; archives are reproducible with the same source and toolchain. Build
time is the source commit timestamp. The standard archives include the HTML
report and native trace exporter; the optional full Perfetto viewer remains a
separate source build. A developer's generated viewer assets cause packaging
to fail instead of silently changing the release.

The release workflow triggers on component tags such as
`gonkactl-trace-v1.0.0-beta.2`, or manual dispatch selecting
that existing tag. It runs source/installer checks, builds all targets, and
publishes a prerelease with [release notes](RELEASE_NOTES.md). Publication
requires the tag, checked-out commit and archive manifest to agree; it never
overwrites an existing release. The separate site pipeline publishes `/trace/`
after integration into main. Publish the release before promoting the page so
the versioned download links resolve. Local builds do not publish either.

## Build from source

Requirements: Go 1.26 or later, a C compiler for race tests, Node.js 22 or later,
Python 3, and Make. Dependency installation needs network access; report
generation from retained inputs does not.

```bash
cd gonkactl-trace
make ui-deps
make all
make demo
```

Open the printed `report.html` path directly in a browser. The demo is generated
from synthetic RPC-shaped records, has no real signatures, and contacts no
network. It demonstrates the presentation, not a real incident outcome.

`make all` runs Go race tests, vet, the binary build, and six UI logic suites.
It neither collects from a live node nor uploads evidence. Tests requiring
private historical samples or a full Perfetto distribution explicitly skip when
those inputs are absent; their separate qualification commands are below.

## How to use gonkactl-trace

Install the packaged binary using the official trace page as described above.
Go and a repository checkout are not prerequisites for ordinary use. Source
builds are an explicit developer workflow, not an installation fallback.

```sh
# Collect and write an HTML report for the latest 101 inclusive heights.
/approved/absolute/path/gonkactl-trace report mainnet HEAD~100
```

The aliases `mainnet`, `devnet`, and `testnet` resolve to `gonka-mainnet`,
`gonka-devnet-community`, and `gonka-testnet`. They read Bootstrap-declared
`chain-rpc` endpoints from `https://gonka-dev.net/<chain-id>/bootstrap.json`,
verify the chain ID, and use another declared endpoint if the first one is
unavailable. A direct `chain-rpc` URL may be used in place of an alias; its
chain ID is read from the selected block. `HEAD` is resolved from that endpoint.
Heights may be absolute, `HEAD`, or `HEAD~N`. In the optional final position,
`+N` means `N` heights after the resolved start: `HEAD~100 +10` is equivalent to
`HEAD~100 HEAD~90`. Named-network ranges are limited to 10,000 blocks.

This command sends read-only HTTP GET requests. It does not broadcast a
transaction, modify a signer, reset a node, or collect private logs. Its output
is private local evidence and must be reviewed before sharing.

## Collect and report

Copy `gonkactl-trace.example.json` to the ignored `gonkactl-trace.json`, then set
your incident label, chain ID, RPC/REST URLs, and authorized log sources. The
example uses loopback URLs and contains no Lab inventory or SSH credentials.

```bash
/approved/absolute/path/gonkactl-trace report --config gonkactl-trace.json 100 120
/approved/absolute/path/gonkactl-trace collect 100 120
/approved/absolute/path/gonkactl-trace report --input .gonkactl-trace/sample-<id>/dataset.json
```

`report <from> [to]` performs the same collection as `collect`, discovers
application queries for the final epoch group in the range, then writes the
analysis, native trace, and HTML report. Heights are inclusive. Omitting `to`
uses the first configured RPC's current height and records that selection.
Flags precede positional heights. Keep historical collections separate from
later observations, especially after a chain reset or recovery.

`report --input` reads retained files only. Preserve the entire sample directory,
not just `dataset.json`. The same binary and inputs reproduce the report bytes,
including after relocation without a derived cache. A fresh live collection is
a new observation and is not expected to be byte-identical.

Outputs below the sample's `derived/perfetto/` directory include:

| Artifact | Contents |
| --- | --- |
| `analysis.json`, `records.jsonl` | Typed events, observations, calculations, provenance, and gaps |
| `incident.pftrace` | Native Perfetto timeline; not the full HTML workspace |
| `matrix.json`, `report.html` | Compact participant view and self-contained report |
| `manifest.json`, `report-manifest.json` | Input fingerprint, analyzer version, and output hashes |

The HTML view focuses on the last four relevant heights. The full selected
history remains in the analysis and trace. Later consensus snapshots carry their
collection time and are not presented as historical vote arrival times.

## Sources and trust

RPC collection covers blocks, commits, validator pages, updates, and current
status/consensus snapshots. Optional REST queries retain requested and reported
historical heights, pagination, errors, and disagreements. The collector does
not treat an unsupported historical query as a historical answer.

Each node can have explicit `logs` entries. For example:

```json
{"component":"core","kind":"docker","path":"my-node-container"}
```

`docker`, `file`, and `journal` sources require that node's configured `ssh`
alias. A `local` source reads an operator-supplied file without SSH. There is no
automatic archive search, key-directory traversal, reset, transaction broadcast,
or signer mutation. Configuration is trusted operator input; collection can be
expensive and should use a bounded range. Sources are capped at 16 MiB;
truncation and source errors remain coverage limitations.

Generated datasets, logs, reports, config files, and exports are private by
default and excluded from this source package. Redaction handles common secret
patterns, not every possible secret. Review every artifact before sharing it.
Only open trusted datasets locally. The offline report embeds source excerpts;
it is not a sanitized public report merely because it opens without a server.

## What remains experimental

- Generic reports derive their visible participant rows from retained validator
  identities in the selected consensus sets. The seven incident labels,
  including `node5-1` and `node5-2`, are reserved for a retained
  `GNK-LAB-2026-0001` dataset and do not appear in a generic network report.
  Labels do not prove historical key ownership, physical signer location, or
  deployment generation.
- The detailed application/PoC causal panel is specific to the original
  incident boundary. Generic ranges get the consensus matrix, not an invented
  application diagnosis. Multi-incident layout and rule selection need further work.
- PoC slot replay is tied to the Gonka source revision recorded in
  [the implementation](ui/causal.mjs). It is not a universal rule for all releases.
- Missing confirmations are distinguished from a negative vote. Where available,
  the panel links worker-filter observations, preservation decisions, and source
  coverage. Unavailable historical API logs leave the cause unknown.
- Signature fields are parsed but not cryptographically verified. A complete
  validator set is not proof that its signers are available. Vote receipt,
  certificate, inferred signing, and later snapshot evidence stay distinct.
- No continuous observer, consensus WAL decoder, clock correction, production
  readiness claim, or end-to-end hosted replay acceptance is included.

## Source layout

The source package keeps the three experiment paths together, with one evidence
model and distinct outputs:

| Path | Entry points | Status in this draft |
| --- | --- | --- |
| Collection and reconstruction | `collect.go`, `dataset.go`, `application_*.go`, `consensus*.go` | Retained sources, normalization, historical-height checks, and explicit gaps |
| HTML investigation | `report*.go`, `perfetto_matrix.go`, `ui/matrix*.mjs`, `ui/causal.mjs` | Primary offline presentation; incident-specific application interpretation |
| Perfetto and OTLP | `perfetto_*.go`, `ui/net.gonka.Consensus/`, `trace.go`, `export.go` | Alternate exports; full Perfetto UI is an optional separate build |

One-off incident preparation scripts, operator inventory, collected datasets,
screenshots, old acceptance reports, and built UI assets are not included.
Historical assertions remain in opt-in regression tests; the public example
does not replace their required original inputs.

## Optional exports and qualification

```bash
/approved/absolute/path/gonkactl-trace otlp > incident.otlp.json
/approved/absolute/path/gonkactl-trace otlp-consensus > incident-consensus.json
/approved/absolute/path/gonkactl-trace perfetto --input .gonkactl-trace/sample-<id> --export-only
```

OTLP commands use the last collection. `run` and `run-consensus` are explicitly
networked alternatives: they upload to TraceKit using `TRACEKIT_API_KEY` from
the environment. Do not use them without permission to transfer that dataset.
No TraceKit credentials are required for collection, offline HTML, or local trace
export; SSH log collection uses the operator's existing SSH access.
HTTP acceptance alone does not prove dashboard visibility or correct replay.

The optional full Perfetto viewer is built with `make release` using the SHA in
`perfetto-build.json`. That downloads and builds Perfetto and its dependencies;
it is not part of the ordinary source checks. Built assets and license notices
are embedded in the binary. Without them, the viewer refuses to substitute a
placeholder; `report` and `--export-only` still work. A separately opened native
trace does not contain the custom tables or the saved HTML view.

Historical qualification remains explicit and requires the retained original
inputs; this public package does not include them:

```bash
GONKACTL_TRACE_SAVED_SAMPLE=/path/to/original/dataset.json make qualify
GONKACTL_TRACE_SAVED_SAMPLE=/path/to/original/dataset.json make qualify-perfetto
make qualify-history HISTORY_ANALYSIS=/path/to/original/analysis.json
```

`qualify-perfetto` also requires the matching original `incident-consensus.json`
and a built Perfetto distribution. Missing required inputs fail these gates.
Their results must not be inferred from passing the synthetic source checks.
