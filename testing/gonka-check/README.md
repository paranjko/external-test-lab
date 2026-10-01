# gonka-check

Smoke checks for Gonka inference through the public DevNet gateway, chain checks, a readiness watch and an escrow slot study from public chain reads.
Python 3.10+, standard library only, nothing to install.

## Run

```sh
bin/gcheck plan                   # target, budget and checks; no network
bin/gcheck run --dry-run          # GET only: READY or BLOCKED with reasons
bin/gcheck run --profile smoke    # at most 2 completions, inside the send window
bin/gcheck run --profile chain    # GET only, no key: chain and public node checks
bin/gcheck watch --duration 3600  # GET only: readiness samples and a per-epoch summary
bin/gcheck selftest               # unit tests against a local fake gateway
```

`--preset devnet-a` and `--preset devnet-b` target the DevShard gateways at `/a` and `/b` directly: no admission proxy, no health receipt, no `fence_audit`, and the send window follows the chain's PoC cycle.

The API key is read from `~/.config/gonka-check/<preset>.key` (mode 0600) and is sent only with completion POSTs.
Runs are written to `~/.local/share/gonka-check/runs/<run>/` (`manifest.json`, `records.jsonl`, `summary.json`).
The per-epoch budget ledger is `~/.config/gonka-check/ledger.jsonl`.

On macOS with the python.org build, set `SSL_CERT_FILE=/etc/ssl/cert.pem` if HTTPS fails certificate verification.

## Checks

| Check | Maps to | Requests | Pass |
|---|---|---|---|
| `model_served` | REG-11 | `GET /v1/models` | the preset model is listed |
| `canary` | SMK-06 | 1 POST | "7 + 5" answers 12; `finish_reason` and `usage` present |
| `floor64` | REG-15 | 1 POST | `max_tokens: 1` yields 64 completion tokens, `finish_reason: length` |
| `fence_audit` | SMK-05, REG-13 | none | `X-GDC-*` heights ordered, permit height inside the proxy fence |
| `chain_advances` | SMK-01 | GET | chain height grows within `chain_advance_wait_s` |
| `nodes_at_tip` | SMK-02 | GET | every `node_rpcs` entry answers, is not catching up, lags at most `node_max_lag_blocks` |
| `epoch_state` | SMK-04 | GET | height, epoch start and the confirmation PoC event agree; a snapshot |

## Watch

`watch` samples every `watch_interval_s` (10 s): chain height, the confirmation PoC event, `/v1/status` and the health receipt.
Samples go to `samples.jsonl`; `summary.json` gives per epoch the ready share of the send window, confirmation PoC offsets and health reasons.
It stops after `--duration` seconds or `--epochs` complete epochs; it exits `0`, or `2` when no sample could be read.

## Escrow slots

Replays how the chain draws escrow slots by weight and simulates other group sizes. Only `snapshot` reads the network.

```sh
bin/gcheck escrow plan --source mainnet                  # what a snapshot reads and how long; no network
bin/gcheck escrow snapshot --source mainnet --dry-run    # a few reads: READY or BLOCKED
bin/gcheck escrow snapshot --source mainnet              # weights and the real escrows of the effective epoch
bin/gcheck escrow report <run>/snapshot.json --out DIR   # replay, 1000 escrows per model at G=16,32,64, report.md, charts, CSV
```

`verify` replays the real escrows only; `simulate` writes the CSV files without the report.
Checks: `weights` (weights sum to `total_weight`, same effective epoch at start and end), `escrows` (every escrow id of the epoch was read), `slots_replay` (the port matches every real escrow of the snapshot), `slots_source` (with `--slots-go`, the ported file's sha256), `slot_share` and `inclusion` (simulated counts within 5 sigma + 1 of the formulas).

## Group size change

Evidence and verdicts for a DevNet run that changes `group_size` within one epoch. The run itself (gateway admin calls, proposals, votes) is outside gcheck; these commands only read.

```sh
bin/gcheck escrow preflight --gateway a                          # READY or BLOCKED: group_size, free escrow places, gateway, voters
bin/gcheck escrow record --a ID --b ID --change N --rollback N   # evidence read at the heights where each value applies
bin/gcheck escrow verdict <run>                                  # report.md and verdicts.json; no network
```

Checks: `a_created`, `g_changed`, `b_created`, `a_settled_after`, `own_group` (quorum and fee split by the escrow's own slots), `same_epoch`, `accounting` (payouts, refund, coin balances), `rolled_back`. With `--a` alone it checks a control run.

`scenarios/control-187.sh` is that control run on gateway A at group size 5: one escrow created through the gateway admin API on the gateway host, two requests into it, a manual settlement in the same epoch, then `escrow record` and `verdict`. Without `--run` it only reads.
`scenarios/run-187.sh` is the live run: escrow A at 5 slots, the 5 → 9 proposal, escrow B at 9 slots, both settled by hand in the same epoch, then the 9 → 5 rollback. The proposals need validator keys the script does not hold: it writes each proposal file, says when to submit it and waits for `group_size`.

## Safety

- `run` and `watch` reach only `https://api.gonka-dev.net` and its gateways `/a` and `/b`, the health receipt on `https://gonka-dev.net` and GET on `https://nodeN.gonka-dev.net/chain-rpc`, or a loopback fake; `/status/gateway/*`, `/v1/admission-status` and gateway admin paths (`/v1/admin`, `/v1/debug`, `/v1/finalize`, `/v1/state`, `/debug/pprof`, also under `/devshard/<id>`) are never requested.
- `watch` samples at most every 5 s against a public target; `--profile chain` and `watch` read no key.
- One request in flight, one lock per machine, sends at least 2 blocks apart at epoch offset `safe_start+1 .. epoch_length-20`.
- `escrow preflight` and `escrow record` read DevNet the same way, GET only, and never call gateway admin paths.
- `scenarios/` is not gcheck: with `--run` a scenario sends transactions through the gateway admin API; the gateway keys are read on the gateway host and reach curl on stdin.
- `escrow snapshot` reads public chain data under `/chain-api/` and `/chain-rpc/` of `https://node3.gonka.ai` (mainnet) or `https://api.gonka-dev.net` (DevNet): GET only, no key, one request per second on mainnet and every 2 s on DevNet, at most `--max-requests` (4000) per run, one snapshot per machine.
- `X-Request-Deadline-Ms` is absolute: now + 60 s. A POST is never retried.
- At most 4 POST per run and per epoch; the ledger entry is written before the send.
- The run stops on a suspected permit leak (408 with a permit height and no dispatch height), on a failed dispatch, on a reply without admission headers (except from `/a` and `/b`), on an unknown outcome, on a proxy protocol misconfiguration, and after two pre-dispatch rejections.

## Exit codes

`0` PASS · `1` FAIL · `2` INCONCLUSIVE · `3` BLOCKED · `4` stopped by a guard or refused.
`run --dry-run` and `escrow snapshot --dry-run` exit `0` when READY and `3` when BLOCKED.
