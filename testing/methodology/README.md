# Test methodology for Community DevNet

Two methodologies in one form:

- [gateway.md](gateway.md): a new gateway build.
- [devshard.md](devshard.md): a new DevShard version.

A gateway build can ship more often than a DevShard version. Each DevShard version ships with a stable gateway release, and the two are checked together.

## Scope

The Lab checks a build or a version on DevNet only. Unit tests, integration tests and local tests on mocks stay with the developers. Their results come with the build or the candidate. The form of these results is not fixed yet.

## Form of a step

Every step has the same fields:

| Field | Content |
|---|---|
| Checks | the risk the step covers |
| Epochs | the duration in stand epochs |
| Expected | the normal result; a threshold names its source |
| Done when | the condition to move to the next step |

The summary table of each methodology names the tool of every step: a script or checklist of this repository, or `none yet`.

## Rules

- The baseline is the previous build or version on the same stand, under the same load, in the same minutes. A result without a baseline is described, not compared.
- A verdict needs a threshold with a source. A result without a threshold is reported against the baseline, without `PASS` or `FAIL`.
- Durations are counted in stand epochs. A load step covers whole PoC and confirmation PoC windows. The windows are read from the chain.
- A confirmed defect gets its own issue. The retest result goes into that issue.
- The check stops when the build does not start or the smoke step fails.

## Test issue

Each new gateway build or DevShard version gets one issue: what is checked, its kind, and the list of steps from the methodology. Each step is a sub-issue. The result of a step is a comment in its sub-issue, by the fields of the step.
