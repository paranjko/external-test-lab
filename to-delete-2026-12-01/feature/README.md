# DevShard v5 qualification features

These Gherkin features are the External Test Lab representation of the
Coreteam v5 operator manuals. They define observable outcomes, not a claim
that a scenario has passed.

| Feature | Coreteam manual | Evidence classes |
| --- | --- | --- |
| [height sync](devshard_v5_height_sync.feature) | [v5 manual height-sync](https://github.com/gonka-ai/gonka/blob/devshard-0.2.15-v5/devshard/docs/v5-manual-height-sync.md) | upstream unit, testenv, safe Community DevNet observation, isolated-rig defer |
| [residual behaviour](devshard_v5_residual.feature) | [v5 manual residual](https://github.com/gonka-ai/gonka/blob/devshard-0.2.15-v5/devshard/docs/v5-manual-residual.md) | upstream unit, testenv, E2E, safe Community DevNet observation, isolated-rig defer |

## Current qualification state

`v2026.09.05-rc.1` is historical controlled-QA material. It predates the
host-ping repair and cannot qualify the final v5 source.

`v2026.09.08-rc.0` freezes the post-repair source while Gonka remains
`v0.2.15` and DAPI remains `v0.2.15-post3`. Fresh upstream evidence passes
host-ping and rolling-update coverage, but
`TestValidationLeaseRaceStaleReclaim` reproducibly fails. The candidate is a
test artifact, not a release-qualified deployment.

## Next test sequence

1. Verify the published candidate binary, images, SBOMs, and attestations.
2. Preserve the stale-lease result as `FAIL`; do not relabel it as a pass.
3. After Coreteam fixes or explicitly accepts that release gate, execute the
   safe Community DevNet height-sync scenarios, then residual scenarios.
4. Run equivalent v4 and v5 functional cells.
5. Run paired inference-load comparison only after both versions are
   functionally ready.
