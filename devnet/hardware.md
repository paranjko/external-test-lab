# Community DevNet hardware inventory

Snapshot: **2026-10-13, 15:21 UTC**, collected through read-only SSH
checks of the ten operator inventory entries. All ten hosts were reachable.
This inventory records hardware visible to the operating system and running
containers at that time. It does not establish validator membership, working
inference, model qualification, or capacity reserved for a new experiment.

There are **ten machines, nine with NVIDIA compute GPUs** detected and responding through NVIDIA drivers. `node4` is the network/edge machine; its MLNode runs on
the separate `node9` machine. These counts are not a validator count.
Provider and regional information is in [regions.md](regions.md).

## Revalidation — 14 October 2026

Read-only SSH probes on all ten machines confirmed the GPU models, total
VRAM, drivers, logical CPU counts, CPU names and OS-visible RAM below.
Filesystem sizes for `/` and `/srv` also match the earlier snapshot.
The earlier OS-version and CPU-instruction observations retain their original
13 October date; they were not rechecked in this pass.

The current DAPI MLNode registrations confirm **node1 → local GPU + node7**
and **node4 → node9**. node7 has a running MLNode but no running Network Node
container. It contributes GPU capacity to node1, not a second independent
participant for the model group's `v_min` requirement. Remote GPUs do not
automatically combine their VRAM or form a tensor-parallel worker.

The old AMD description of node8 does not describe this inventory: node8 is
an RTX 3090. Consult this file before using historical rollout notes or
qualification instructions as hardware evidence.

### Model placement assessment

This is a hardware/runtime preflight, **not a completed model-load or PoC
qualification**. No model was stopped, switched or loaded during these probes.
The checked model contracts are [Qwen3-4B](../model/qwen3-4b-instruct-2507.lock)
and [Qwen2.5-7B](../model/qwen2.5-7b-instruct.lock): BF16, single GPU,
respectively 25,000 and 4,096 context tokens. These locks are qualification-only.

| Machine | CUDA capability | Qwen3-4B-Instruct-2507 | Qwen2.5-7B-Instruct |
|---|---|---|---|
| node1 | 7.5, T4 | Candidate only with a separately qualified FP16 runtime; the BF16 lock is incompatible | Do not select the current BF16 profile; FP16 also leaves very little memory for cache and execution |
| node7 | 7.5, T4 | Same FP16 qualification requirement; currently a remote worker of node1 | Same limitations as node1 |
| node8 | 8.6, RTX 3090 | Suitable hardware candidate; load and PoC qualification pending on this host | Preferred candidate for this host; load and PoC qualification pending |

T4 cannot run the current BF16 profile. Changing to FP16 is not proof of
numerical agreement with the BF16 validators. Before moving either T4, test
the exact model revision, full configured context, cache/backend settings,
completion and cross-validator PoC acceptance. For 7B, fitting weights alone
does not establish enough memory for the full workload; quantization would
be a separate numerical compatibility experiment, not an approved shortcut.

The 24 GB hosts node0/node2/node3/node5/node8 are the hardware candidates for
either model. The 16 GB Blackwell hosts node6/node9 must retain their separately
verified runtime/cache configuration; do not infer that a generic BF16 lock
has the same memory requirements. Node4 itself is not a GPU placement target.

### Maintenance rule

Use this inventory as the baseline instead of rediscovering stable hardware
on every task. Refresh the affected row after host replacement, GPU or driver
changes, SSH alias reassignment, or MLNode reassignment. Keep the observation
date and distinguish hardware facts from workload qualification. Check free
VRAM, disk space and current workload ownership immediately before a real
deployment: those transient values cannot be guaranteed by this document.

## Accelerators

VRAM below is the total reported by `nvidia-smi`, in MiB. Marketing capacities
such as “16 GB” differ from the memory exposed to the runtime. An unavailable
driver leaves runtime VRAM unverified, even when PCI identifies the GPU.

| Host | Observed GPU | Reported VRAM, MiB | NVIDIA driver | Container observation |
|---|---|---:|---|---|
| `node0` | NVIDIA RTX A5000 | 24,564 | 595.71.05 | Network and MLNode containers running |
| `node1` | Tesla T4 | 15,360 | 580.178.04 | Network and MLNode containers running |
| `node2` | NVIDIA GeForce RTX 4090 | 24,564 | 580.178.04 | Network and MLNode containers running |
| `node3` | NVIDIA GeForce RTX 3090 | 24,576 | 580.178.04 | Network and MLNode containers running |
| `node4` | No compute GPU observed; virtual display controller only | n/a | n/a | Network and edge containers running; ML is on `node9` |
| `node9` | NVIDIA RTX PRO 2000 Blackwell | 16,311 | 595.91.07 | MLNode and monitoring containers running |
| `node5` | NVIDIA RTX A5000 | 24,564 | 615.71.09 | Network and MLNode containers running |
| `node6` | NVIDIA RTX PRO 2000 Blackwell | 16,311 | 595.91.07 | Network and MLNode containers running |
| `node7` | Tesla T4 | 15,360 | 610.57.04 | MLNode and test containers running; no Network Node container observed |
| `node8` | NVIDIA GeForce RTX 3090 | 24,576 | 615.71.09 | Network and MLNode containers running |

`node8` now reports RTX 3090 memory through its working NVIDIA driver.
`node5` now has an RTX A5000 and Xeon E5-2690 v4.
`node9` was formerly named `node4-ml`; existing container names retain the old name.

## CPU, memory and storage

CPU names and logical CPU counts are reported by `lscpu`; virtual machines may
expose only a subset of the named processor. RAM is OS-visible `MemTotal`,
rounded to 0.1 GiB. Storage is the size of the filesystem containing
`/srv/dai`, rounded to whole GiB, not raw drive capacity or free space.

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

### CPU compatibility

All ten machines expose `adx`, `bmi1` and `bmi2`, required by the
[published-image JOIN check](../net-deployment-runbook/ROLE-JOIN.md).
The replacement node5 CPU passes this instruction check; the earlier
missing-instruction exception no longer describes this machine.

This is not full workload qualification. node4 and node9 expose virtual CPUs;
logical CPU counts are not physical core counts.

## Using this inventory

- Check current **free** GPU memory before assigning a workload. Total VRAM is not spare
  capacity, even when the served model has relatively few parameters.
- The 24 GB class is the largest single-GPU tier in this fleet. GPUs on
  geographically separate hosts do not automatically form one shared memory
  pool for a larger model.
- T4, Ampere, Ada and Blackwell require compatible runtime builds and
  kernels. A model fitting in memory is not enough to qualify it for Gonka.
- `node9` exposes 26.9 GiB RAM, below the published practical 32 GB baseline.
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
