# Community DevNet — M2 regional capacity

**Snapshot:** 2026-08-10 — 2026-09-09

Public inventory of rented M2 capacity. Hosts used for JOIN / reset / restore testing may be rebuilt and disappear from the live participant set; current state is on [gonka-dev.net](https://gonka-dev.net).

| Host | Role | Provider | Region | GPU | M2 state |
|---|---|---|---|---|---|
| `node0` | Full Host | DatabaseMart | North Kansas City, US | RTX A5000 | stable baseline |
| `node1` | Full Host | OneProvider | Helsinki, Finland | Tesla T4 | DevNet / reusable test host |
| `node2` | Full Host | LeaderGPU | Amsterdam, Netherlands | RTX 4090 | DevNet / reusable test host |
| `node3` | Full Host | GIGAGPU | London, UK | RTX 3090 | DevNet / reusable test host |
| `node4` | Network Host | OneProvider | Portland, US | — | network-only |
| `node4-ml` | ML-only | DatabaseMart | League City, US | RTX Pro 2000 | remote ML capacity |
| `node5` | Full Host | DatabaseMart | North Kansas City, US | RTX A4000 | JOIN / backup / restore target |
| `node6` | Full Host | HOSTKEY | Russia | RTX 2000 PRO | staged; preparation at cutoff |
| `node7` | Full Host | OneProvider | Helsinki, Finland | Tesla T4 | staged; preparation at cutoff |
| `node8` | Experimental | GIGAGPU | London, UK | RX 9070 XT | pending; not counted as validated MLNode |

