# Test Strategy — External Test Lab (pre-release assurance)

**Version: M1 initial strategy (August 2026).** Extended versions will add a public catalogue of test scenarios — smoke and regression checklists (M2 artifact per [proposal #82](https://github.com/gonka-ai/gonka/discussions/1388)).

## Purpose

Give the community a clear, repeatable confidence signal before a release ships. The Lab answers: **is this release ready for operators and users on a live, multi-region network?**

The Lab provides an independent readiness recommendation. The final release decision remains with Protocol Maintainers and, where applicable, governance.

## Two modes of work

1. **Release assurance** — validation of provided release candidates and DevShard builds, on the handoff terms below.
2. **Continuous regression** — between release candidates, testing capacity goes to proactive bug hunting and invariant-driven black-box regression of the core network contract (inference → validation → settlement, durability, safety). Confirmed defects are filed through the public defect process; each confirmed core-affecting defect becomes a permanent regression check so it cannot silently return.

## Environments

- **Community DevNet** (`gonka-dev.net`) — the primary environment: geographically distributed nodes, chain-accounted DevShard gateway, public dashboards. See [devnet/architecture.md](../devnet/architecture.md).
- **Burst GPU capacity** — rented when release-candidate, large-model, or load testing requires it; usage itemized in monthly reports.
- All testing uses DevNet-only keys and accounts; never mainnet keys, funds, or endpoints.

## Scope (in)

- **Upgrade rehearsal** — planned node/API (and other required containers) upgrade on a multi-region set; downtime, catch-up, no consensus halt; post-upgrade health (error-free logs, healthy block production, uninterrupted lifecycle).
- **New joiner path** — cold join, catch-up to tip, mid-epoch join, rejoin after offline; allowlist / approved binary fetch where applicable.
- **Geo / time-sensitive behavior** — dispersed hosts; clock sync; seed submit / signing under RTT; no region systematically missing windows or losing rewards.
- **Continuous lifecycle health** — epoch → PoC → confirmation-PoC → inference; restart mid-lifecycle; recovery; no stuck phase over time.
- **Chain as product (inference)** — happy-path inference (and streaming where standard) through the chain-accounted gateway; basic miss/failure visibility; not a full model matrix.
- **Basic bridge** — deposit/withdraw (or the agreed smoke bridge transactions) succeed and are visible on the explorer; not adversarial bridge security.

## Scope (out)

- Speculative, experimental, or unfinished surfaces not listed in the release notes for Lab coverage.
- Load/chaos beyond the agreed smoke pack.
- Deep product matrices (unless the release explicitly adds a Lab smoke item).
- Full security red-team / economic exploit hunting — findings are escalated, not hunted systematically.

## Near-term DevShard validation sequence

The Lab builds confidence in protocol changes through ordered, separately
reported iterations. A later iteration does not turn an earlier baseline into
an assumed result.

1. **Current baseline — `v2026.07.23` / `devshardd v3`.** Establish a clean
   Community DevNet, prove independent Host joins, and retain chain,
   inference, and public-observability evidence for the v3 runtime.
2. **Next upgrade iteration — `v2026.08.06` / `devshardd v3` and `v4`.** In a
   separate change and run, rehearse the documented network upgrade and verify
   the relevant v3/v4 lifecycle before and after it.
3. **Future target — `devshardd v5`.** Use the completed baseline and upgrade
   evidence to define the v5 validation request and its acceptance pack; v5 is
   not assumed compatible until that run succeeds.

Each iteration retains the release-profile lock, immutable run manifest,
sanitized chain receipts and verdicts, authenticated inference evidence, and
public dashboard/browser evidence. These are the comparison artifacts for the
next iteration and the basis for a repeatable v5 procedure.

## Release assurance flow

Handoff terms follow proposal §11: protocol releases — RC, upgrade notes, affected components, and test focus **at least 7 days** before the planned vote/rollout where feasible; DevShard validation — **at least 3 days** before the expected result. Requests are filed as [validation requests](../../../issues/new/choose).

```
RC handed off → Lab runs the Release Assurance Pack → Lab publishes a scorecard
(pass / fail / residuals) → Maintainers: go / no-go
```

Each report answers: can the community upgrade, join, stay in sync across regions, operate through a normal epoch, do inference, and move a basic bridge transaction? If artifacts arrive late or incomplete, the Lab may still perform limited validation, and the report will state the reduced scope and known limitations.

## Assurance pack (pass criteria)

| Theme | Example pass criteria |
|---|---|
| Upgrade | All Lab validators on target version; tip advancing; no prolonged halt |
| Join | New host reaches tip within agreed SLA; participates in the next eligible window |
| Geo | No region-correlated seed/sign failures above threshold; NTP healthy |
| Lifecycle | Full epoch observed; PoC / confirmation-PoC complete without fleet-wide zeros |
| Inference | N successful completions from ≥2 regions |
| Bridge | M smoke transactions confirmed; balances match expectation |
| Residuals | Known issues listed with severity (blocker vs noise) |

Exact thresholds, SLAs, and test counts are agreed for each RC before the run.

## How the Lab works

- **Transparent** — public run notes and a short scorecard per RC; planned and active work on the [public task board](https://github.com/users/paranjko/projects/1); findings in the [issue tracker](../../../issues).
- **Stable scenarios** — a regression pack runs every release; items are added when a past incident or confirmed defect warrants it.
- **Defect quality** — every defect includes reproduction steps, expected vs actual behavior, impact, and severity (enforced by the [defect template](../../../issues/new/choose)); region, height/epoch, and relevant logs where applicable.
- **Escalation** — release blockers go immediately to the designated Protocol Maintainer contact. Security-sensitive findings are reported privately first per [SECURITY.md](../SECURITY.md); public disclosure follows remediation or an agreed window.
- **Clear scope** — each RC run covers only what is in the assurance pack agreed for that RC.
