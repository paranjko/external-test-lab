# Community DevNet node join runbook

This document reflects the current runbook behavior in
`net-deployment-runbook/`.

## 0. Prerequisites

The machine executing `join` must have:

- SSH access to the target host alias (`gdc-node1`, `gdc-node2`, `gdc-node3`, or `gdc-node4`)
- `bash`, `ssh`, `scp`, `rsync`, `jq`, and `sudo` available
- the same cloned repository checkout as the controller (same release)
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

## 1. Baseline prerequisite for genesis

`./gdc.sh --release testnet-0.2.14 identities` prepares only the baseline
primitives needed to start the network:

- secrets and operator keyring;
- cold account for `gdc-node0`;
- cold account for `gdc-gateway`;
- warm identity for `gdc-node0`.

It does **not** create participant wallets for `gdc-node1..gdc-node4`.
Those are created later during each `join`.

## 2. Run a node join locally on the controller host

From an operator host that already ran genesis:

```bash
./gdc.sh --release testnet-0.2.14 join node2
```

The `join` phase now:

- creates a missing cold account for the requested node on demand;
- renders node/edge/agent artifacts from current inventory;
- installs and starts the node services;
- waits for chain synchronization;
- registers the participant;
- funds and grants ML permission;
- waits for ACTIVE status.

For `node4`, the script also installs and starts the dedicated Blackwell ML host.

## 3. Independent operator node

An external operator must not receive controller secrets. Use handoff flow:

- Controller:
  ```bash
  ./gdc.sh handoff create node2
  ```
- Transfer `artifacts/operator-handoffs/gdc-node2/` securely.
- Operator:
  ```bash
  GDC_ENV=/secure/gdc-node2/operator.env \
  GDC_NODE_HANDOFF_DIR=/secure/gdc-node2 \
    ./gdc.sh --release testnet-0.2.14 join node2
  ```

This produces:

- `artifacts/operator-requests/gdc-node2-activation-request.json` (registration request).

Controller:

```bash
./gdc.sh handoff approve node2 /received/gdc-node2-activation-request.json
```

## 4. Onboarding predefined nodes

Supported aliases are `node1`, `node2`, `node3`, and `node4` (or the same with
`gdc-` prefix). If an alias is prepared for another host name, set it in SSH with
an equivalent `gdc-nodeN` label used by `.env` and runbook phases.

## 5. Validation and troubleshooting

After each join, verify:

- `./gdc.sh --release testnet-0.2.14 verify`
- `node0` logs for registration / funding / ML permission messages
- `/srv/dai/shared/genesis.json` exists on the new host

If join fails, keep the full command output in your logs and report the failing
phase and host.
