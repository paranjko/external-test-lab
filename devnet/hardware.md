# Community DevNet hardware

Verified: **2026-10-14** — GPU, driver, CPU, RAM, filesystem capacity and MLNode mapping.
OS versions and CPU flags: **2026-10-13**.
10 hosts, 9 NVIDIA GPUs. [Regions](regions.md).

## GPU and MLNode mapping

VRAM: total reported by `nvidia-smi`, not free memory. CC: CUDA compute capability.

| Host | GPU | VRAM, MiB | CC | Driver | ML participant |
|---|---|---:|---|---|---|
| node0 | RTX A5000 | 24,564 | 8.6 | 595.71.05 | node0 |
| node1 | Tesla T4 | 15,360 | 7.5 | 580.178.04 | node1 |
| node2 | RTX 4090 | 24,564 | 8.9 | 580.178.04 | node2 |
| node3 | RTX 3090 | 24,576 | 8.6 | 580.178.04 | node3 |
| node4 | None; Cirrus Logic display only | — | — | — | Uses node9 |
| node5 | RTX A5000 | 24,564 | 8.6 | 615.71.09 | node5 |
| node6 | RTX PRO 2000 Blackwell | 16,311 | 12.0 | 595.91.07 | node6 |
| node7 | Tesla T4 | 15,360 | 7.5 | 610.57.04 | node1, remote MLNode |
| node8 | RTX 3090 | 24,576 | 8.6 | 615.71.09 | node8 |
| node9 | RTX PRO 2000 Blackwell | 16,311 | 12.0 | 595.91.07 | node4, remote MLNode |

node7 has no running Network Node. Its GPU does not add an independent
participant for `v_min`. Each GPU has separate memory.

## CPU, RAM and storage

CPU counts are logical; node4/node9 expose virtual CPUs.
RAM: OS-visible GiB. Storage: capacity of the filesystem containing `/srv/dai`, not free space.

| Host | CPU exposed to OS | Logical CPUs | RAM, GiB | Data filesystem, GiB | Mount | Ubuntu |
|---|---|---:|---:|---:|---|---|
| `node0` | Xeon E5-2680 v4 | 56 | 125.8 | 1,877 | `/srv` | 24.04 |
| `node1` | Xeon Silver 4116 | 48 | 188.5 | 1,832 | `/` | 22.04 |
| `node2` | Xeon E5-2630 v4 | 20 | 62.7 | 439 | `/srv` | 22.04 |
| `node3` | Ryzen 7 3700X | 16 | 62.7 | 463 | `/` | 24.04 |
| `node4` | EPYC 7502 | 12 | 62.8 | 630 | `/` | 26.04 |
| `node9` | Intel Core Processor (Broadwell, IBRS), virtual CPU | 16 | 26.9 | 241 | `/` | 26.04 |
| `node5` | Xeon E5-2690 v4 | 56 | 125.8 | 219 | `/` | 24.04 |
| `node6` | Ryzen 9 5900X | 24 | 60.7 | 932 | `/` | 26.04 |
| `node7` | Xeon E5-2630L v4 | 20 | 62.7 | 914 | `/` | 22.04 |
| `node8` | Ryzen 7 3700X | 16 | 60.7 | 910 | `/` | 26.04 |

CPU flags: `adx`, `bmi1`, `bmi2` present on all ten hosts.
node9 RAM: 26.9 GiB, below the [32 GB practical baseline](../net-deployment-runbook/ROLE-JOIN.md).

## Model constraints

Qualification locks: single GPU, BF16.
[Qwen3-4B-Instruct-2507](../model/qwen3-4b-instruct-2507.lock): 25,000-token context.
[Qwen2.5-7B-Instruct](../model/qwen2.5-7b-instruct.lock): 4,096-token context.

| Hosts | 4B | 7B |
|---|---|---|
| node0, node2, node3, node5, node8 | 24 GB hardware candidates | 24 GB hardware candidates |
| node1, node7 | BF16 unsupported; FP16 load and PoC qualification pending | BF16 unsupported; FP16 memory headroom unverified |
| node6, node9 | Requires host-specific runtime/cache configuration | Not qualified by this inventory |
| node4 | No local GPU | No local GPU |

node8: target-model load and PoC qualification pending.
node1/node7: FP16 compatibility with BF16 validators unverified.
No model-load or PoC tests were executed during this hardware check.

## Verification commands

```sh
lscpu -J
free -b
cat /etc/os-release
df -B1 / /srv/dai
lspci -nn
nvidia-smi --query-gpu=name,memory.total,memory.used,compute_cap,driver_version --format=csv,noheader
docker ps --format '{{.Names}} {{.Image}}'
```

MLNode mapping: DAPI `GET /admin/v1/nodes` on each parent.
Refresh affected rows after hardware, driver or mapping changes.
Check free VRAM and disk space before deployment.
