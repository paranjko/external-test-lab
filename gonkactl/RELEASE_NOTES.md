# gonkactl 1.0.0-alpha.1

The first alpha distributes the native Gonka deployment-control implementation
draft as standalone binaries.

## Available capabilities

- Help and shell completion for Bash, Zsh, Fish and PowerShell.
- Version output with source commit and build date.
- Linux, macOS and Windows archives for amd64 and arm64, with SHA-256 checksums.
- A POSIX installer with checksum verification and atomic user-local installation.

## Requirements and limits

The binary needs no Go installation. The shell installer needs curl or wget,
tar (unzip on Windows), and sha256sum or shasum.

This is an early distribution preview. Host JOIN, reset, recovery and deployment
commands are not wired into the executable. Internal implementation packages
are unfinished and do not establish node-operation or migration readiness.

Install instructions and downloads: https://gonka-dev.net/ctl/
