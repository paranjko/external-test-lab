# gonkactl 1.0.0-alpha.6

An experimental native CLI for Gonka deployment control.

This alpha supports policy-driven native bootstrap maintenance. Available commands:

- `gonkactl --help`: inspect available commands.
- `gonkactl completion bash|zsh|fish|powershell`: generate shell completion.
- `gonkactl version`: display version, source commit and build date.
- `gonkactl --version`: display only the version.
- `gonkactl bootstrap update <chain_id> <output_dir> [path_profile]`: discover
  and validate seeds before replacing a local JSON/ENV pair.
- `gonkactl bootstrap validate <chain_id>`: check published bootstrap data,
  seed endpoints and pinned software images without modifying the network.

See [bootstrap maintenance](https://github.com/paranjko/external-test-lab/blob/gonkactl-v1.0.0-alpha.6/gonkactl/BOOTSTRAP.md)
for local validation, publication comparison, trust boundaries and failure reports.
Both bootstrap subcommands accept `--policy auto|strict|testnet|devnet`; auto
selects testnet reset behavior or devnet guardian exclusion
and historical supplementation by chain name. Other networks remain strict.
Bootstrap checks connectivity, identity and optional installation images, not
network health, synchronization, block progress or currently running versions.

The local `recover epoch-length-live-update` protocol provides an offline preview and explicitly authorized capture, verification and report operations, see [rehearsal prerequisites and limits](https://github.com/paranjko/external-test-lab/blob/gonkactl-v1.0.0-alpha.6/gonkactl/docs/rehearsal.md)

H+1 is observed and independently verified after standard-runtime startup, then its identity is durably pinned, it is not required as a pre-launch input

The incident-only native Go host agent requires a separate build tag and explicit installation, it is not included in ordinary release binaries

Recovery rehearsal operations are unavailable on Windows, those binaries retain bootstrap maintenance, help and version commands without weakening Unix recovery protections

Darwin supports offline rehearsal inspection and input validation only, persisted evidence, capture, stage and run operations require Linux

Host JOIN, reset, general live recovery and other deployment operations are not exposed.
Do not use this alpha as a replacement for the deployment runbook.
Cross-platform packaging does not qualify unfinished native host operations.

Download the archive for your operating system and processor, check its SHA-256
against `checksums.txt`, and extract `gonkactl` (or `gonkactl.exe`) into a
directory on PATH. No Go installation is required.

On Linux and macOS:

```sh
curl -LsSf https://gonka-dev.net/ctl/install.sh | sh
gonkactl version
```

The installer defaults to `$HOME/.local/bin`. Set `GONKACTL_INSTALL_DIR`
to an absolute directory to override it. It verifies the checksum and version
before atomically replacing the installed binary; it never edits shell files.
Windows users can extract the ZIP directly, or use the installer in Git Bash.

This source prepares alpha.6, it does not publish release assets or change the installed CLI

The public installer and download page remain on the previously published version until release publication is verified
