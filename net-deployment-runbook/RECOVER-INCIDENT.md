# Recover GNK-LAB-2026-0001

This one-incident Bash workflow uses the deployed v0.2.15 binary, preserves
Genesis and confirmed history, and excludes both lost participant identities.
It does not add a Python runtime dependency.

Use the same controller, SSH aliases, existing `GDC_HOME`, validator identity
archives, and recovery receipts throughout. The controller needs its
runbook-managed `~/.local/bin/inferenced`; SSH must support non-interactive sudo.
Archives are named after the discovered deployment, not necessarily its SSH
alias: `$GDC_HOME/<deployment-name>-validator-backup.tar`.

## Starting versus continuing

For a new recovery from the recorded incident halt, run steps 1–5. Each Host
needs enough space for its retained backup and working data. For an existing
bootstrap with the returning Hosts already restored, **start at step 3**.
Do not repeat reset/join or replace `GDC_HOME` with an empty directory.
Stop on any command failure; do not continue to the next numbered step.

The aliases and domains below are examples supplied by the operator, not
required names.

```bash
alias gdc="$PWD/external-test-lab/net-deployment-runbook/gdc.sh"
export GDC_HOME="${GDC_HOME:?Set GDC_HOME to the existing controller data directory}"
RETURNING=gdc-node1,gdc-node2,gdc-node4

# 1. Bootstrap the source with a temporary signer. Confirm RECOVER.
gdc network recover bootstrap gdc-node0
curl -fsS https://node0.gonka-dev.net/chain-rpc/status | jq '.result.sync_info | {latest_block_height, catching_up}'
# Height must exceed 306552 and keep increasing; catching_up must be false.

# 2. Restore each returning Host once. JOIN discovers an archival source and
# an independent current witness from the published Bootstrap descriptor.
gdc host reset gdc-node1
gdc host join --pex false --restore "$GDC_HOME/gdc-node1-validator-backup.tar" --public-host node1.gonka-dev.net gdc-node1
gdc host reset gdc-node2
gdc host join --pex false --restore "$GDC_HOME/gdc-node2-validator-backup.tar" --public-host node2.gonka-dev.net gdc-node2
gdc host reset gdc-node4
gdc host join --pex false --restore "$GDC_HOME/gdc-node4-validator-backup.tar" --public-host node4.gonka-dev.net gdc-node4

# 3. Explicitly hand consensus back to the original signers.
gdc network recover handoff gdc-node0 --hosts "$RETURNING"

# 4. Enable peer discovery, retaining existing peers and chain data.
gdc host peers --pex true gdc-node0
gdc host peers --pex true gdc-node1
gdc host peers --pex true gdc-node2
gdc host peers --pex true gdc-node4

# 5. Verify the final state.
gdc network recover check gdc-node0 --hosts "$RETURNING"
```

## What the commands do

`bootstrap` processes only its selected Host. It runs `in-place-testnet` once
on a copy of the stopped data, applies native governance to exclude the lost
identities, and prepares a native state-sync snapshot. Backups and chain data
remain on the Hosts; no database archive is downloaded to the controller.

`host reset` and `host join --restore` remain ordinary Host lifecycle commands.
The restore archive contains the existing validator identity, not a chain
database. JOIN reads the published Bootstrap descriptor, selects a seed that
still serves the historical checkpoints, and pairs it with a distinct current
witness. `--pex false` only disables peer discovery. State sync uses native
P2P, then verifies common-height state before activating the original signer.

`handoff` is a separate operation; ordinary join does not trigger it. It
checks the returning Hosts against their retained identity archives and waits
up to 40 minutes for all expected original keys to enter the active validator
set. A synchronized Host with zero voting power is not sufficient: its PoC
participation must become effective. Missing membership stops the operation;
resetting a synchronized Host is not the remedy.

The native handoff temporarily changes guardian and slashing parameters,
verifies returning quorum, switches node0 to its original signer, and uses
native downtime handling and governance to remove the temporary staking
record. It then restores the saved parameters and checks their committed
readback. Retain all receipts if it stops partway through.

`host peers --pex true` changes only the selected Host and restarts only its
chain container. It preserves existing peers, seeds, data, and signer state;
there is no fixed topology list or second reset/state-sync cycle.

`check` requires the exact original validator keys, absence of the temporary
key, advancing blocks, two healthy native epochs, matching common-height state,
peer connections, and both lost identities in the blocklist. Only its
`RECOVERED` result confirms this recovery scope, not end-to-end inference
service acceptance.

## Retained state and verification

Keep `$GDC_HOME/recovery-GNK-LAB-2026-0001`, the original identity archives, and
the Host backups under
`/srv/dai/recovery/GNK-LAB-2026-0001/<deployment-name>`. No manual recovery run
ID, manifest, additional SSH key, or SSH-agent forwarding is required.

Local contract tests: `make test-recover-incident`. SSH and governance in those
tests are mocked; they do not prove native handoff acceptance.
`GONKA_UPSTREAM_WORKTREE=/path/to/gonka make test-recover-incident-runtime`
uses disposable identities and an internal Docker network to verify real
history preservation, restart, snapshot creation, and signerless P2P state
sync. It does not exercise incident Hosts, their PoC, or the native
temporary-key removal. Successful full handoff and final checks must be
established separately before claiming end-to-end recovery readiness.
