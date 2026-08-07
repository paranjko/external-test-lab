# External Test Lab & Community DevNet

Community-owned testing function for the [Gonka](https://github.com/gonka-ai/gonka) network: protocol upgrades, DevShards, inference flows, host/broker operations, and geographically distributed network behavior — validated before governance decisions and production rollout.

This repository hosts the public artifacts of the 4-month pilot approved by Gonka governance.

## Key links

| | |
|---|---|
| Proposal discussion | [gonka-ai/gonka#1388](https://github.com/gonka-ai/gonka/discussions/1388) |
| Governance proposal | [#82 — passed 2026-07-10](https://gonka.gg/network/proposals/82) |
| Escrow contract (funds) | [`gonka1g57f45qjvn0529vpgj8x8mzt8r5k4audchm3pp9pezywxwf4rexqlj8ayw`](https://gonka.gg/address/gonka1g57f45qjvn0529vpgj8x8mzt8r5k4audchm3pp9pezywxwf4rexqlj8ayw) |
| Escrow source & verification | [paranjko/testlab-devnet-escrow](https://github.com/paranjko/testlab-devnet-escrow) |
| Issue tracker | [Issues](../../issues) — defects, validation requests, DevNet access |
| Task board | [Gonka External Test Lab](https://github.com/users/paranjko/projects/1) — planned, active, and completed work |
| DevNet status & dashboards | [gonka-dev.net](https://gonka-dev.net) · [grafana.gonka-dev.net](https://grafana.gonka-dev.net/d/gdc-network/gonka-devnet-network?orgId=1&from=now-24h&to=now&timezone=utc) |
| Security reports | See [SECURITY.md](SECURITY.md) — **do not open public issues for vulnerabilities** |

## What is being built

| Component | Purpose |
|---|---|
| **Community DevNet** | Small always-on geographically distributed network for protocol, node, DevShard, and operational testing. Hosts connecting their own nodes are welcome. |
| **Burst GPU testing** | Temporary rental of large GPU capacity for release-candidate, model-compatibility, and load tests. Usage itemized in monthly reports. |
| **External Testing Team** | Two QA / infrastructure testing engineers validating pre-release builds, DevShards, and deliverables from external teams. See [open positions](jobs/). |

## Team

| Role | Owner |
|---|---|
| Project Lead | [Sergii Paranko](https://www.linkedin.com/in/paranko/) ([@paranjko](https://github.com/paranjko)) |
| Infrastructure Lead | [Mikhail Chudinov](https://www.linkedin.com/in/mikhail-chudinov/) (Mitch) |
| QA Engineers | Hiring — see [jobs/](jobs/) |

## Repository roadmap

Artifacts appear in this repository as the pilot milestones deliver them, per the approved proposal. Status is updated in place.

| Milestone | Artifact | Location | Status |
|---|---|---|---|
| M1 | DevNet architecture note | [`devnet/architecture.md`](devnet/architecture.md) | published |
| M1 | QA hiring | [`jobs/`](jobs/) | **open** |
| M1 | Initial test strategy | [`testing/test-strategy.md`](testing/test-strategy.md) | published |
| M1 | Node deployment runbook | [`net-deployment-runbook/`](net-deployment-runbook/) | published — `1.0.0-alpha.0` |
| M1→M2 | Monthly public report #1 | `reports/monthly/` | planned — before the Aug 13 unlock |
| M2 | Join guide, regional layout | [`net-deployment-runbook/JOIN.md`](net-deployment-runbook/JOIN.md), `devnet/regions.md` | join guide published — regional layout planned |
| M2 | Smoke & regression checklists, live task board | [`testing/`](testing/), [task board](https://github.com/users/paranjko/projects/1) | task board **live** — checklists planned |
| M2 | External join opening (genesis params, seeds) | `devnet/` | planned — gates on M2 stability |
| M3 | Test automation scripts (smoke-level) | `automation/` | planned |
| M3 | Incident log, participant onboarding guide | `runbooks/incidents/`, `devnet/` | planned |
| M4 | Final reports, lessons learned, handoff package | `reports/`, `docs/` | planned |

Folders are created together with their first real artifact — an absent folder means the milestone that delivers it has not been reached yet.

## Reporting and transparency

- Monthly public reports cover deliverables, incidents, spending by budget line, remaining balance, and next-month plan. Reports are posted here and linked in [discussion #1388](https://github.com/gonka-ai/gonka/discussions/1388).
- Release-readiness and DevShard validation reports are published when testable artifacts are provided per the handoff requirements in the proposal.
- Security-sensitive findings follow the private disclosure process in [SECURITY.md](SECURITY.md).
- Unused funds at the end of the pilot are returned to the Community Pool, per the proposal and the escrow contract terms.

## Ownership and handoff

This repository is community-owned by intent. It is planned to be transferred to the `gonka-ai` organization (or another community-designated home) as part of the pilot handoff. Owner model, emergency access, and handoff procedure will be documented in `docs/handoff.md` during the pilot.

## License

[Apache-2.0](LICENSE) applies **only to Test Lab artifacts** in this repository (plans, runbooks, reports, scripts, and other materials authored by the pilot).

It does **not** apply to Gonka network software, protocol code, or chain state. This repository contains no Gonka source code. The Gonka network and its codebase are licensed under separate [terms](https://github.com/gonka-ai/gonka/blob/main/LICENSE.md).
