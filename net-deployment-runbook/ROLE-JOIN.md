# JOIN: add a Host

JOIN is a single command for the operator who owns the target Host. The
operator creates and keeps the Host's accounts and identities; the command
imports only the public Genesis bootstrap.

## Join

```bash
cat >> ~/.ssh/config <<'EOL'
Host <ssh-alias>
  HostName <IP_or_DOMAIN>
  User root
  Port <PORT> # optional
EOL

git clone https://github.com/paranjko/external-test-lab.git
alias gdc="$PWD/external-test-lab/net-deployment-runbook/gdc.sh"

# Local runtime data defaults to `GDC_HOME=$HOME/.gdc-data`
# Optional: choose a different local data directory
# export GDC_HOME=/absolute/path

gdc host join --public-host <IP_or_DOMAIN> <ssh-alias>
```

The command verifies and imports the public Genesis bootstrap, creates the
Host's accounts, installs the pinned release, synchronizes the node, registers
it, and waits for `ACTIVE`. With an optional GPU SSH alias, it qualifies and
attaches that MLNode automatically.

Use a lowercase SSH alias beginning with a letter or digit and containing only
lowercase letters, digits, `_`, or `-`. The alias is also the Docker Compose
project name on the Host.

`ACTIVE` is an onboarding state, not a successful validator join. The command
continues through a bounded six-epoch acceptance window: two onboarding
transitions followed by four effective-evidence epochs. It returns
`JOIN_PASS` only after it proves a chain-recorded runtime, positive PoC weight,
positive consensus voting power, and authenticated gateway inference.

The verified public bootstrap includes a join-only gateway credential for the
final inference check. It never accepts Genesis private material from the JOIN
operator.

After a successful Genesis or JOIN, the command creates
`$GDC_HOME/<ssh-alias>-validator-backup.tar`. Store this private archive away
from the Host. It preserves the operator-owned validator material for a future
documented recovery procedure.

For an independent proof, use a clean checkout and a separate `GDC_HOME`, then
share only the resulting `join-acceptance-<ssh-alias>/` evidence bundle. Its
`receipt.json` contains public chain-verifiable identifiers and no mnemonic,
keyring, client credential, or private account material.

If the SSH alias uses an IP address and DNS cannot be detected automatically,
pass the node's public DNS name explicitly:

```bash
gdc host join --public-host node2.gonka-dev.net gdc-node2
```

## Supported scope

This guide documents one first-time independent Host connection. It creates a
private validator backup as part of that flow. Repairing an existing Host,
restoring a replaced Host, bypassing qualification, and broader Host lifecycle
operations are not supported by this first-time JOIN interface. Do not use
this guide to claim that an existing Host can be repaired or rejoined
automatically.

If the GPU runs on another machine, see `host ml-attach` in
[ROLE-HOST.md](ROLE-HOST.md).
