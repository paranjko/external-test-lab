# JOIN: add a Host

JOIN uses one signed network bootstrap document. Your SSH alias, public Host,
P2P port, and optional ML Host remain local to your machine.

## Download and verify a bootstrap

Download the schema and the network document you intend to use. Attestation
verification is optional and checks the downloaded bytes' repository origin;
local validation checks the document's chain, Genesis, seed, and service data.

```bash
wget -O v1.bootstrap.schema.json https://gonka-dev.net/v1.bootstrap.schema.json
gh attestation verify v1.bootstrap.schema.json -R paranjko/external-test-lab

wget -O gonka-devnet-community.bootstrap.json \
  https://gonka-dev.net/gonka-devnet-community/bootstrap.json
gh attestation verify gonka-devnet-community.bootstrap.json -R paranjko/external-test-lab
```

The same schema supports the other published networks; keep each downloaded
file distinct before verifying it:

```bash
wget -O gonka-mainnet.bootstrap.json \
  https://gonka-dev.net/gonka-mainnet/bootstrap.json
wget -O gonka-testnet.bootstrap.json \
  https://gonka-dev.net/gonka-testnet/bootstrap.json
gh attestation verify gonka-mainnet.bootstrap.json -R paranjko/external-test-lab
gh attestation verify gonka-testnet.bootstrap.json -R paranjko/external-test-lab
```

The descriptor carries only chain identity, RPC/P2P seeds, optional participant
registration APIs, and optional broker discovery. It never contains Genesis
bytes, credentials, topology, or release-profile data. `genesis.sha256` is the
distribution-integrity hash of the exact file written by `inferenced
download-genesis`, not a consensus-defined chain fingerprint.

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

gdc network bootstrap verify gonka-devnet-community.bootstrap.json
gdc network bootstrap verify --online gonka-devnet-community.bootstrap.json
gdc host join --bootstrap-file gonka-devnet-community.bootstrap.json --public-host <IP_or_DOMAIN> <ssh-alias>
```

`bootstrap.env` is a generated compatibility projection, not an independent
input. Download it only alongside the matching JSON, verify its attestation,
generate the projection locally from the verified JSON, compare the bytes, and
inspect it before applying it to an operator-owned local environment. Do not
execute shell content directly from a URL.

For Community DevNet, the simple form downloads the same network document:

```bash
gdc host join --public-host <IP_or_DOMAIN> <ssh-alias>
```

## Restore a cold account

Never put a mnemonic in a command line. Use exactly one source:

```bash
# Read a 12- or 24-word phrase without echoing it
gdc host join --mnemonic-prompt --public-host <IP_or_DOMAIN> <ssh-alias>

# Read plaintext or JSON with {"mnemonic":"..."}
gdc host join --mnemonic-file "$GDC_HOME/<ssh-alias>-cold-backup.json" \
  --public-host <IP_or_DOMAIN> <ssh-alias>
```

`--mnemonic-prompt` requires a TTY. `--mnemonic-file` accepts only an
operator-owned regular file with mode `0400` or `0600`; symlinks are refused.
The cold mnemonic stays on the operator machine, where it restores the local
cold account and signs any participant-key rebind. It is not sent to the Host.

Do not combine either option with `--restore`:

```bash
gdc host join --restore <validator-backup.tar> \
  --public-host <IP_or_DOMAIN> <ssh-alias>
```

Without a second SSH alias, JOIN prepares `<ssh-alias>` as a `network-gpu`
Host and requires a visible NVIDIA PCI device with an R580+ driver. To keep
the network Host CPU-only, supply a separate ML Host alias; JOIN prepares the
network Host as `network-only` and the ML Host as `ml-only`, where the NVIDIA
GPU is required. Before changing packages, JOIN verifies both the NVIDIA PCI
device and an Ubuntu-provided R580+ driver candidate.

Use `--chain-id <id>` to select another Bootstrap document; the default is
`gonka-devnet-community`. The value is accepted only as a safe URL path
segment, and Bootstrap must declare the same chain ID.

Before Host mutation, JOIN requires two consecutive quorum-backed runtime
observations and confirms them again immediately before preparation. The
default deadline is 30 minutes; use `--preflight-deadline 60m` deliberately.
`--release` and `--composition` are intentionally not accepted by JOIN. A
runtime change restarts preflight without touching the Host.

If driver installation needs a reboot, JOIN stops before identity or deployment
creation. Reboot and rerun the same command; no `host reset` is needed.

JOIN uses state sync and requires matching lineage observations from two
independent RPC domains. `snapshot_unavailable` is terminal: JOIN never
guesses old binaries or falls back to historical replay.

Use a lowercase SSH alias beginning with a letter or digit and containing only
lowercase letters, digits, `_`, or `-`. The alias is also the Docker Compose
project name on the Host.

`ACTIVE` is an onboarding state, not a successful validator join. Ordinary
JOIN finishes after mandatory installation, synchronization, registration,
permissions, and recovery-archive creation. Request the longer acceptance
proof explicitly when the operator needs it:

```bash
gdc host join --verification --public-host <IP_or_DOMAIN> <ssh-alias>
```

Only `--verification` enters the bounded six-epoch acceptance window and
returns `JOIN_PASS` after proving a chain-recorded runtime, positive PoC
weight, positive consensus voting power, and authenticated gateway inference.

The mandatory completion result is not `JOIN_PASS`. `ACTIVE` alone does not
prove a successful validator join; `JOIN_PASS` is available only from explicit
verification.

After a successful Genesis or JOIN, the command creates
`$GDC_HOME/<ssh-alias>-validator-backup.tar`. Store this private archive away
from the Host. It preserves the operator-owned validator material for a future
documented recovery procedure.

If the SSH alias uses an IP address and DNS cannot be detected automatically,
pass the node's public DNS name explicitly:

```bash
gdc host join --public-host node2.gonka-dev.net gdc-node2
```

## Repeat and recovery scope

The same JOIN command may be repeated for a complete matching local state. It
queries registration before submission and must not create a second
participant, funding claim, or validator identity. A partial, conflicting,
different-lineage, or unreachable state stops before deployment changes.

A stop before the first Host change is recorded as a refusal with
`mutation: none`: the terminal result and the diagnostic that `gdc report
github` renders state what was found, and the next `gdc host join` classifies
the Host afresh instead of demanding manual recovery.

| Stop | Meaning | Way back |
|---|---|---|
| `partial_identity` | the operator state holds some of the identity record, the cold account and the joined marker, but not all three | restore with `--restore` from the validator archive; without an archive, `gdc host reset` clears an unregistered identity so the next JOIN starts as `new`, and keeps a registered one until the archive exists |
| `identity_conflict` | the Host holds a validator identity that the operator state does not know | restore with `--restore` from the archive of that identity; `gdc host reset` removes it only when the chain does not know its participant, never adopt it |
| `unreachable` | no SSH session to the Host | repeat the same command once the Host is reachable |

`gdc host backup` creates the archive only while the deployment is present on
the Host; create it before any `gdc host reset`.

For a validated private archive, use the same supported interface:

```bash
gdc host join --restore <validator-backup.tar> --public-host <IP_or_DOMAIN> <ssh-alias>
```

The archive is an assertion, not permission to replace identity or software
selection. A matching running Host is recovered only after identity, lineage,
signer, and selected-composition checks; an empty Host is restored only after
archive validation. Historical software facts in the archive are diagnostic
evidence only. Do not bypass
qualification or use this interface to reset, recreate Genesis, or adopt an
unknown existing validator.

If the GPU runs on another machine, see `host ml-attach` in
[ROLE-HOST.md](ROLE-HOST.md).
