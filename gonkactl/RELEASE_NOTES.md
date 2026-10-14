# gonkactl 1.0.0-alpha.5

Alpha.5 limits bootstrap validation to connection points, network identity and
optional installation software. Syncing or stalled networks can have usable
bootstraps: block height, catching-up, participant health and running versions
are no longer validation gates. RPC identity/Genesis, P2P reachability and pinned
image availability remain required. Software is optional on every network.
The obsolete `--observation-window` flag is removed, not silently ignored.

Alpha.4 introduced explicit bootstrap policies: `--policy auto|strict|testnet|devnet`.
Auto chooses by chain name. Testnet update accepts a reset only after distinct
RPC endpoints agree on the requested chain ID and Genesis. Devnet update excludes
unavailable guardians with warnings and fills a shortfall to two reachable seeds
using corroborated historical participation. Reachable guardians keep priority.
Failed final checks preserve the
existing files. Validation remains read-only and does not hide declared seed failures.

The previous alpha.3 expanded discovery on networks with more than 2,000 participants. The
inventory now accepts up to 100 pages of 100 entries and still refuses an
incomplete inventory. Candidate identity errors identify the affected public
RPC. Public RPC endpoints may be separate non-validator full nodes; their
consensus keys need not match participant validator keys. Guardian-to-participant
mapping, selection and pinned Genesis checks remain required. These checks
establish consistency, not cryptographic proof of canonical chain history.

## Available capabilities

- Bootstrap update with on-chain guardian discovery, historical fallback and
  validated, journaled JSON/ENV replacement. Failed validation preserves files.
- Read-only bootstrap validation, optional published-file comparison, and
  pinned OCI image digest/platform checks without Docker or image-layer downloads.
- Structured JSON validation reports and distinct validation/execution exit codes.
- Help and shell completion for Bash, Zsh, Fish and PowerShell.
- Version output with source commit and build date.
- Linux, macOS and Windows archives for amd64 and arm64, with SHA-256 checksums.
- A POSIX installer with checksum verification and atomic user-local installation.

## Requirements and limits

The binary needs no Go installation. The shell installer needs curl or wget,
tar (unzip on Windows), and sha256sum or shasum.

Live network failures are reported, not repaired or hidden. A successful release
build does not establish the health of a network or prove a live bootstrap refresh.

This is an early distribution preview. Host JOIN, reset, recovery and deployment
commands are not wired into the executable. Internal implementation packages
are unfinished and do not establish node-operation or migration readiness.

Install instructions and downloads: https://gonka-dev.net/ctl/
