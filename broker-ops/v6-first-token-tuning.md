# First-token timeout experiment

This operator helper changes only `redundancy.first_token_timeout_floor_ms`
through the existing loopback admin API. It does not restart services, alter
funding or rotation, clear performance history, disable failover, or raise
concurrency. Use Python 3 on the gateway host; credentials remain there.

Dry-run A on node4 (B is on node0):

```sh
ssh gdc-node4 python3 - a --expected-ms 1000 --target-ms 20000 < broker-ops/v6-first-token-tuning.py
```

Apply only after operator authorization, using a new private receipt path:

```sh
ssh gdc-node4 python3 - a --expected-ms 1000 --target-ms 20000 --apply --receipt /srv/dai/broker-tests/v6-a/first-token-tuning.json < broker-ops/v6-first-token-tuning.py
```

Rollback only the changed field, using the recorded previous value and a new
receipt; do not restore the entire settings object over concurrent changes:

```sh
ssh gdc-node4 python3 - a --expected-ms 20000 --target-ms 1000 --apply --receipt /srv/dai/broker-tests/v6-a/first-token-rollback.json < broker-ops/v6-first-token-tuning.py
```

The helper fails on a stale expected value, existing receipt, or readback
mismatch. A transport error after POST has an uncertain outcome: read back
before retrying. Do not share receipts publicly without inspection.

For release `lab-gonka-pr-1792-bce2388c4df1`, the configured floor applies to
the fallback delay; a learned p95 from performance samples takes precedence.
This is not a guaranteed minimum for every request. Do not erase performance
history to manufacture a passing test. Validate JSON/SSE and a bounded
five-minute load outside PoC, with fresh escrow and unchanged epoch, before
claiming improvement. Keep the control gateway unchanged until that result.

The correction in [Gonka PR 2008](https://github.com/gonka-ai/gonka/pull/2008)
also clamps the learned-p95 delay to this configured minimum. Verify the exact
published corrected image before applying a larger floor; changing the setting
on an older image does not correct that path. The floor does not extend the
independent receipt deadline or guarantee that a host produces a response.
Retain both failed and successful load evidence.

Run `make -C broker-ops test-v6-first-token-tuning` for offline contract checks.
