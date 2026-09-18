# JOIN: add a Host

JOIN uses one bootstrap document; gdc does not verify its attestation. Your
SSH alias, public Host, P2P port and optional ML Host are your own
command-line inputs, not part of that document.

## Download a bootstrap document

Download the schema and the bootstrap document of the network you intend to
use. Attestation verification is optional and checks the downloaded bytes'
repository origin; local validation checks only the document's format.
`--online` also checks its seeds and Genesis against the network.

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

The bootstrap document carries only chain identity, RPC/P2P seeds, optional
participant registration APIs, and optional broker discovery. It never contains Genesis
bytes, credentials, topology, or release-profile data. `genesis.sha256` is the
distribution-integrity hash of the exact file written by `inferenced
download-genesis`, not a consensus-defined chain fingerprint.

## Join

Run these commands on your operator machine; it needs `jq`, `curl`, `unzip`,
`rsync`, and `openssl`.

```bash
cat >> ~/.ssh/config <<'EOL'
Host <ssh-alias>
  HostName <IP_or_DOMAIN>
  User root
  # Port <PORT>
EOL
ssh -o BatchMode=yes <ssh-alias> true  # must succeed: key login, accepted host key

git clone https://github.com/paranjko/external-test-lab.git
alias gdc="$PWD/external-test-lab/net-deployment-runbook/gdc.sh"

# Local runtime data defaults to `GDC_HOME=$HOME/.gdc-data`
# Optional: choose a different local data directory
# export GDC_HOME=/absolute/path

gdc network bootstrap verify gonka-devnet-community.bootstrap.json
gdc host join --bootstrap-file gonka-devnet-community.bootstrap.json --public-host <IP_or_DOMAIN> <ssh-alias>
```

`gdc network bootstrap verify --online <file>` is an optional live check: it
needs a compatible `inferenced` on `PATH` and fails if any listed seed or
broker does not pass. JOIN needs neither: it installs its own pinned CLI,
and its preflight needs only a quorum of seeds. Registration, DevNet faucet
funding and the `ACTIVE` wait use a single seed (node0 on Community DevNet);
if it does not answer, JOIN stops after Host preparation.

`bootstrap.env` is a generated compatibility projection, not an independent
input. Download it only alongside the matching JSON, verify its attestation,
generate the projection locally from the verified JSON, compare the bytes, and
inspect it before applying it to an operator-owned local environment. Do not
execute shell content directly from a URL.

For Community DevNet, the simple form downloads the same bootstrap document:

```bash
gdc host join --public-host <IP_or_DOMAIN> <ssh-alias>
```

## Restore a cold account

Never put a mnemonic in a command line. Use exactly one source:

```bash
# Read a 12- or 24-word phrase without echoing it
gdc host join --mnemonic-prompt --public-host <IP_or_DOMAIN> <ssh-alias>

# Read plaintext or JSON with {"mnemonic":"..."}
gdc host join --mnemonic-file <cold-mnemonic-file> \
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
GPU is required. Before installing a driver, JOIN verifies the NVIDIA PCI
device and, when no R580+ driver is loaded, an Ubuntu-provided R580+ candidate.

Use `--chain-id <id>` to select another network's bootstrap document; the
default is `gonka-devnet-community`. The value is accepted only as a safe URL
path segment, and the document must declare the same chain ID.

Before Host mutation, JOIN requires two consecutive quorum-backed runtime
observations and confirms them again immediately before preparation. The
default deadline is 30 minutes; use `--preflight-deadline 60m` deliberately.
`--release` and `--composition` are intentionally not accepted by JOIN. A
runtime change restarts preflight without touching the Host.

If driver installation needs a reboot, JOIN stops with exit 194. Reboot the Host
listed under `REBOOT` and rerun the same command; a JOIN without `--restore`
needs no `host reset`.

JOIN uses **state sync** and checks the chain lineage before it creates or
changes anything on the Host. The preflight requires matching observations
from two independent RPC fault domains, a non-expired trust checkpoint, and
two P2P snapshot providers. It does not fetch a snapshot: whether one is
served is proven later, by a signerless canary on the Host. It writes a
receipt to `$GDC_HOME/<ssh-alias>/state/` on your machine and prints its path;
the receipt holds the observed lineage evidence, not credentials or validator
keys.

JOIN repeats this preflight just before the canary. A canary that catches up
later than the receipt's lifetime, 600 seconds unless
`GDC_JOIN_PREFLIGHT_TTL_SECONDS` is set for that run, stops JOIN with
`lineage_trust_expired`; one that does not catch up within an hour stops it
with `lineage_snapshot_unavailable`. Both stops come after JOIN has changed
the Host, so run `gdc host reset` before the next JOIN. JOIN never falls back
to guessed old binaries or historical replay.

Use a lowercase SSH alias beginning with a letter or digit and containing only
lowercase letters, digits, `_`, or `-`. The alias is also the Docker Compose
project name on the Host.

For the published images JOIN requires `adx`, `bmi1` and `bmi2` on the network
Host CPU and refuses without them only after preparing the Host;
`ssh <ssh-alias> grep -ow -e adx -e bmi1 -e bmi2 /proc/cpuinfo | sort -u` must
print all three. Otherwise build and declare images as in
[PORTABLE-RUNTIME.md](PORTABLE-RUNTIME.md).

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
The gateway check uses a client key that only the network operator's state
holds, so without it acceptance cannot return `JOIN_PASS`. With
`--verification`, unless acceptance returns `JOIN_PASS`, `COMPLETE` is not
recorded, and `gdc host start` and a repeated JOIN are then refused; an
independent operator therefore omits `--verification`. A repeat after
`COMPLETE` does not run acceptance.

Voting power follows the first accepted PoC, normally one or two epochs after
`ACTIVE`. JOIN enables the signer first and then waits up to 2400 seconds for
the first signature, printing a `WAIT` line about once a minute. If none comes,
the ordinary JOIN still finishes with the signer on, but a `--restore` stops;
after the first signature,
`gdc host join --resume <run_id> --public-host <IP_or_DOMAIN> <ssh-alias>`
finishes it, with `<run_id>` from the `BEGIN` line.

An ordinary JOIN exits 0 after printing
`PASS Host JOIN mandatory convergence complete; full lifecycle verification was not requested`
and `END host join SUCCESS`; `JOIN_PASS` appears only with `--verification`.

After a successful Genesis or JOIN, the command creates
`$GDC_HOME/<ssh-alias>-validator-backup.tar`. It is not encrypted and holds
the cold and warm mnemonics and the validator signing key; protect it like the
mnemonics.

`--public-host` is required for every `gdc host join`. JOIN registers
`https://<IP_or_DOMAIN>` on chain as the participant URL and checks only that
the value resolves to an IPv4 address; for a DNS name, create its record first.

## Repeat and recovery scope

The same JOIN command may be repeated for a complete matching local state. It
queries registration before submission and must not create a second
participant, funding claim, or validator identity. The repeat must come from
the same gdc revision, with the same `GDC_PORTABLE_*` declaration if one was
used; another revision is refused with `join_reentry_profile_changed` before
any change. After `--restore` onto a reset Host, only a repeat that names an
unchanged copy of the restored archive can be a no-op: JOIN rewrites
`$GDC_HOME/<ssh-alias>-validator-backup.tar`, and any other repeat is refused
the same way. A partial, conflicting, different-lineage, or unreachable state
stops before deployment changes.

The `partial_identity`, `identity_conflict` and `unreachable` stops come
before the first Host change and are recorded as a refusal with
`mutation: none`: the terminal result and the diagnostic that `gdc report
github` renders state what was found, and the next `gdc host join` classifies
the Host afresh instead of demanding manual recovery.

| Stop | Meaning | Way back |
|---|---|---|
| `partial_identity` | the operator state holds some of the identity record, the cold account and the joined marker, but not all three | restore with `--restore` from the validator archive; `gdc host reset` clears the identity only when the chain reports the participant as unregistered, and the next JOIN then starts as `new` |
| `identity_conflict` | the Host holds a validator identity that the operator state does not know | restore with `--restore` from the archive of that identity; `gdc host reset` keeps it, because without a cold account it cannot ask the chain about the participant; without that archive there is no supported way back; never adopt it |
| `unreachable` | no SSH session to the Host | repeat the same command once the Host is reachable |
| `completed_join_readback_failed` | a repeat of a completed JOIN could not confirm that the Host still runs as that JOIN left it; the Host was not changed | repeat once the Host is reachable and running, with the same `GDC_PORTABLE_*` declaration if one was used |
| exit 194 | host preparation installed the NVIDIA driver and a Host needs a reboot | reboot the Host listed under `REBOOT` and repeat the same command; a JOIN without `--restore` needs no `gdc host reset` |
| `join_reentry_manual_recovery_required` | an earlier JOIN stopped part-way, for example on `lineage_snapshot_unavailable` from the state-sync canary; repeating it changes nothing | `gdc host reset <ssh-alias>`, which keeps the run evidence; then the same command when reset reports the participant unregistered, or `--restore` when it reports a registered participant whose signer had started |

A participant registered before its signer ever started has no supported way
back.

Recreate a missing archive with `gdc host backup <ssh-alias>` before any
`gdc host reset`.

`gdc host reset` stops the signer at once. If the Host holds a third or more
of the voting power the chain halts, so check the validator set first.

For a validated private archive, use the same supported interface:

```bash
gdc host join --restore <validator-backup.tar> --public-host <IP_or_DOMAIN> <ssh-alias>
```

The archive is an assertion, not permission to replace identity or software
selection. `--restore` works only on the machine where `gdc host reset` stopped
this validator's signer; another or reinstalled machine is refused. Do not
bypass qualification or use this interface to reset, recreate Genesis, or
adopt an unknown existing validator.

If the GPU runs on another machine, pass its SSH alias after `<ssh-alias>` in
`gdc host join`; `gdc host ml-attach` in [ROLE-HOST.md](ROLE-HOST.md) reapplies
an attachment that is already configured.
