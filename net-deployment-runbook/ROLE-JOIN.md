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
and its preflight needs only a quorum of seeds. Registration tries the
published guardian endpoints in turn. DevNet faucet funding and the `ACTIVE`
wait still use node0.

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

Every fresh JOIN requires `$GDC_HOME/<ssh-alias>` to be absent, including
`--plan`, `--restore` and mnemonic recovery. If that path exists, GDC stops
before reading a mnemonic, taking a lifecycle lock or contacting the Host.
Save required keys, backups and run evidence outside it, then remove the
local state path before starting a new JOIN. GDC never removes it for you.
Only an explicit `--resume <RUN_ID>` uses retained state.

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

The verified archive contains the participant cold mnemonic. If its TMKMS key
is no longer published, JOIN rebinds that participant to the restored key,
then reads it back before enabling the signer.

Without a second SSH alias, JOIN prepares `<ssh-alias>` as a `network-gpu`
Host. GDC detects the PCI accelerator before mutation and selects a committed
profile. NVIDIA requires an R580+ driver. AMD support is limited to `gfx1201`
with PCI device `0x7550`; it checks ROCm, `/dev/kfd` and the render node.
Unknown or mismatched hardware is refused before package, Docker, identity or
deployment changes. A separate ML Host remains `ml-only` while the network
Host is `network-only`.

Use `--chain-id <id>` to select another network's bootstrap document; the
default is `gonka-devnet-community`. The value is accepted only as a safe URL
path segment, and the document must declare the same chain ID.

Before Host mutation, JOIN requires two consecutive quorum-backed runtime
observations and confirms them again immediately before preparation. The
default deadline is 30 minutes; use `--preflight-deadline 60m` deliberately.
`--release` and `--composition` are intentionally not accepted by JOIN. A
runtime change restarts preflight without touching the Host.

If driver installation needs a reboot, JOIN stops with exit 194. Reboot the Host
listed under `REBOOT`, preserve required local evidence and keys, then remove
the alias's local state path before a new JOIN; a JOIN without `--restore`
needs no remote `host reset`.

Before network observation, JOIN reads reboot, package-manager and Docker
storage prerequisites over SSH. This changes nothing on the Host.

If preparation reports `ACTION`, GDC found a Host prerequisite it will not
repair implicitly. Follow `/var/log/gdc-prepare.log`, preserve local evidence,
and remove the alias's local state path before a new JOIN; no identity or signer
was created.

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
Without the operator-only gateway client key, acceptance cannot return
`JOIN_PASS`. With
`--verification`, unless acceptance returns `JOIN_PASS`, `COMPLETE` is not
recorded, and `gdc host start` is then refused; an independent operator
therefore omits `--verification`. Fresh JOIN always refuses retained local
state. Use explicit `--resume` to continue a recorded run.

Voting power follows the first accepted PoC, normally one or two epochs after
`ACTIVE`. JOIN watches for the first signer record for up to 300 seconds. A
participant outside the validator set is recorded as armed with eligibility
pending. `--verification` later proves PoC, membership and gateway acceptance.
If acceptance stops after signer and archive verification,
`gdc host join --verification --resume <run_id> --public-host <IP_or_DOMAIN> <ssh-alias>`
continues acceptance only. A completed eligibility window is retained; a
gateway-only retry does not extend it. An uncertain inference result remains
`INCONCLUSIVE` rather than being replayed.

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

Fresh JOIN exits 2 whenever `$GDC_HOME/<ssh-alias>` exists, even after a
completed run or a refusal before Host mutation. It prints the exact path and
does not read or replace the retained Host state. An empty directory, file or
symlink also blocks a fresh JOIN.

Use `--resume <RUN_ID>` to continue a supported retained run. Resume validates
the original profile and receipt chain; it does not bypass their checks.
A supported resume must not create a second participant or funding claim. For
a new attempt, preserve required recovery material and run evidence outside
the alias path, then remove that local state. Removing local state does not
reset the remote Host or remove an on-chain participant; use the appropriate
Host reset and restore workflow when required.

The `partial_identity`, `identity_conflict` and `unreachable` stops occur
before the first Host change and retain `mutation: none`. Their diagnostics
remain available through `gdc report github`; a fresh attempt still requires
removing the alias's local state after preserving required material.

Every fresh JOIN suggested below requires preserving recovery material and
removing the local alias path first, including state retained by Host reset.

| Stop | Meaning | Way back |
|---|---|---|
| `partial_identity` | the operator state holds some of the identity record, the cold account and the joined marker, but not all three | restore with `--restore` from the validator archive; `gdc host reset` clears the identity only when the chain reports the participant as unregistered, and the next JOIN then starts as `new` |
| `identity_conflict` | the Host holds an unknown validator identity | restore with `--restore`; `--mnemonic-file` may replace only a stopped key bound to that participant or unregistered on chain |
| existing local state, exit 2 | the alias path already exists, regardless of its contents or JOIN options | use explicit `--resume` for a supported retained run; otherwise preserve required keys and evidence, then remove the printed local state path before a new JOIN |
| `unreachable` | no SSH session to the Host | restore connectivity, preserve local evidence, then remove local state before a new JOIN |
| exit 65, `restore_identity_mismatch` | `--restore` names a validator backup for a different signer than the one captured by `gdc host reset` | use the matching validator backup; otherwise use an authorized validator-key rotation |
| exit 194 | host preparation installed the NVIDIA driver and a Host needs a reboot | reboot the Host listed under `REBOOT`, preserve local evidence, and remove local state before a new JOIN; a JOIN without `--restore` needs no remote `gdc host reset` |
| exit 195 | Host preparation needs operator action before GDC can safely continue | resolve the stated prerequisite in `/var/log/gdc-prepare.log`, preserve local evidence, and remove local state before a new JOIN; no remote `gdc host reset` is needed |
| `join_reentry_manual_recovery_required` | an earlier JOIN stopped part-way, for example on `lineage_snapshot_unavailable` from the state-sync canary; repeating it changes nothing | `gdc host reset <ssh-alias>`, which keeps the run evidence; then the same command when reset reports the participant unregistered, or `--restore` when it reports a registered participant whose signer had started |
| registered with another validator key | the chain publishes a validator key for this participant that is not the key this Host signs with, so the Host cannot sign for its own registration; the Host was not changed | repeat with `--mnemonic-prompt` or `--mnemonic-file` and that participant's cold mnemonic; or continue on the Host whose signer owns the registered key |

A participant registered before its signer ever started has no supported way
back.

Recreate a missing archive with `gdc host backup <ssh-alias>` before any
`gdc host reset`.

### Recover the staking key without reset

After a completed JOIN, restore a mismatched signer from backup, keeping chain data, images, warm account and P2P identity:

```bash
gdc host join --resume <completed-run-id> --restore <validator-backup.tar> \
  --recover-consensus-signer --exclusive-signer \
  --public-host <IP_or_DOMAIN> <ssh-alias>
```

Stop every other copy of the key before using `--exclusive-signer`. The local cold keyring must own the participant; jailed or tombstoned keys are refused.

`VALIDATING` proves positive voting power and new signatures across an epoch change, not just `ACTIVE` status.

After signer activation, resume interrupted verification with `--resume <new-run-id>`, without recovery flags or reset. Keep the new backup and run evidence.

`gdc host reset` stops the signer at once. If the Host holds a third or more
of the voting power the chain halts, so check the validator set first.

For a validated private archive, use the same supported interface:

```bash
gdc host join --restore <validator-backup.tar> --public-host <IP_or_DOMAIN> <ssh-alias>
```

The archive is an assertion, not permission to replace identity or software
selection. `--restore` accepts a same-Host reset archive, or an archive whose
key is unregistered before restore and signer enablement. It also refuses a
lower signing state. Stop every other copy of the archive key. Do not use it to
recreate Genesis or adopt an unknown validator.

If the GPU runs on another machine, pass its SSH alias after `<ssh-alias>` in
`gdc host join`; `gdc host ml-attach` in [ROLE-HOST.md](ROLE-HOST.md) reapplies
an attachment that is already configured.
