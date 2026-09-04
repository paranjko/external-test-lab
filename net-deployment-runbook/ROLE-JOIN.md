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

Use `--chain-id <id>` to select another Bootstrap document; the default is
`gonka-devnet-community`. The value is accepted only as a safe URL path
segment, and Bootstrap must declare the same chain ID.

Before downloading `inferenced` or preparing a Host, JOIN validates Bootstrap
seed chain identity and uses non-catching-up roots to discover connected
public peers. Each seed and unique public peer can contribute one
software observation. A peer vote is accepted only when the same public IP
also proves the requested chain through its CometBFT identity or DAPI block
header. JOIN first selects the strict-majority DAPI version and commit, then
selects the strict-majority Core version and commit within that DAPI cohort.
The resulting pair must have quorum support.
The reviewed local quorum is two for Community DevNet and three for larger or
unknown networks; one endpoint can never decide. Seed order, duplicate
addresses, unavailable peers and governed DevShard approval order cannot
select the runtime. JOIN records exclusions and quorum arithmetic in a bounded
diagnostic receipt; it never combines components that were not observed
together or chooses a semantic maximum. `--release` and `--composition` are
intentionally not accepted by JOIN. It then creates a local immutable profile,
imports Genesis, creates the Host's accounts, synchronizes the node,
registers it, and waits for `ACTIVE`. With an optional GPU SSH alias, it
qualifies and attaches that MLNode automatically. If no quorum-backed runtime
majority can be established, JOIN stops before Host mutation and retains a
diagnostic.

For an upgraded chain lineage, JOIN uses **state sync** before it creates or
changes anything on the Host. The preflight requires matching observations
from two independent RPC fault domains, a non-expired trust checkpoint, and a
compatible post-upgrade snapshot from both domains. It writes a bounded local
receipt under the selected Host state directory and prints its path for both a
pass and a terminal refusal. Keep that receipt with the retained diagnostic;
it contains the observed lineage evidence, not credentials or validator keys.

If no compatible snapshot is available, the command stops with
`snapshot_unavailable`. It never falls back to historical replay and it never
guesses an older binary or upgrade schedule. Wait for a supported snapshot or
ask the network operator for an approved recovery procedure; do not bypass
the preflight, enable the signer, or retry against a different profile.

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
