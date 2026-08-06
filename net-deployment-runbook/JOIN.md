# Community DevNet node join runbook

This document reflects the current runbook behavior in
`net-deployment-runbook/`.

## 0. Prerequisites

The machine executing `join` must have:

- SSH access to the target host alias (`gdc-node1`, `gdc-node2`, `gdc-node3`, or `gdc-node4`)
- `bash`, `ssh`, `scp`, `rsync`, `jq`, and `sudo` available
- the same cloned repository checkout as the runbook release in use (same release)
- `.env` prepared from `.env.example`

Add the SSH alias(es):

```bash
cat >> ~/.ssh/config <<'EOL'
Host gdc-node2
  HostName <IP>
  User root
  Port <PORT> # optional
EOL
```

## 1. Join model for independent validators

Every node connection is treated as onboarding an **independent validator**.

- Genesis may be started by one operator (`node0` in most runs).
- Any additional node may be added by the same operator or a delegated operator.
- Each node has its own `account + identity + validator registration` lifecycle and can be
  managed independently (including `stop`, `start`, `verify`, `reset`, and re-join).

From a host that has access to the target node and shared chain state:

```bash
./gdc.sh --release testnet-0.2.14 join gdc-node2
```

The `join` phase now:

- creates a missing cold account for the requested node on demand;
- ensures ML capability evidence for this node is available. If qualification evidence is missing or stale, it is produced automatically, then reused;
- renders node/edge/agent artifacts from current inventory;
- installs and starts the node services;
- waits for chain synchronization;
- registers the participant only when its cold address is absent from chain
  state;
- funds and grants ML permission only when that participant is not already
  ACTIVE;
- waits for ACTIVE status.

This distinction makes `node reset` followed by `join` a runtime recovery, not
a second economic onboarding. An already ACTIVE participant retains its chain
account and permissions; the command restores its deployment, synchronizes it,
and recreates the local joined marker without duplicate funding transactions.

To disable auto-qualification in exceptional cases (for example, when you want
to run manual pre-staging), set `GDC_AUTO_QUALIFY_ML=false`.

For `node4`, the script also installs and starts the dedicated Blackwell ML host.

## 2. Operator handoff flow

An external operator owns both the cold and warm validator keys. The
coordinator transfers only public Genesis, seed, and topology data.

- Coordinator:
  ```bash
  ./gdc.sh handoff create gdc-node2
  ```
- Transfer `artifacts/operator-handoffs/gdc-node2/` securely.
- Operator:
  ```bash
  GDC_ENV=/secure/gdc-node2/operator.env \
  GDC_NODE_HANDOFF_DIR=/secure/gdc-node2 \
    ./gdc.sh --release testnet-0.2.14 join gdc-node2
```

The first operator-side `join` creates the cold and warm identities locally,
installs the node, registers it, and produces:

- `artifacts/operator-requests/gdc-node2-activation-request.json` (registration request).

Coordinator:

```bash
./gdc.sh handoff approve gdc-node2 /received/gdc-node2-activation-request.json
```

Approval verifies the registered address and consensus key, then funds the
registered account. It cannot sign with the operator's cold key. The operator
finishes activation by rerunning the same command:

```bash
GDC_ENV=/secure/gdc-node2/operator.env \
GDC_NODE_HANDOFF_DIR=/secure/gdc-node2 \
  ./gdc.sh --release testnet-0.2.14 join gdc-node2
```

The second run detects committed funding, grants ML permissions with the
operator-owned cold key, waits for ACTIVE, and writes the local joined marker.

## 3. Onboarding predefined nodes

Primary commands use SSH aliases `gdc-node1`, `gdc-node2`, `gdc-node3`, and
`gdc-node4`. Short forms such as `node2` are rejected because they hide the
actual SSH target expected by the runbook. If an alias is prepared for another
host name, expose it in SSH with the corresponding `gdc-nodeN` label used by
`.env` and runbook phases.

## 4. Single-node operations

To rehearse a controlled failure and recovery without stopping the entire network:

```bash
./gdc.sh node stop gdc-node1
./gdc.sh node reset gdc-node1
./gdc.sh --release testnet-0.2.14 join gdc-node1
```

`./gdc.sh node reset gdc-node1` removes deployed state from `gdc-node1` on the
target host and removes the local `state/joined/gdc-node1` marker. That makes
the node eligible for a clean rejoin after the chain is available.

You may use the full single-node cycle:

```bash
./gdc.sh node stop gdc-node1
./gdc.sh node start gdc-node1
./gdc.sh node verify gdc-node1
```

## 5. Validation and troubleshooting

After each join, verify:

- `./gdc.sh --release testnet-0.2.14 verify`
- host logs for registration / funding / ML permission messages
- `/srv/dai/shared/genesis.json` exists on the new host

If join fails, keep the full command output in your logs and report the failing
phase and host.
