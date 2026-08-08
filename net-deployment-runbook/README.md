# Community DevNet node deployment runbook

**Version:** `1.0.0-alpha.0`  
**Status:** initial public release

This package creates a reproducible Gonka Community DevNet for release and distributed-behaviour testing. A clean rehearsal always starts on `testnet-0.2.14` with chain ID `gonka-devnet-community`. The `0.2.15` workflow is a state-preserving upgrade test, not a replacement baseline.

It contains orchestration and configuration only. It contains neither Gonka source code nor chain state, private keys, mnemonics, API keys, host inventory, or operator configuration.

## Profile boundaries

The selected software is split by ownership:

- `profiles/releases/` contains only the Gonka network components verified
  against the corresponding upstream release tag;
- `profiles/deployments/` contains lab-owned chain timing, storage, hardware
  compatibility and separately governed DevShard inputs;
- `profiles/models/` contains model and PoC parameters; and
- `profiles/operator-services/` contains Caddy, monitoring and exporters
  used by operators but not part of the network release under test.

The network profile hash covers release + deployment + model. Operator support
has a separate hash. See [profiles/README.md](profiles/README.md) and run:

```bash
make verify-upstream-profiles
./scripts/verify-release-profiles.sh --registry
```

The first command compares local profiles with the tags in `code/gonka`.
The optional registry gate also proves that every immutable digest still
matches the image tag declared by upstream.

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

Run this only against an isolated DevNet with dedicated accounts and hosts. Never use mainnet keys, funds, endpoints or chain state. Do not commit `.env`, `state/`, `generated/`, `artifacts/`, mnemonic backups, tokens or SSH configuration. Store the Genesis operator mnemonic backup produced by `genesis` offline. Every later validator operator owns and stores that validator's backups.

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

`GDC_SKIP_HOSTS` is the supported way to intentionally exclude a participant. An excluded host is recorded as `SKIP`, never silently counted as an active participant, and can be qualified and joined later.

## Baseline: 0.2.14

Run each phase only after the preceding one returns `PASS`. The CLI holds an
exclusive local lifecycle lock, so a second phase cannot race an active one:

```bash
./gdc.sh --release testnet-0.2.14 --model qwen3-0.6b prepare
./gdc.sh --release testnet-0.2.14 qualify-ml validator-a
./gdc.sh --release testnet-0.2.14 genesis
./gdc.sh --release testnet-0.2.14 bootstrap-access
./gdc.sh --release testnet-0.2.14 join validator-b
./gdc.sh --release testnet-0.2.14 join validator-c
./gdc.sh --release testnet-0.2.14 join validator-d
./gdc.sh --release testnet-0.2.14 verify
./gdc.sh --release testnet-0.2.14 gateway-continuity
```

The baseline uses the primary fast rehearsal profile: 50-block epochs, short
governance windows and one PoC validation slot. Its purpose is to make
lifecycle testing practical; it is not a claim about production timing. The
validation slot must remain non-zero: zero disables PoC validation and makes a
chain-accounted gateway impossible to verify.

`genesis` creates only the Genesis operator's secrets and identities plus
the dedicated gateway account. It does not create passwords, cold accounts,
warm keys, or consensus identities for later validators. Each validator
operator creates that material during its own `join` flow.

`qualify-ml` without a target checks the configured Genesis node. A named diagnostic run accepts
one configured SSH alias, for example `qualify-ml validator-b`; it never scans the other
operators' hosts. `join <ssh-alias>` runs the same qualification automatically
for its own inference host when matching evidence does not already exist.

Every `join` treats the target node as an independent validator. Genesis can be
started by one operator, while other nodes can be added by the same operator or
delegated operators via handoff.

### One-participant access bootstrap

Immediately after Genesis, the optional `bootstrap-access` phase makes the
single active participant usable through the same authenticated,
chain-accounted access contract as the later distributed network:

```bash
./gdc.sh --release testnet-0.2.14 bootstrap-access
```

The command uses the configured gateway participant RPC while the other
participants have not joined yet, submits or
reuses the DevShard v3/v4 governance proposal, records the sole validator's
vote, waits for the proposal to pass, creates an escrow, starts the gateway,
generates and verifies a finite key pool, and deploys the Telegram bot on the
configured gateway host. The authenticated bootstrap endpoint is
`https://<gateway-public-host>/gateway/v1`; neither a secondary-services host
nor its public edge is required. The eight-block PoC exchange window and ten-block validation delay
are intentional primary test parameters. Official DAPI 0.2.14 can submit its
first MLNode distribution in the same block as a newer store commit. The
exchange window remains open for its 30-second retry to observe the final
committed count and record a matching distribution before the validation
snapshot. The phase waits for a positive chain-computed validation weight
before creating the escrow. It is idempotent
and does not treat a direct MLNode response as gateway proof. This bootstrap is
intentionally a one-validator availability mode;
distributed-governance evidence begins only after the other participants join.
By default the escrow uses the live governance minimum instead of the original
Genesis allocation, because governance deposits have already reduced the
gateway account's spendable balance. An explicit
`GDC_GATEWAY_ESCROW_AMOUNT_NGONKA` must fit the current spendable balance.
Before gateway creation, the runbook restores
`GDC_GATEWAY_MIN_SPENDABLE_NGONKA` as a reserve target for automatic escrow
rotation. This is test-chain funding, not a client request quota.

`gateway-continuity` sends authenticated requests before, during and after the
next live PoC window. A PASS requires a non-empty preserved runtime set and no
failed request in any of the three windows. The evidence is tied to the current
chain ID, Genesis hash, release and model profile, so a PASS from a chain that
was later reset cannot authorize an upgrade. The Community assurance profile
disables the Genesis guardian because Gonka excludes guardian capacity from the
preserved non-voting runtime set. This is Genesis-only: set
`GDC_GENESIS_GUARDIAN_ENABLED=true` only for a one-validator bootstrap
experiment that intentionally cannot pass the PoC-continuity gate. A normal
continuity rehearsal still requires joined, eligible model capacity.

With the default non-guardian Community profile, do not call
`bootstrap-access` immediately after one-node Genesis. First qualify and join
one model participant, then run `bootstrap-access`; this lets the chain compute
the first validation weight without relying on guardian-only capacity.

## Operator handoff onboarding

An additional GPU Network Node may be operated by a different person or
organization. They must never receive `state/secrets/operator.keyring`, coordinator
mnemonic backups, gateway credentials, or any unrelated node secret. The
coordinator creates a target-specific public handoff after Genesis. The
operator creates both validator identities, qualifies, deploys, and registers
the node. The coordinator confirms the on-chain identity and supplies only the
minimum test-chain funding.

Coordinator workstation:

```bash
./gdc.sh handoff create validator-b
```

Transfer the emitted `artifacts/operator-handoffs/validator-b/` directory. Its
manifest protects integrity; it contains no secrets. The recipient clones the
same runbook release, adds its own `ACME_EMAIL` to `operator.env`, and provides
the `validator-b` SSH alias. `join` produces missing model qualification evidence
automatically, then deploys and registers the node:

```bash
GDC_ENV=/secure/validator-b/operator.env \
GDC_NODE_HANDOFF_DIR=/secure/validator-b \
  ./gdc.sh --release testnet-0.2.14 join validator-b
```

The first command ends in the registered-but-not-active state and writes an
`artifacts/operator-requests/validator-b-activation-request.json` file. Transfer
that public activation request to the coordinator, which verifies the
committed address and consensus key and funds the account:

```bash
./gdc.sh --release testnet-0.2.14 handoff approve validator-b /received/validator-b-activation-request.json
```

The operator then repeats the same command:

```bash
GDC_ENV=/secure/validator-b/operator.env \
GDC_NODE_HANDOFF_DIR=/secure/validator-b \
  ./gdc.sh --release testnet-0.2.14 join validator-b
```

`handoff create` contains no validator or account secrets. The operator creates
the cold and warm keys and registers the participant on the first `join` run.
`handoff approve` verifies that the registered address and consensus key match
the request, then funds that address; it cannot sign ML permissions. The
operator reruns the same `join` command, signs with the operator-owned cold
key, waits for ACTIVE, and records the local joined marker. This is the
required rehearsal for adding a node after bootstrap: start a fresh baseline
with `GDC_SKIP_HOSTS="validator-b validator-c"`, then use the handoff flow for
`validator-b`.

## Gateway and observability overlays

DevShard versions and the dedicated gateway creator are approved through chain governance before a gateway is started:

```bash
./gdc.sh --release testnet-0.2.15 governance devshard
./gdc.sh --release testnet-0.2.15 vote <proposal-id> yes
GDC_GATEWAY_VERSION=v3 \
GDC_GATEWAY_ESCROW_ROTATION_ENABLED=false \
GDC_GATEWAY_ESCROW_ROTATION_SETTLEMENT_ENABLED=false \
  ./gdc.sh --release testnet-0.2.15 ops gateway
./gdc.sh --release testnet-0.2.15 settle
GDC_GATEWAY_VERSION=v4 \
GDC_GATEWAY_ESCROW_ROTATION_ENABLED=false \
GDC_GATEWAY_ESCROW_ROTATION_SETTLEMENT_ENABLED=false \
  ./gdc.sh --release testnet-0.2.15 ops gateway
./gdc.sh --release testnet-0.2.15 settle
./gdc.sh ops monitoring
./gdc.sh ops site
./gdc.sh ops edge
./gdc.sh ops explorer
```

`ops gateway` must report an active unblocked DevShard before the public OpenAI-compatible access surface is considered ready. A successful direct MLNode response alone is not proof of chain-accounted gateway inference.

`ops monitoring` provisions three reproducible dashboards. The compact
`gdc-overview` remains available for operational triage; the public entry point
is `gdc-network` with a 24-hour chain, validator and host view, and
`gdc-inference` provides a seven-day gateway, executor, latency and capacity
view. Prometheus scrapes the gateway metrics over the Docker host gateway, so
the inference dashboard uses the same `/metrics` endpoint as the public API
runtime without exposing an additional public collector. Run
`04-ops/grafana/generate-dashboards.sh` after editing the dashboard source so
the authenticated and anonymous copies remain identical.

Gateway escrow rotation is enabled by default. The gateway keeps two temporary
and two regular escrows per model around the short test-lab epoch transition
and keeps the same client API keys while routing later requests through the
replacement set. Configure the reserve with
`GDC_GATEWAY_ROTATION_TEMP_COUNT` and
`GDC_GATEWAY_ROTATION_TARGET_COUNT`; both must remain positive.
This is required because settled or pruned escrows cannot accept new
inferences. Automatic settlement is also enabled so rotated escrows return
their unused balance instead of exhausting the gateway account. Set both
`GDC_GATEWAY_ESCROW_ROTATION_ENABLED=false` and
`GDC_GATEWAY_ESCROW_ROTATION_SETTLEMENT_ENABLED=false` only for the bounded
manual settlement rehearsal; that is not an always-on access mode.

Issued API keys have no request-count or lifetime quota. The test-lab defaults
use the gateway's `0` (unlimited) values for concurrent requests and input
tokens in flight. Capacity-derived concurrency uses an intentionally
non-limiting value because the gateway normalizes zero there to its
conservative default. An arbitrary eight-request ceiling therefore cannot make
otherwise valid keys appear exhausted.
Protocol phases, a missing active escrow, unavailable ML capacity and the
model context window remain real service boundaries and must be reported as
such.

The always-on lab gateway uses relaxed PoC request handling with
`DEVSHARD_CAPACITY_AWARE_LIMITS=off`. During the short PoC window, the gateway
continues with the preserved participant set instead of interpreting the
expected empty current-weight snapshot as zero service capacity. Outside PoC,
normal runtime availability and participant health checks still apply.

## Telegram key issuer

The bot implementation is part of this release at
[`scripts/telegram-bot/`](scripts/telegram-bot/). The BotFather token belongs
in the ignored root `.env`; the finite `gateway-key-pool.json` remains a
root-owned runtime file on the gateway host. Neither secret is committed.

After those two files have been provisioned and the gateway is active, deploy
or move the bot to the configured secondary-services host after it is available:

```bash
./gdc.sh telegram-bot
```

The deployment keeps the durable issuance database on that host, stops any
gateway-host poller, and verifies both the Telegram identity and an
authenticated key before reporting success.

## Single-node operations

Use these commands for a controlled node recovery rehearsal. `verify` waits for synchronization and checks common-height consistency; a running container is not sufficient evidence of recovery.

```bash
./gdc.sh node stop validator-b
./gdc.sh node start validator-b
./gdc.sh node verify validator-b
./gdc.sh node reset validator-b
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

If a target node fails during rollout, the upgrade bundle ends in `BLOCKED`
and records the failed stage, failed node, completed target nodes, and exit
status. Do not reset Genesis and do not downgrade any node after the approved
height. Correct the failed target deployment and resume only with the same
pinned command:

```bash
./gdc.sh --release testnet-0.2.15 upgrade
```

The resume preflight accepts nodes still on the recorded `0.2.14` baseline or
already on this exact `0.2.15` profile. Any third or mixed release is rejected
before another host changes.

## Optional overlays after upgrade evidence

```bash
./gdc.sh --release testnet-0.2.15 ha v4
./gdc.sh --release testnet-0.2.15 bridge-deploy sepolia
GDC_SEPOLIA_CONTRACT=<authorized-contract-address> \
GDC_SEPOLIA_BEACON_STATE_URL=<beacon-state-endpoint> \
  ./gdc.sh --release testnet-0.2.15 bridge sepolia
```

The HA phase checks traffic through loss and recovery of one v4 `versiond`
replica. `bridge-deploy sepolia` creates a fresh Genesis-bound contract after
validating Sepolia chain ID `11155111`; it reads the mode-0600
`GDC_SEPOLIA_PRIVATE_KEY_FILE` and never accepts a private key in argv. Complete
Community DevNet governance registration and set a separately preflighted
beacon checkpoint URL before `bridge sepolia`. The runtime bridge phase stays
blocked without those values and never guesses Ethereum configuration.

## Reset and prove public truth

```bash
./gdc.sh reset --yes
```

Reset removes only resettable DevNet containers, volumes, networks, deployment state, generated accounts and Genesis artifacts. It preserves prior run evidence, Docker images, model cache, Telegram issuer, public edge and public Grafana. The reset contract includes browser evidence that the status site shows every stopped node as offline and reports gateway traffic as `OFFLINE` with `Network reset – no nodes online`. It must never report `PENDING` when the network itself is down. Chain-dependent PASS bundles record their chain ID and Genesis SHA-256, so preserved evidence from an earlier Genesis remains historical and cannot satisfy a current-chain gate.

After reset, repeat the baseline from `prepare`. Public observability must show the actual reset state, not stale metrics.

## Validation before contribution

```bash
make shellcheck
make test
```

Runtime evidence is written under `artifacts/runs/<UTC timestamp>/` and remains local unless it has been reviewed and sanitized for publication.
