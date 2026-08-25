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

`ACTIVE` is an onboarding state, not a successful validator join. The command
continues through a bounded four-epoch acceptance window and returns
`JOIN_PASS` only after it proves a chain-recorded runtime, positive PoC weight,
positive consensus voting power, and authenticated gateway inference.

The verified public bootstrap includes a join-only gateway credential for the
final inference check. It never accepts Genesis private material from the JOIN
operator.

After a successful Genesis or JOIN, the command creates
`$GDC_HOME/<ssh-alias>-validator-backup.tar`. Store this private archive away
from the Host. It is required to restore the same validator after the Host is
fully replaced.

For an independent proof, use a clean checkout and a separate `GDC_HOME`, then
share only the resulting `join-acceptance-<ssh-alias>/` evidence bundle. Its
`receipt.json` contains public chain-verifiable identifiers and no mnemonic,
keyring, client credential, or private account material.

If the SSH alias uses an IP address and DNS cannot be detected automatically,
pass the node's public DNS name explicitly:

```bash
gdc host join --public-host node2.gonka-dev.net gdc-node2
```

## Host lifecycle

```bash
gdc host verify <ssh-alias>
gdc host stop <ssh-alias>
gdc host start <ssh-alias>
gdc host reset <ssh-alias>
gdc host join [--skip-qualification] [--public-host <dns-name>] <ssh-alias> [<gpu-ssh-alias>]
gdc host join --verification [--skip-qualification] [--public-host <dns-name>] <ssh-alias> [<gpu-ssh-alias>]
```

The first form performs the operational connection and creates the recovery
archive. Add `--verification` to wait for chain acceptance, validator
membership, and an authenticated inference regression. It is safe to run that
form again for an already connected Host.

To reuse a previously validated model installation without running the ML
qualification probe again:

```bash
gdc host join --skip-qualification [--public-host <dns-name>] <ssh-alias> [<gpu-ssh-alias>]
```

To restore a fully replaced Host, use the same JOIN command with its saved
archive:

```bash
gdc host join --public-host <dns-name> --restore <ssh-alias>-validator-backup.tar <ssh-alias>
```

To refresh the private recovery archive while operator state is still
available, run:

```bash
gdc host backup <ssh-alias>
```

The archive is written as `<ssh-alias>-validator-backup.tar` in the operator
data root. For a split Host, the saved topology supplies and verifies its ML
alias automatically; the Network Node owns validator identity.

`host reset` removes only runbook-managed services and state for that Host.
Its chain account remains owned by the operator.

If the GPU runs on another machine, see `host ml-attach` in
[ROLE-HOST.md](ROLE-HOST.md).
