# Community DevNet — Architecture Note

**Status: LIVE, first generation (`gonka-devnet-community`).** Milestone 1 is complete: the network is deployed, reproducible end-to-end from the [net-deployment-runbook](../net-deployment-runbook/README.md), with public observability online. This note tracks the running architecture; deployment mechanics, exact image pins and phase commands live in the runbook.

## Purpose

A small, always-on, geographically distributed Gonka network for protocol, node, DevShard, operational, integration, and distributed-behavior testing — separate from mainnet, cost-efficient to operate, and realistic enough to catch issues that local environments cannot: latency, synchronization, propagation, regional instability.

## Architecture decisions

- **Clean genesis.** The persistent Community DevNet starts from a clean genesis. Stateful network copies may be launched from application-state exports as temporary, isolated shadow environments for upgrade, migration, and regression testing.
- **Long-lived network.** The network is intended to persist across routine protocol upgrades (the `0.2.14 → 0.2.15` governed upgrade is rehearsed on it). A new chain ID is introduced when the network must be relaunched from a new genesis; any such reset is announced in advance.
- **Bootstrap profile first.** The first generation runs a fast rehearsal profile — 50-block epochs, short governance windows, one PoC validation slot — to make lifecycle testing practical. It is not a claim about production timing; realistic steady-state values come later.
- **Key isolation.** All DevNet keys and credentials are unique to the DevNet; nothing is shared with mainnet.
- **Independent validators.** Every node join is treated as onboarding an independent validator. Additional nodes can be operated by delegated operators via an encrypted handoff flow that never shares coordinator secrets (see runbook `handoff create` / `handoff approve`).
- **Reproducible deployments.** All images and DevShard binaries are pinned by digest in release profiles; a reset preserves only the public observability runtimes and the network is rebuilt from `prepare` up.

## Current topology

```
├── gonka-dev.net          static network/status site
├── api.gonka-dev.net      authenticated OpenAI-compatible gateway
├── grafana.gonka-dev.net  public dashboards
│
├── node0.gonka-dev.net ─┐ genesis dbsmart-a5000
├── node1.gonka-dev.net ─┤ join    one-nelsinki
├── node2.gonka-dev.net ─┤ join    leadergpu-4090
├── node3.gonka-dev.net ─┤ join    gigagpu1
└── node4.gonka-dev.net ─┘ join    one-net
                                   │
                                   ▼
                                   dbsmart-rtx-2000 (dedicated MLNode host)
```

| Node | Chain role | Host | GPU profile | Extra services |
|---|---|---|---|---|
| node0 | genesis validator | dbsmart-a5000 | A5000 24 GB | DevShard gateway, Prometheus + authenticated Grafana + alerting, status site origin, G-Meter, `/gateway/*` bootstrap route |
| node1 | join validator | one-nelsinki | T4 16 GB | — |
| node2 | join validator | leadergpu-4090 | RTX 4090 24 GB | operator-handoff rehearsal target (440 GiB data disk) |
| node3 | join validator | gigagpu1 | RTX 3090 24 GB | — |
| node4 | join validator | one-net | Blackwell 16 GB (dedicated ML host) | public TLS edge (Caddy), anonymous public Grafana, explorer entry, Telegram key-issuer bot |

- **node4's MLNode runs on a separate machine** (`dbsmart-rtx-2000`, RTX PRO 2000 Blackwell). The network node and the ML host are deliberately different hosts; the ML endpoint is resolved from operator SSH inventory, never from public DNS. Blackwell (compute capability 12.0) requires a newer MLNode runtime image than the 0.2.14 generic one — a pinned hardware-runtime exception in the release profile.
- **node0 keeps its own TLS name** because DAPI peers use the configured node URL for PoC proof exchange and chain RPC; all other public application origins terminate on the node4 edge.

## Public surfaces

| Endpoint | What it serves | Where it terminates |
|---|---|---|
| `https://gonka-dev.net` | static network/status site (per-node status cards, participant list from committed chain state, gateway status) | TLS on node4 edge → site origin on node0 |
| `https://api.gonka-dev.net/v1` | authenticated OpenAI-compatible inference via the chain-accounted DevShard v4 gateway | TLS on node4 edge → gateway on node0 |
| `https://grafana.gonka-dev.net` | public dashboards: `gdc-network` (24 h chain/validator/host view), `gdc-inference` (7-day gateway/executor/latency/capacity), `gdc-overview` (triage) | anonymous Grafana copy on node4 |
| `https://nodeN.gonka-dev.net` | per-node status/proxy endpoints (`node0` additionally exposes the one-participant bootstrap gateway route) | each node |
| Telegram key bot | self-service issuance of gateway API keys from a finite pre-generated pool | node4 (node0 during bootstrap) |

Access model: API keys are issued through the Telegram bot and have no artificial request-count or lifetime quota — protocol phases, escrow state, ML capacity and the model context window are the only real service boundaries. The gateway rotates its escrow automatically before each short DevNet epoch transition (with auto-settlement), so issued keys survive epoch switches.

## Network profile (first generation)

| Parameter | Value |
|---|---|
| Chain ID | `gonka-devnet-community` |
| Baseline release | `testnet-0.2.14` (pinned commit + image digests in `profiles/releases/`) |
| Upgrade rehearsal | governed on-chain upgrade to `testnet-0.2.15` (state-preserving, not a new baseline) |
| Epochs | 50 blocks, one PoC validation slot (must stay non-zero for a chain-accounted gateway) |
| Model | [Qwen/Qwen3-0.6B](https://huggingface.co/Qwen/Qwen3-0.6B) on every MLNode |
| Inference access | DevShard v4 gateway (v3/v4 approved via chain governance), escrow rotation + auto-settlement |
| Optional overlays | DevShard v4 HA (versiond replica loss/recovery), Sepolia bridge |
| Monitoring | Prometheus + Grafana + Alertmanager + blackbox probes on node0; anonymous public copy on node4; NVIDIA GPU metrics agents on ML hosts |

## Milestone path (per proposal)

- **M1 — done:** architecture agreed; 5 nodes online across 5 providers; deployment reproducible via the runbook; public status site, gateway and dashboards live.
- **M2 — in progress:** grow towards 9+ MLNodes across target regions; join guide published ([ROLE-JOIN.md](../net-deployment-runbook/ROLE-JOIN.md)) and operator-handoff flow rehearsed; monitoring polish.
- **M3:** stable operation; incident log; onboarding guide for external participants.
- **M4:** final infrastructure and cost report; handoff package.

## Open questions being worked

- Final region/provider mix within the monthly infrastructure cap (path to 9+ MLNodes).
- When to open external joins: the handoff flow works; public join instructions gate on M2 stability.
- Moving from the fast rehearsal profile (50-block epochs) to realistic steady-state chain parameters.
