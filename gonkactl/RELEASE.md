# gonkactl 1.0.0-alpha.2

An experimental native CLI for Gonka deployment control.

This alpha adds native bootstrap maintenance. Available commands:

- `gonkactl --help`: inspect available commands.
- `gonkactl completion bash|zsh|fish|powershell`: generate shell completion.
- `gonkactl version`: display version, source commit and build date.
- `gonkactl --version`: display only the version.
- `gonkactl bootstrap update <chain_id> <output_dir> [path_profile]`: discover
  and validate seeds before replacing a local JSON/ENV pair.
- `gonkactl bootstrap validate <chain_id>`: check published bootstrap data,
  seed endpoints and pinned software images without modifying the network.

See [bootstrap maintenance](https://github.com/paranjko/external-test-lab/blob/gonkactl-v1.0.0-alpha.2/gonkactl/BOOTSTRAP.md)
for local validation, publication comparison, trust boundaries and failure reports.

Host JOIN, reset, recovery and other deployment operations are not exposed.
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

Source: https://github.com/paranjko/external-test-lab/tree/gonkactl-v1.0.0-alpha.2/gonkactl
