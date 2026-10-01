# gonka-check

Smoke checks for Gonka inference through the public DevNet gateway, chain checks, a readiness watch, an escrow slot study from public chain reads and a gateway load measurement.
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

The API key is read from `~/.config/gonka-check/devnet.key` (mode 0600) and is sent only with completion POSTs.
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

## Gateway load

Runs the upstream DevShard gateway session with G in-process hosts and the stub model, one request at a time, and measures every 1,000 nonces. Needs `go` 1.25.9 or newer, or Docker.

```sh
bin/gcheck gateway-load plan                    # source tag and commit, runner, what is written
bin/gcheck gateway-load stress --dry-run        # fetch the source and build the test: READY or BLOCKED
bin/gcheck gateway-load stress                  # G=16,32,64, 19,800 nonces each: report.md, checkpoints.csv, charts
```

The source is `gonka-ai/gonka` at `devshard/v5.0.2`, pinned to its commit; gcheck adds one test file to that checkout.
The test is built once and runs as a plain binary, capped at 75% of the machine memory by default (`--memory GB`, `0` for no cap).
Gateway time per nonce is the wall time minus the time inside the hosts. Each group size is one check: `PASS` when every nonce, the finalization and the settlement check pass.

## Safety

- `run` and `watch` reach only `https://api.gonka-dev.net`, the health receipt on `https://gonka-dev.net` and GET on `https://nodeN.gonka-dev.net/chain-rpc`, or a loopback fake; `/status/gateway/*` and `/v1/admission-status` are never requested.
- `watch` samples at most every 5 s against a public target; `--profile chain` and `watch` read no key.
- One request in flight, one lock per machine, sends at least 2 blocks apart at epoch offset `safe_start+1 .. epoch_length-20`.
- `escrow snapshot` reads public chain data under `/chain-api/` and `/chain-rpc/` of `https://node3.gonka.ai` (mainnet) or `https://api.gonka-dev.net` (DevNet): GET only, no key, one request per second on mainnet and every 2 s on DevNet, at most `--max-requests` (4000) per run, one snapshot per machine.
- `gateway-load` reaches only GitHub for the source and the Go module proxy; it sends nothing to any Gonka network.
- `X-Request-Deadline-Ms` is absolute: now + 60 s. A POST is never retried.
- At most 4 POST per run and per epoch; the ledger entry is written before the send.
- The run stops on a suspected permit leak (408 with a permit height and no dispatch height), on a failed dispatch, on a reply without admission headers, on an unknown outcome, on a proxy protocol misconfiguration, and after two pre-dispatch rejections.

## Exit codes

`0` PASS · `1` FAIL · `2` INCONCLUSIVE · `3` BLOCKED · `4` stopped by a guard or refused.
`run --dry-run` and `escrow snapshot --dry-run` exit `0` when READY and `3` when BLOCKED.
