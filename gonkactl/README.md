# gonkactl – implementation draft

This directory preserves an unfinished native Go implementation of gonkactl.
It is a source snapshot for continued development, not an operator-ready
replacement for the existing deployment runbook. The executable currently
exposes help, shell completion, and version only. Recovery and JOIN handlers
are not wired into the CLI.

## Local checks

Use Go 1.27.x, a C compiler for the race detector, and Make on Linux:

```bash
make -C gonkactl check
```

The target checks formatting, runs package tests and `go vet`, runs the race
detector, builds `gonkactl/build/gonkactl`, and checks help/version. It uses the
installed Go toolchain without changing the retained module requirements or
dependency lock. The initial check was run with Go 1.27.1.

Run it without `GONKACTL_TEST_ENV` or `GONKACTL_TEST_RECEIPT`. These portable
checks use temporary files, test doubles, and loopback HTTP servers. They do
not authorize Docker, working-node access, transaction signing, broadcasts,
or a lab campaign. Dependency downloads may be needed on a fresh machine.

## Source layout

- `cmd/gonkactl` and `internal/cli`: executable and command registration.
- `internal/contracts`, `internal/config`, and `internal/operation`: types,
  validation, persistence, and operation helpers.
- Other `internal` packages: retained domain implementations and helper
  scaffolding, including work not yet integrated into the first usable CLI.
- `internal/assets`: embedded schemas and tar bundles, pinned by
  `manifest.json`. Their historical source revision is intentional; updating
  the checkout base does not regenerate these assets.
- `tests/acceptance`: code checks, fixture integrity checks, and unfinished
  lab entrypoints. A passing package test is not an acceptance receipt.
- `../distribution/gonkactl`: retained release scaffolding. The installer
  template is not an installation procedure.

`internal/release/build` contains Go source; only the top-level `build/`
directory is generated output.

## Known completion gaps

- Recovery/JOIN command wiring and end-to-end handler integration remain
  incomplete. Stable private-identity persistence and observation interfaces
  still need their contract decisions and implementation.
- Transaction tests exercise reconciliation helpers. They do not establish
  complete participant registration, funding, or grant readback through the
  real handlers.
- The retained producer archive does not satisfy the required historical
  producer revision. Fixture integrity is a narrower check than producer
  qualification; no producer substitution is approved by this snapshot.
- Lab entrypoints are incomplete and explicitly skip portable execution.
  No lab, live-network, recovery, or JOIN acceptance is claimed.
- The local `check` target is not the full integration/fuzz/acceptance suite.
  Neither first-phase code readiness nor final migration readiness has been
  established. Existing later-phase scaffolding does not authorize advancing
  past the first-phase gate.

Historical receipts and failures remain in the private planning workspace.
This draft neither rewrites those outcomes nor changes frozen contracts.
