# Gateway build methodology

The check of a new gateway build on DevNet. The form of a step and the common rules are in [README.md](README.md).

## Builds

| Build | When | Steps | Epochs |
|---|---|---|---|
| Preliminary | a test build from the developers: a fix or a small change | 1 to 7 | 2 |
| Release | a stable build for operators, shipped with a new DevShard version | 1 to 12 | 2 for steps 1 to 7, then 11 to 17 for steps 8 to 12 run one after another |

A build that fixes a defect found by the Lab always runs the check of that defect in step 4.

Local tests on mocks are not part of this methodology. Their results come from the developers with the build.

## Rules

- Both gateways get the same prompt at the same moment. Otherwise an error can depend on the prompt, not on the gateway.
- Gateway logs are streamed to another machine from the start of a step. Container logs rotate within minutes.
- PoC and confirmation PoC windows are read from the chain. A window that overlaps the install is not counted.

## Steps

| # | Step | Epochs | Tool |
|---|---|---|---|
| 1 | What changed | before the install | not needed |
| 2 | Install | epoch 1 | the operator instructions of the release |
| 3 | Smoke | epoch 1 | [smoke-checklist.md](../smoke-checklist.md), by hand |
| 4 | Regression | epoch 2, with step 7 | [stand-load](../devshard-v6-load/stand-load) for the cache check; none yet for the other two |
| 5 | Hard requests and a bad client | epoch 1 | [remote-one-token.py](../devshard-v6-load/remote-one-token.py) for hard prompts; none yet for a bad client |
| 6 | Targeted checks | epoch 1 | made for the change |
| 7 | Paired load | epoch 2, whole | [stand-load](../devshard-v6-load/stand-load), [remote-parallel.sh](../devshard-v6-load/remote-parallel.sh), [remote-node-sampler.sh](../devshard-v6-load/remote-node-sampler.sh) |
| 8 | Long paired load | 6 to 12 | as in step 7 |
| 9 | Maximum throughput | 1 | [remote-steps.sh](../devshard-v6-load/remote-steps.sh) |
| 10 | Faults | 1 | none yet |
| 11 | Accounting | 2 | none yet |
| 12 | Update and rollback | 1 | the operator instructions; [remote-wrapper-watch.sh](../devshard-v6-load/remote-wrapper-watch.sh) |

All steps run on DevNet. The build runs on one node, the baseline on a neighbour node.

### 1. What changed

- Checks: what exactly is under test and what it is compared with.
- Epochs: before the install.
- Expected: the image with its digest, the commit, the baseline image and the list of changes are recorded.
- Done when: the checks for steps 4 and 6 are chosen from the list of changes.

### 2. Install

- Checks: the build starts and takes traffic.
- Epochs: epoch 1, outside a PoC window.
- Expected: the container is healthy, escrows are created, status and metrics answer. The install time and the client error time are recorded.
- Done when: the build takes traffic.

### 3. Smoke

- Checks: requests pass, keys are checked, a request is accounted, monitoring shows the real state.
- Epochs: epoch 1, about 15 minutes.
- Expected: the pass signals of the checklist. A wrong key is refused with `401`.
- Done when: every applicable check is `PASS`.

The step covers SMK-05 to SMK-09 of the checklist. A request with a wrong key and a request without a key are added; the checklist does not list them.

### 4. Regression

- Checks: no fixed gateway defect is back.
- Epochs: epoch 2, together with step 7. The PoC start check needs a PoC start.
- Expected: by the table below. The expectations are exact, so a verdict is set. A returned defect is `FAIL` and a defect issue.
- Done when: no defect is back.

| Defect | Check | Expected |
|---|---|---|
| A stalled request body breaks the connection | one request whose body stalls for 40 s, then 3 requests on the same connection and 20 on new ones | only the stalled request is refused; the refusal is in the log and in the HTTP response counter |
| `no escrow capacity` refusals at a PoC start | client answers in the 30 s before and after each PoC start | 0 such answers |
| Response cache | repeated requests with one key | cache hits, no errors |

Each new confirmed defect adds a row.

### 5. Hard requests and a bad client

- Checks: refusals on hard prompts and on malformed requests are explained and do not affect other requests.
- Epochs: epoch 1.
- Expected: hard prompts are compared with the baseline by the share of client refusals, without a threshold. A malformed request gets a clear `4xx` answer and a log line.
- Done when: every refusal is explained and no other request is affected.

Hard prompts are prompts where hosts answer with one empty token or fail validation. Chosen dataset rows go one at a time through the build and the baseline, 100 to 200 requests each.

Bad client cases: broken JSON, a body over the limit, an unknown model, `max_tokens` over the limit, a client that drops in the middle of a stream, many connections with one key.

### 6. Targeted checks

- Checks: each change from step 1 does what it claims.
- Epochs: epoch 1.
- Expected: what the description of the change claims.
- Done when: each change has a record of what was checked and what was seen.

### 7. Paired load

- Checks: the build under the constant stand load, compared with the baseline.
- Epochs: epoch 2, whole: one PoC and one confirmation PoC. One more epoch if no confirmation PoC happened.
- Expected: no threshold. The comparison with the baseline is reported without a verdict.
- Done when: the comparison is recorded. For a preliminary build this is the final result.

Compared per gateway and model, inside and outside PoC and confirmation PoC windows:

- client errors by type;
- p50, p95 and p99 latency;
- attempts per request and burned nonces;
- memory, CPU and restarts;
- empty host answers and how many reached the client.

### 8. Long paired load

- Checks: the same as step 7 over a long run: memory growth and escrow rotation.
- Epochs: 6 to 12: at least 5 PoC and 5 confirmation PoC windows, across escrow rotation.
- Expected: no threshold. Memory per epoch is reported as growing or flat.
- Done when: at least 5 PoC and 5 confirmation PoC windows passed and the comparison is recorded.

### 9. Maximum throughput

- Checks: where errors and p95 grow, how the build refuses under overload, whether it recovers.
- Epochs: 1.
- Expected: no threshold. The step where errors grow is recorded and compared with the baseline.
- Done when: the failing step is found and the recovery is recorded.

### 10. Faults

- Checks: a fault loses no request silently, and service recovers by itself.
- Epochs: 1.
- Expected: refusals are explicit; service recovers without manual action; accounting is not lost.
- Done when: each fault has a record of what the client saw and how service recovered.

Faults under constant load, one after another: a gateway restart, a stop and return of one host of the group, a one-minute loss of the chain connection.

### 11. Accounting

- Checks: gateway accounting matches the chain: nonce count, payouts, refund.
- Epochs: 2, across escrow rotation and settlement.
- Expected: the gateway numbers and the chain numbers are equal.
- Done when: the comparison is recorded for each settled escrow.

This comparison has not been run so far.

### 12. Update and rollback

- Checks: the build installs and rolls back by the operator instructions; what the client loses.
- Epochs: 1.
- Expected: no threshold. Two numbers are reported without a verdict: downtime and lost requests.
- Done when: after the rollback the gateway serves requests and both measurements are recorded.

Order:

1. Record the image with its digest, the running config and the number of escrows.
2. Outside a PoC window, replace the image by the operator instructions.
3. Wait for the first successful request. Measure the downtime and the lost requests from the generator results.
4. Run one epoch across a PoC.
5. Return the previous image the same way and take the same two measurements.
6. Check that the gateway serves requests and that the escrows of the new build do not block the old one.

## Thresholds

| What | Threshold | Source |
|---|---|---|
| Smoke and regression answers | the exact expectation of the check | [smoke-checklist.md](../smoke-checklist.md), the defect issue |
| Client error share, p95, memory growth, update downtime | none | not set |

## Report

A preliminary build ends with a comment of tables and facts after step 7. A release build ends with a report on steps 1 to 12 and a recommendation.
