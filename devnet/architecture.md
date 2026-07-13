# Community DevNet — Architecture Note

**Status: DRAFT (Milestone 1).** This document is being refined as procurement and initial deployment proceed. Numbers below reflect the approved proposal; concrete regions, providers, and node counts will be filled in as nodes come online.

## Purpose

A small, always-on, geographically distributed Gonka network for protocol, node, DevShard, operational, integration, and distributed-behavior testing — separate from mainnet, cheap to run, and realistic enough to catch issues that local environments cannot: latency, synchronization, propagation, regional instability.

## Design principles

1. **Distributed behavior over throughput.** Many small nodes across regions beat few large ones. Inference nodes run lightweight instruct models (target: [Qwen/Qwen3-0.6B](https://huggingface.co/Qwen/Qwen3-0.6B) or equivalent), so consumer-grade GPUs (16 GB VRAM, CUDA 13.0 compatible stack) are sufficient.
2. **Realistic topology.** Part of the DevNet runs as Network Nodes with multiple attached MLNodes, reproducing real multi-MLNode host configurations. Some Network Nodes run on CPU-only servers.
3. **Open by default.** External hosts connecting their own nodes are welcome from the start — join instructions (genesis, seeds, chain-id) will be published in this folder as soon as the network accepts external nodes. Access gating applies only to project-managed resources (managed nodes, burst GPU capacity), via a [lightweight request](../../../issues/new/choose).

## Target shape (per proposal)

| Parameter | Target |
|---|---|
| Inference nodes | 9–13 always-on, plus required Network Node services |
| Regions (indicative) | North America East/West, UK, Germany, France, Finland, Asia — subject to network quality and hosting availability |
| Inference node profile | NVIDIA GPU, 16 GB VRAM, CUDA 13.0 compatible |
| Model profile | Lightweight instruct models (Qwen3-0.6B class) |
| Monitoring | Public dashboard for node availability (tooling under evaluation, incl. coordination with existing explorer/dashboard maintainers) |

## Milestone path

- **M1 (current):** design agreed, procurement started, at least 5 nodes online; blockers documented.
- **M2:** at least 9 nodes across target regions; monitoring live; join guide + deployment runbook published.
- **M3:** stable operation; incident log; onboarding guide for external participants.
- **M4:** final infrastructure and cost report; handoff package.

## Open questions being worked

- Final region/provider mix within the monthly infrastructure cap.
- Dashboard: reuse of existing community explorer infrastructure vs dedicated Grafana-style deployment.
- Chain parameters for the DevNet genesis (to be published here before external join opens).
