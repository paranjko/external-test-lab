# Community DevNet node deployment runbook

**Version:** `1.0.0-alpah.0`  
**Status:** initial public release

This package creates a reproducible Gonka Community DevNet for release and distributed-behaviour testing. A clean rehearsal always starts on `testnet-0.2.14` with chain ID `gonka-devnet-community`. The `0.2.15` workflow is a state-preserving upgrade test, not a replacement baseline.

It contains orchestration and configuration only. It contains neither Gonka source code nor chain state, private keys, mnemonics, API keys, host inventory, or operator configuration.

## What it does

- prepares Network Node and MLNode hosts;
- creates a fresh genesis and joins participants one by one;
- qualifies the configured model before genesis and join;
- deploys the DevShard gateway, monitoring, public status site and edge;
- verifies chain progress, participant state, inference and monitoring;
- rehearses a governed `0.2.14` to `0.2.15` upgrade;
- provides DevShard v3/v4, v4 HA and Sepolia bridge overlays;
- stops, starts and verifies one node; and
- resets the test network while preserving the public observability runtimes.

## Safety boundary

Run this only against an isolated DevNet with dedicated accounts and hosts. Never use mainnet keys, funds, endpoints or chain state. Do not commit `.env`, `state/`, `generated/`, `artifacts/`, mnemonic backups, tokens or SSH configuration. Store the mnemonic backups produced by `identities` offline.

The operator workstation needs Bash, Docker, SSH, `jq`, `rsync`, `scp` and SSH aliases for the selected hosts. Copy the example configuration and set only the operator values it asks for:

```bash
cp .env.example .env
```

### Host storage prerequisite

Every machine is supplied by its operator with `/srv` and writable
`/srv/dai` already in place. Before running the runbook, the filesystem that
backs `/srv/dai` must have at least **50 GiB free** for a Network Node and at
least **40 GiB free** for a standalone MLNode. Docker and containerd storage
must have the same usable headroom; they may be on that filesystem or another
operator-managed filesystem. `prepare` verifies these conditions but never
migrates data, modifies `/etc/fstab`, remounts a disk, or creates symlinks.

For node2 this prerequisite is already met: `/srv/dai`, Docker and containerd
are backed by its 440 GiB data disk with 365 GiB currently free.

`GDC_SKIP_HOSTS=gdc-node3` is the supported way to intentionally exclude a participant. An excluded host is recorded as `SKIP`, never silently counted as an active participant, and can be qualified and joined later.

## Baseline: 0.2.14

Run each phase only after the preceding one returns `PASS`. The CLI holds an
exclusive local lifecycle lock, so a second phase cannot race an active one:

```bash
./gdc.sh --release testnet-0.2.14 --model qwen3-0.6b prepare
./gdc.sh --release testnet-0.2.14 identities
./gdc.sh --release testnet-0.2.14 qualify-ml
./gdc.sh --release testnet-0.2.14 genesis
./gdc.sh --release testnet-0.2.14 bootstrap-access
./gdc.sh --release testnet-0.2.14 join node1
./gdc.sh --release testnet-0.2.14 join node2
./gdc.sh --release testnet-0.2.14 join node4
./gdc.sh --release testnet-0.2.14 verify
```

The baseline uses the primary fast rehearsal profile: 50-block epochs, short
governance windows and one PoC validation slot. Its purpose is to make
lifecycle testing practical; it is not a claim about production timing. The
validation slot must remain non-zero: zero disables PoC validation and makes a
chain-accounted gateway impossible to verify.

### One-participant access bootstrap

Immediately after Genesis, the optional `bootstrap-access` phase makes the
single active participant usable through the same authenticated,
chain-accounted access contract as the later distributed network:

```bash
./gdc.sh --release testnet-0.2.14 bootstrap-access
```

The command uses the live node0 RPC while node4 has not joined yet, submits or
reuses the DevShard v3/v4 governance proposal, records the sole validator's
vote, waits for the proposal to pass, creates an escrow, starts the gateway,
generates and verifies a finite key pool, and deploys the Telegram bot on
node0. The authenticated bootstrap endpoint is
`https://node0.gonka-dev.net/gateway/v1`; neither node4 nor its public edge is
required. The ten-block PoC validation delay is an intentional primary test
parameter: official DAPI 0.2.14 can submit its first MLNode distribution in
the same block as a newer store commit. The extra test-lab window lets its
30-second retry observe the final committed count and record a matching
distribution before the validation snapshot. The phase waits for a positive
chain-computed validation weight before creating the escrow. It is idempotent
and does not treat a direct MLNode response as gateway proof. This bootstrap is
intentionally a one-validator availability mode;
distributed-governance evidence begins only after the other participants join.
By default the escrow uses the live governance minimum instead of the original
Genesis allocation, because governance deposits have already reduced the
gateway account's spendable balance. An explicit
`GDC_GATEWAY_ESCROW_AMOUNT_NGONKA` must fit the current spendable balance.

## Independent operator node join

An additional GPU Network Node may be operated by a different person or
organization. They must never receive `state/secrets/operator.keyring`, the
controller's mnemonic backups, gateway credentials, or any unrelated node
secret. The controller creates a target-specific encrypted handoff after
Genesis; the independent operator qualifies, deploys and registers that node;
the controller then confirms the on-chain registration and grants the minimum
funding and ML operational permission.

Controller workstation:

```bash
./gdc.sh handoff create node2
```

Transfer the emitted `artifacts/operator-handoffs/gdc-node2/` directory through
an encrypted out-of-band channel. The recipient clones the same runbook
release, adds its own `ACME_EMAIL` to the received `operator.env`, and provides
only the SSH alias for its host. It first produces local model evidence, then
deploys and registers its node:

```bash
GDC_ENV=/secure/gdc-node2/operator.env \
GDC_QUALIFY_HOSTS=gdc-node2 \
  ./gdc.sh qualify-ml

GDC_ENV=/secure/gdc-node2/operator.env \
GDC_NODE_HANDOFF_DIR=/secure/gdc-node2 \
  ./gdc.sh join node2
```

The second command ends in the registered-but-not-active state and writes an
`artifacts/operator-requests/gdc-node2-activation-request.json` file. Transfer
that public activation request to the controller, which performs the only
privileged action:

```bash
./gdc.sh handoff approve node2 /received/gdc-node2-activation-request.json
```

`handoff approve` verifies the expected chain ID, controller-created cold
address and on-chain registration before it funds the account or grants ML
permission. It records `state/joined/gdc-node2` only after the chain reports
`ACTIVE`. This is the required rehearsal for adding a node after bootstrap:
start a fresh baseline with `GDC_SKIP_HOSTS="gdc-node2 gdc-node3"`, then use
the handoff flow for node2.

## Gateway and observability overlays

DevShard versions and the dedicated gateway creator are approved through chain governance before a gateway is started:

```bash
./gdc.sh governance devshard
./gdc.sh vote <proposal-id> yes
./gdc.sh ops gateway
./gdc.sh ops monitoring
./gdc.sh ops site
./gdc.sh ops edge
./gdc.sh ops meter
./gdc.sh ops explorer
./gdc.sh verify
```

`ops gateway` must report an active unblocked DevShard before the public OpenAI-compatible access surface is considered ready. A successful direct MLNode response alone is not proof of chain-accounted gateway inference.

## Telegram key issuer

The bot implementation is part of this release at
[`scripts/telegram-bot/`](scripts/telegram-bot/). The BotFather token belongs
in the ignored root `.env`; the finite `gateway-key-pool.json` remains a
root-owned runtime file on the gateway host. Neither secret is committed.

After those two files have been provisioned and the gateway is active, deploy
or move the bot to the secondary-services host after node4 is available:

```bash
./gdc.sh telegram-bot
```

The deployment keeps the durable issuance database on that host, stops any
gateway-host poller, and verifies both the Telegram identity and an
authenticated key before reporting success.

## Single-node operations

Use these commands for a controlled node recovery rehearsal. `verify` waits for synchronization and checks common-height consistency; a running container is not sufficient evidence of recovery.

```bash
./gdc.sh node stop node1
./gdc.sh node start node1
./gdc.sh node verify node1
```

## Governed upgrade: 0.2.14 to 0.2.15

Choose a future activation height and use the current chain minimum deposit. Proposal creation is review-only until `GDC_UPGRADE_SUBMIT=true` is explicitly set.

```bash
GDC_UPGRADE_HEIGHT=<future-height> \
GDC_UPGRADE_DEPOSIT=<live-minimum>ngonka \
GDC_UPGRADE_SUBMIT=true \
  ./gdc.sh --release testnet-0.2.15 upgrade-proposal

./gdc.sh vote <proposal-id> yes
./gdc.sh --release testnet-0.2.15 upgrade-worker <proposal-id>
./gdc.sh --release testnet-0.2.15 verify
```

The worker waits for the passed proposal and activation height, verifies disk headroom and pre-pulls pinned images before changing node containers. It uses a 30-block minimum lead by default. Do not use the foreground `upgrade` command before the activation height.

## Optional overlays after upgrade evidence

```bash
./gdc.sh ha v4
GDC_SEPOLIA_CONTRACT=<authorized-contract-address> \
GDC_SEPOLIA_BEACON_STATE_URL=<beacon-state-endpoint> \
  ./gdc.sh bridge sepolia
```

The HA phase checks traffic through loss and recovery of one v4 `versiond` replica. The bridge phase is intentionally blocked until both values are supplied; it does not guess Ethereum configuration.

## Reset and prove public truth

```bash
./gdc.sh reset --yes
```

Reset removes only resettable DevNet containers, volumes, networks, deployment state and rehearsal artifacts. It preserves Docker images, model cache, Telegram issuer, public edge and public Grafana. The reset contract includes browser evidence that the status site shows every stopped node as offline and reports gateway traffic as `OFFLINE` with `Network reset – no nodes online`. It must never report `PENDING` when the network itself is down.

After reset, repeat the baseline from `prepare`. Public observability must show the actual reset state, not stale metrics.

## Validation before contribution

```bash
make shellcheck
./scripts/test-profiles.sh
```

Runtime evidence is written under `artifacts/runs/<UTC timestamp>/` and remains local unless it has been reviewed and sanitized for publication.
