# Community DevNet regional capacity

Fleet reference: **13 October 2026**, 10 machines, 9 NVIDIA GPUs, 5 providers.

| Host | Provider | Recorded location | GPU |
|---|---|---|---|
| node0 | DatabaseMart | North Kansas City, US | RTX A5000 |
| node1 | OneProvider | Helsinki, Finland | Tesla T4 |
| node2 | LeaderGPU | Amsterdam, Netherlands | RTX 4090 |
| node3 | GIGAGPU | London, UK | RTX 3090 |
| node4 | OneProvider | Portland, US | None; remote ML on node9 |
| node5 | DatabaseMart | North Kansas City, US | RTX A5000 |
| node6 | HOSTKEY | Russia; city unconfirmed | RTX PRO 2000 Blackwell |
| node7 | OneProvider | Helsinki, Finland | Tesla T4 |
| node8 | GIGAGPU | London, UK | RTX 3090 |
| node9 (formerly node4-ml) | DatabaseMart | League City, US | RTX PRO 2000 Blackwell |

**Distribution:** US 4, Finland 2, UK 2, Netherlands 1, Russia 1.

Hardware was checked by read-only SSH on 13 October. Provider and location assignments are carried forward from the [M2 inventory](../reports/monthly/2026-09-month-2.md); they have not been reverified against provider accounts. The node9 rename is operator-confirmed.

See [architecture](architecture.md) for machine roles, [hardware](hardware.md) for measured capacity and [live observations](https://gonka-dev.net) for network participation. Historical M2 equipment and spending remain in the monthly report.
