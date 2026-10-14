# gonkactl 1.0.0-alpha.2

This alpha adds native bootstrap maintenance to the standalone CLI.

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
