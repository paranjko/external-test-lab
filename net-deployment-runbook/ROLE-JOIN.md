# JOIN: add a Host

JOIN uses one signed network bootstrap document. Your SSH alias, public Host,
P2P port, and optional ML Host remain local to your machine.

## Download and verify a bootstrap

Download the schema and the network document you intend to use. Attestation
verification is optional and checks the downloaded bytes' repository origin;
local validation checks the document's chain, Genesis, seed, and service data.

```bash
wget https://gonka-dev.net/v1.bootstrap.schema.json
gh attestation verify v1.bootstrap.schema.json -R paranjko/external-test-lab

wget https://gonka-dev.net/bootstrap/gonka-mainnet.json
gh attestation verify gonka-mainnet.json -R paranjko/external-test-lab

wget https://gonka-dev.net/bootstrap/gonka-testnet.json
gh attestation verify gonka-testnet.json -R paranjko/external-test-lab

wget https://gonka-dev.net/bootstrap/gonka-devnet-community.json
gh attestation verify gonka-devnet-community.json -R paranjko/external-test-lab
```

The Community DevNet document may contain a scoped, public client credential
for its final inference check. It is not a private operator key. Never add
private keys, mnemonics, SSH credentials, or administrator tokens to a
bootstrap document.

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

gdc network bootstrap verify gonka-devnet-community.json
gdc host join --bootstrap-file gonka-devnet-community.json --public-host <IP_or_DOMAIN> <ssh-alias>
```

For Community DevNet, the simple form downloads the same network document:

```bash
gdc host join --public-host <IP_or_DOMAIN> <ssh-alias>
```

The command validates and imports the public Genesis bootstrap, creates the
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

The observable successful result is `JOIN_PASS`. `ACTIVE` alone does not prove
a successful validator join.

After a successful Genesis or JOIN, the command creates
`$GDC_HOME/<ssh-alias>-validator-backup.tar`. Store this private archive away
from the Host. It preserves the operator-owned validator material for a future
documented recovery procedure.

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
