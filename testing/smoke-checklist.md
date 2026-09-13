# Community DevNet — public smoke checklist

**M2 public catalogue:** minimum post-change confidence pack. Exact thresholds, credentials, test data, and security-sensitive procedures are campaign-specific.

| ID | Check | Pass signal |
|---|---|---|
| SMK-01 | Chain / consensus | Height advances; no unexplained consensus halt |
| SMK-02 | Participants / sync | Expected Hosts are visible and active test Hosts are at / near tip |
| SMK-03 | ML qualification | Required model loads and Host passes the active qualification contract |
| SMK-04 | Lifecycle | Applicable PoC / confirmation-PoC / inference stages progress |
| SMK-05 | Gateway readiness | Traffic is accepted only when network / runtime admission is ready |
| SMK-06 | Non-stream inference | Authenticated completion returns a valid terminal response |
| SMK-07 | Streaming inference | Stream terminates once without truncation / duplicate terminal output |
| SMK-08 | Accounting | Accepted inference follows the active accounting / escrow path |
| SMK-09 | Observability | Public status / dashboards reflect actual network and inference health |
| SMK-10 | Restart / recovery | One Host can restart and catch up without breaking the network |
| SMK-11 | External JOIN | Fresh Host reaches documented preflight / qualification without coordinator secrets |
| SMK-12 | Candidate / rollback | Candidate can be staged before promotion and a bounded rollback path remains |

Record `PASS`, `FAIL`, `INCONCLUSIVE`, or `N/A` for each applicable check, with evidence and residuals. A failed check is a result, not something to rerun until it passes.
