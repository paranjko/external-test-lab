# gonka-check

Smoke checks for Gonka inference through the public DevNet gateway, chain checks and a readiness watch.
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

`--preset devnet-a` and `--preset devnet-b` target the DevShard gateways at `/a` and `/b` directly: no admission proxy, no health receipt; `status_gate` takes the place of `fence_audit`.

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
| `fence_audit` | SMK-05, REG-13 | none | proxy path: `X-GDC-*` heights ordered, permit and dispatch heights inside the proxy fence |
| `status_gate` | SMK-05 | none | `/a`, `/b`: each completion follows a routable `/v1/status` and is sent inside the PoC fence |
| `chain_advances` | SMK-01 | GET | chain height grows within `chain_advance_wait_s` |
| `nodes_at_tip` | SMK-02 | GET | every `node_rpcs` entry answers, is not catching up, lags at most `node_max_lag_blocks` |
| `epoch_state` | SMK-04 | GET | height, epoch start and the confirmation PoC event agree; a snapshot |

## Watch

`watch` samples every `watch_interval_s` (10 s): chain height, the confirmation PoC event, `/v1/status` and the health receipt.
Samples go to `samples.jsonl`; `summary.json` gives per epoch the ready share of the send window, confirmation PoC offsets and health reasons.
It stops after `--duration` seconds or `--epochs` complete epochs; it exits `0`, or `2` when no sample could be read.

## Safety

- `run` and `watch` reach only `https://api.gonka-dev.net` and its gateways `/a` and `/b`, the health receipt on `https://gonka-dev.net` and GET on `https://nodeN.gonka-dev.net/chain-rpc`, or a loopback fake; `/status/gateway/*`, `/v1/admission-status` and gateway admin paths (`/v1/admin`, `/v1/debug`, `/v1/finalize`, `/v1/state`, `/debug/pprof`, also under `/devshard/<id>`) are never requested.
- `watch` samples at most every 5 s against a public target; `--profile chain` and `watch` read no key.
- One request in flight, one lock per machine, sends at least 2 blocks apart at epoch offset `safe_start+1 .. epoch_length-20`; the height is read again right before each send.
- `X-Request-Deadline-Ms` is absolute: now + 60 s. A POST is never retried.
- At most 4 POST per run and per epoch; the ledger entry is written before the send.
- The run stops on a suspected permit leak (408 with a permit height and no dispatch height), on a failed dispatch, on a reply without admission headers (except from `/a` and `/b`), on an unknown outcome, on a proxy protocol misconfiguration, and after two pre-dispatch rejections.

## Exit codes

`0` PASS · `1` FAIL · `2` INCONCLUSIVE · `3` BLOCKED · `4` stopped by a guard or refused.
`run --dry-run` exits `0` when READY and `3` when BLOCKED.
