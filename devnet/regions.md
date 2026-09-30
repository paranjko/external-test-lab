# Community DevNet – regional capacity

## Current hardware reference

[Hardware inventory](hardware.md) records the read-only SSH audit of all ten
machines on **2026-09-21**: CPU, RAM, filesystem capacity, GPU, driver and
observed container presence. `node6` and `node7` now have running Network Node
and MLNode containers; `node3` has edge containers only, and `node8` has no
running Docker containers. These observations do not establish JOIN,
inference, PoC or model qualification.

The older provider and regional assignments below have not been reverified
against provider accounts. The M2 state column remains the historical report
cutoff, not the latest operational status. In particular, the current GPU name
reported by both `node4-ml` and `node6` is RTX PRO 2000 Blackwell.

## M2 reporting snapshot

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
