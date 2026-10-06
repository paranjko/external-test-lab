# Community DevNet hardware inventory

Snapshot: **2026-10-07, 06:29 UTC**, collected through read-only SSH
checks of the ten operator inventory entries. All ten hosts were reachable.
This inventory records hardware visible to the operating system and running
containers at that time. It does not establish validator membership, working
inference, model qualification, or capacity reserved for a new experiment.

There are **ten machines, nine with NVIDIA compute GPUs** detected, the driver
on `node8` is not operational. `node4` is the network/edge machine; its MLNode runs on
the separate `node4-ml` machine. These counts are not a validator count.
Provider and regional information is in [regions.md](regions.md).

## Accelerators

VRAM below is the total reported by `nvidia-smi`, in MiB. Marketing capacities
such as “16 GB” differ from the memory exposed to the runtime. An unavailable
driver leaves runtime VRAM unverified, even when PCI identifies the GPU.

| Host | Observed GPU | Reported VRAM, MiB | NVIDIA driver | Container observation |
|---|---|---:|---|---|
| `node0` | NVIDIA RTX A5000 | 24,564 | 595.71.05 | Network and MLNode containers running |
| `node1` | Tesla T4 | 15,360 | 580.173.02 | Network and MLNode containers running |
| `node2` | NVIDIA GeForce RTX 4090 | 24,564 | 580.178.04 | Network and MLNode containers running |
| `node3` | NVIDIA GeForce RTX 3090 | 24,576 | 580.178.04 | No running Docker containers |
| `node4` | No compute GPU observed; virtual display controller only | n/a | n/a | Network and edge containers running; ML is on `node4-ml` |
| `node4-ml` | NVIDIA RTX PRO 2000 Blackwell | 16,311 | 595.91.07 | MLNode and monitoring containers running |
| `node5` | NVIDIA RTX A4000 | 16,376 | 595.91.07 | No running Docker containers |
| `node6` | NVIDIA RTX PRO 2000 Blackwell | 16,311 | 595.91.07 | Network and MLNode containers running |
| `node7` | Tesla T4 | 15,360 | 610.57.04 | Network and MLNode containers running |
| `node8` | NVIDIA GeForce RTX 3090, PCI `10de:2204` | Unverified | Unavailable | No running Docker containers; `nvidia-smi` cannot communicate with the driver |

`node8` now exposes an RTX 3090 instead of the previously observed AMD GPU, runtime memory and GPU readiness require a working NVIDIA driver

## CPU, memory and storage

CPU names and logical CPU counts are reported by `lscpu`; virtual machines may
expose only a subset of the named processor. RAM is OS-visible `MemTotal`,
rounded to 0.1 GiB. Storage is the size of the filesystem containing
`/srv/dai`, rounded to whole GiB, not raw drive capacity or free space.
Where `/srv/dai` is absent, the root filesystem is explicitly identified.

| Host | CPU exposed to OS | Logical CPUs | RAM, GiB | Data filesystem, GiB | Mount | Ubuntu |
|---|---|---:|---:|---:|---|---|
| `node0` | Xeon E5-2680 v4 | 56 | 125.8 | 1,877 | `/srv` | 24.04 |
| `node1` | Xeon Silver 4116 | 48 | 188.5 | 1,832 | `/` | 22.04 |
| `node2` | Xeon E5-2630 v4 | 20 | 62.7 | 439 | `/srv` | 22.04 |
| `node3` | Ryzen 7 3700X | 16 | 62.7 | 463 | `/` (root; `/srv/dai` absent) | 24.04 |
| `node4` | EPYC 7502 | 12 | 62.8 | 630 | `/` | 26.04 |
| `node4-ml` | Intel Core Processor (Broadwell, IBRS), virtual CPU | 16 | 26.9 | 241 | `/` | 26.04 |
| `node5` | Xeon E5-2697 v2 | 48 | 125.8 | 219 | `/` (root; `/srv/dai` absent) | 24.04 |
| `node6` | Ryzen 9 5900X | 24 | 60.7 | 932 | `/` | 26.04 |
| `node7` | Xeon E5-2630L v4 | 20 | 62.7 | 914 | `/` | 22.04 |
| `node8` | Ryzen 7 3700X | 16 | 60.7 | 910 | `/` (root; `/srv/dai` absent) | 26.04 |

### CPU compatibility

[Gonka Quickstart](https://github.com/gonka-ai/gonka-docs/blob/f9f9b1ea79ddf632d41c59c59d59518f7e7d6e39/docs/host/quickstart.md) specifies a 16-core `amd64` CPU, but does not list instruction flags in its hardware requirements

Our [published-image JOIN check](../net-deployment-runbook/ROLE-JOIN.md) requires `adx`, `bmi1` and `bmi2`, the table shows this instruction check only, not full Gonka qualification

| Hosts | Missing CPU flags | Exception and action |
|---|---|---|
| `node0`, `node1`, `node2`, `node3`, `node4`, `node4-ml`, `node6`, `node7`, `node8` | None | All three flags exposed |
| `node5` – Xeon E5-2697 v2 | `adx`, `bmi1`, `bmi2` | CPU replacement not observed, the known standard-artifact `SIGILL` limitation remains, portable builds are required until replacement |

The [portable runtime workaround](../net-deployment-runbook/PORTABLE-RUNTIME.md) covers DAPI and Core, it does not qualify the official DevShard artifact or remove the CPU replacement requirement

Flags were observed on 7 October, recheck after CPU or VM changes, `node4` and `node4-ml` expose vCPUs and logical CPU counts are not physical core counts

## Using this inventory

- Check current **free** GPU memory before assigning a workload. At this
  snapshot `node3` used 1 MiB. Total VRAM is not spare
  capacity, even when the served model has relatively few parameters.
- The 24 GB class is the largest single-GPU tier in this fleet. GPUs on
  geographically separate hosts do not automatically form one shared memory
  pool for a larger model.
- T4, Ampere, Ada and Blackwell require compatible runtime builds and
  kernels. A model fitting in memory is not enough to qualify it for Gonka.
- `node4-ml` exposes 26.9 GiB RAM, below the published practical 32 GB baseline.
  An existing machine's observed configuration does not redefine JOIN
  requirements or prove that a new Host with those resources is supported.
- [The Host requirements profile](../net-deployment-runbook/profiles/devnet-hadware.json)
  describes admission guidance, not this fleet. The model registry's `v_ram`
  is also a separate configuration value, not measured model memory usage.

## Refresh method

Use the corresponding authorized operator SSH entries and read `lscpu -J` (including `Flags` for `adx`, `bmi1`, `bmi2`),
`free -b`, `/etc/os-release`, `df -B1 / /srv/dai`, `lspci -nn`,
`nvidia-smi --query-gpu=name,memory.total,memory.used,driver_version --format=csv,noheader`
and `docker ps`. For AMD, inspect the compute device's vendor/device IDs and
`mem_info_vram_total` under `/sys/class/drm/cardN/device/`.

Record observation time, missing commands and inaccessible hosts explicitly.
These probes do not start, stop or qualify workloads. Publish only the
hardware summary; keep operator access details and raw diagnostics private.
