# Community DevNet regional capacity

Fleet reference: [16 October 2026 GPU report](hardware.md), 12 inventoried hosts and 11 reported NVIDIA GPU hosts, node3 is reachable again

Five providers are recorded for node0–node9, providers for node10 and node11 remain unrecorded

| Host | Provider | Recorded location | GPU |
|---|---|---|---|
| node0 | DatabaseMart | North Kansas City, US | RTX A5000 |
| node1 | OneProvider | Helsinki, Finland | Tesla T4 |
| node2 | LeaderGPU | Amsterdam, Netherlands | RTX 4090 |
| node3 | GIGAGPU | London, UK | RTX 3090 |
| node4 | OneProvider | Portland, US | None recorded; last verified remote ML on node9 |
| node5 | DatabaseMart | North Kansas City, US | RTX A5000 |
| node6 | HOSTKEY | Russia; city unconfirmed | RTX PRO 2000 Blackwell |
| node7 | OneProvider | Helsinki, Finland | Tesla T4 |
| node8 | GIGAGPU | London, UK | RTX 3090 |
| node9 (formerly node4-ml) | DatabaseMart | League City, US | RTX PRO 2000 Blackwell |
| node10 | Not recorded | Russia; city unconfirmed | RTX 4090 |
| node11 | Not recorded | Irvine, United States | RTX 5090 |

Recorded distribution: US 5, Finland 2, UK 2, Netherlands 1, Russia 2, these counts do not establish qualified regional serving capacity

GPU and driver data follow the operator-provided 16 October report, other hardware fields retain the dates listed in [hardware.md](hardware.md), node3's GPU is reported again after the 15 October SSH failure

Provider and location assignments are carried forward from the [M2 inventory](../reports/monthly/2026-09-month-2.md) and have not been reverified against provider accounts, the node9 rename and the node10 and node11 locations are operator-confirmed

See [architecture](architecture.md) for machine roles, [hardware](hardware.md) for measured capacity and [live observations](https://gonka-dev.net) for network participation. Historical M2 equipment and spending remain in the monthly report.
