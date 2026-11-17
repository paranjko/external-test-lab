# DevShard version methodology

The check of a new DevShard version on DevNet. The form of a step and the common rules are in [README.md](README.md).

## What is checked

| Component | Role |
|---|---|
| `devshardd` | runs an escrow session: executes a request, validates, signs |
| `versiond` | keeps one `devshardd` process per approved version |
| `versiond-router` | sends all requests of a session to one `versiond` copy |
| `proxy`, `proxy-router` | the entry to a host |

Governance approves the `devshardd` binary. The host operator updates the other containers.

## Candidate and final release

The developers hand over a release candidate. It runs all 8 steps. A candidate that passes every step becomes the final release. The final release has no shorter run of its own.

## Input

The candidate comes with:

- the version: tag, commit, sha256 of the `devshardd` binary, versions of the other containers;
- the list of changes since the previous version;
- the results of the developers' unit, integration and local load tests.

The list of changes selects the checks of steps 4 and 5. The form of the test results is not fixed yet.

Unit tests, integration tests and local tests on mocks are not part of this methodology.

## Rules

- Checks that already ran on the developers' side are not repeated. The Lab checks what only a live network shows.
- A check that cannot be run is recorded as `SKIP` with the reason.

## Steps

| # | Step | Epochs | Tool |
|---|---|---|---|
| 1 | Stand check | less than 1 | the stand monitoring |
| 2 | Rollout | 1 to 2 | the governance vote and the container update; the order is not written down yet |
| 3 | Smoke | less than 1 | [smoke-checklist.md](../smoke-checklist.md), by hand |
| 4 | Functional checks of the changes | not fixed yet | the developers' manual test plan; no Lab checks yet |
| 5 | Regression | not fixed yet | none yet, by hand |
| 6 | With the stable gateway | as in [gateway.md](gateway.md) | [gateway.md](gateway.md), steps 1 to 12 |
| 7 | Load and faults | not fixed yet | [stand-load](../devshard-v6-load/stand-load), [remote-steps.sh](../devshard-v6-load/remote-steps.sh), [remote-soak.sh](../devshard-v6-load/remote-soak.sh), [remote-wrapper-watch.sh](../devshard-v6-load/remote-wrapper-watch.sh); no fault scenarios yet |
| 8 | Report | not applicable | none yet; the report has no fixed form |

All steps run on DevNet.

### 1. Stand check

- Checks: the stand is healthy before the rollout, so a stand fault is not taken for a version defect.
- Epochs: less than 1, before the rollout.
- Expected: blocks advance, all validators are in the set, hosts serve both models, both gateways answer.
- Done when: every item is normal. The state before the rollout is recorded: component versions, weights, number of escrows.

### 2. Rollout

- Checks: the move to the new version itself, as operators will get it.
- Epochs: 1 to 2.
- Expected: sessions started on the previous version finish on it; the network does not halt; a rollback stays possible.
- Done when: the new version runs on every host of the group.

### 3. Smoke

- Checks: the main paths work right after the rollout.
- Epochs: less than 1.
- Expected: the pass signals of the checklist.
- Done when: every applicable check is `PASS`.

### 4. Functional checks of the changes

- Checks: each change of the version does on a live network what it claims.
- Epochs: not fixed yet.
- Expected: the expectation written in each test of the developers' manual test plan.
- Done when: each change has `PASS`, `FAIL` or `SKIP` with the reason.

### 5. Regression

- Checks: no fixed DevShard defect is back.
- Epochs: not fixed yet.
- Expected: by the table below. The expectations are exact, so a verdict is set. A returned defect is `FAIL` and a defect issue.
- Done when: no defect is back.

| Defect | Check | Expected |
|---|---|---|
| A host loses its slots of an open escrow after a restart | under constant load, stop one host for a few minutes and bring it back | no client errors, no `not_executor` answers, the host is not excluded |

Each new confirmed defect adds a row. The list of past DevShard defects is not complete yet.

### 6. With the stable gateway

- Checks: the DevShard version and the stable gateway release work together.
- Epochs: as in [gateway.md](gateway.md) for a release build.
- Expected: as in [gateway.md](gateway.md).
- Done when: the release build has its result by [gateway.md](gateway.md), on hosts that run this DevShard version.

The gateway steps are not repeated here. The DevShard report takes their result.

### 7. Load and faults

- Checks: the version under load on a live stand, compared with the previous version.
- Epochs: not fixed yet.
- Expected: no threshold. The comparison with the baseline is reported without a verdict.
- Done when: the comparison is recorded.

Compared inside and outside PoC and confirmation PoC windows:

- client errors by type;
- p50, p95 and p99 latency;
- memory and CPU of hosts and gateways, restarts;
- excluded participants and missed blocks.

### 8. Report

- Checks: not applicable.
- Epochs: not applicable.
- Expected: each step has `PASS`, `FAIL`, `SKIP` with the reason, or a comparison with the baseline.
- Done when: the report is published in the test issue of the version.

The report states the version under test and the baseline, the result of each step with numbers, the result of [gateway.md](gateway.md) for the release build, the defects found as links to their issues, and what was not checked and why. The release decision stays with the developers and governance.

## Thresholds

| What | Threshold | Source |
|---|---|---|
| Smoke and regression answers | the exact expectation of the check | [smoke-checklist.md](../smoke-checklist.md), the defect issue |
| Functional checks | the expectation of the test | the developers' manual test plan |
| Client error share, p95, memory growth | none | not set |
