# Community DevNet architecture

Hardware snapshot: **13 October 2026**. The stand has **10 machines and 9 NVIDIA GPUs** across five recorded providers.

## Fleet at a glance

| Machines | GPU per machine | Recorded location |
|---|---|---|
| node0, node5 | RTX A5000, 24 GB | North Kansas City, US |
| node1, node7 | Tesla T4, 16 GB | Helsinki, Finland |
| node2 | RTX 4090, 24 GB | Amsterdam, Netherlands |
| node3, node8 | RTX 3090, 24 GB | London, UK |
| node4 | No compute GPU | Portland, US |
| node6 | RTX PRO 2000 Blackwell, 16 GB | Russia; city unconfirmed |
| node9 | RTX PRO 2000 Blackwell, 16 GB | League City, US |

Recorded distribution: **US 4, Finland 2, UK 2, Netherlands 1, Russia 1**. Locations come from the published provider inventory; SSH verifies hardware, not physical location. See [regional capacity](regions.md).

## Machine roles

- **node0–node3, node5, node6 and node8:** Network Node and MLNode containers running on the same machine.
- **node4 → node9:** separate Network Node/edge and GPU machines. node9 was formerly named **node4-ml**; existing containers still use that name.
- **node7:** MLNode and test containers running; no Network Node container observed in this snapshot.
- **node0 and node4:** shared gateway, monitoring and public edge services.

The GPUs span Turing, Ampere, Ada and Blackwell, with 16–24 GB per device. All ten machines expose the CPU flags required by the published-image JOIN check. [Hardware inventory](hardware.md) lists CPU, RAM, storage, drivers and measured VRAM.

## Public access and operation

| Surface | Purpose |
|---|---|
| [gonka-dev.net](https://gonka-dev.net) | Live network and participant observations |
| [api.gonka-dev.net/v1](https://api.gonka-dev.net/v1) | Authenticated OpenAI-compatible inference |
| [grafana.gonka-dev.net](https://grafana.gonka-dev.net) | Public monitoring dashboards |

The stand supports protocol, DevShard, inference, JOIN/recovery and distributed-system testing. DevNet credentials are isolated from mainnet. Machine and container counts do not establish validator membership or workload qualification; use live observations for network state.

Deployment commands, release profiles and operator roles are maintained in the [runbook](../net-deployment-runbook/README.md). Earlier topology and milestone results are recorded in the [monthly reports](../reports/monthly/).
