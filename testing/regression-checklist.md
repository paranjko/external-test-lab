# Community DevNet — public regression checklist

**M2 public catalogue:** stable cross-release regression coverage. Detailed inputs, thresholds, credentials, and security-sensitive procedures remain campaign-specific.

Confirmed defects and incidents should strengthen this list rather than remain one-off findings.

## Consensus / Host lifecycle

| ID | Scenario | Invariant |
|---|---|---|
| REG-01 | Validator restart / temporary outage | Network progresses or recovers within the campaign bound |
| REG-02 | Mixed-version / state-preserving update | No unexplained halt; confirmed history / lineage is preserved |
| REG-03 | Catch-up after downtime | Returning Host catches up without reset-by-default |
| REG-04 | Fresh external JOIN | Public inputs + operator-owned state are sufficient; no coordinator secrets |
| REG-05 | Re-entry / repeated JOIN | Existing local / on-chain state is classified before mutation |
| REG-06 | Backup / clean-host restore | Validator / peer identity is preserved through supported recovery |
| REG-07 | Pruned bootstrap RPC | Old-checkpoint unavailability does not break quorum-based lineage validation |
| REG-08 | Early failure reporting | Preflight failures remain reportable without leaking secrets or unsafe paths |

## ML / inference / gateway

| ID | Scenario | Invariant |
|---|---|---|
| REG-09 | ML qualification | Host is qualified against the network release / profile actually resolved |
| REG-10 | Unsupported hardware | Admission fails clearly before leaving a partially registered Host |
| REG-11 | Model / runtime identity | Served model and runtime match the tested composition |
| REG-12 | Auth + accounting | Valid auth succeeds; invalid auth fails; accepted traffic follows accounting |
| REG-13 | Fail-closed readiness | Gateway does not dispatch on stale / unavailable admission evidence |
| REG-14 | Candidate staging / rollback | Candidate stays isolated until promotion; previous runtime remains recoverable |
| REG-15 | Chat Completions / Responses compatibility | Published broker contracts remain compatible |
| REG-16 | Streaming / non-stream terminal behavior | Both modes complete consistently; no `nonce_finished=false`-style regression |
| REG-17 | Multi-region inference | Campaign-required independent Hosts / regions can complete inference |

## Lifecycle / observability / recovery

| ID | Scenario | Invariant |
|---|---|---|
| REG-18 | Epoch boundary / PoC lifecycle | Network advances through expected lifecycle stages or exposes an attributable failure |
| REG-19 | Escrow / accounting rotation | Gateway follows active accounting state across transitions |
| REG-20 | Height / hash evidence | Results remain attributable to the tested composition and chain state |
| REG-21 | Public Host state | Stopped / unreachable Hosts are not presented as healthy |
| REG-22 | GPU / software inventory | Public inventory maps runtime evidence to the intended Host without secret leakage |
| REG-23 | Incident recovery | Original genesis / confirmed history is preserved where recovery permits |
| REG-24 | Defect → regression | Confirmed core-affecting defects become retained scenarios / automation where feasible |

Campaign-specific bridge, load, large-model, or deep model-matrix checks are added only when explicitly in scope.

Record `PASS`, `FAIL`, `INCONCLUSIVE`, or `N/A` for the applicable subset and link evidence / defects. A new release does not inherit an earlier pass without rerunning the scenarios in scope.
