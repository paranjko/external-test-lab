# gonka-check

Smoke checks for Gonka inference through the public DevNet gateway.
Python 3.10+, standard library only, nothing to install.

## Run

```sh
bin/gcheck plan                   # target, budget and checks; no network
bin/gcheck run --dry-run          # GET only: READY or BLOCKED with reasons
bin/gcheck run --profile smoke    # at most 2 completions, inside the send window
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

## Safety

- Only `https://api.gonka-dev.net` or a loopback fake; `/status/gateway/*` and `/v1/admission-status` are never requested.
- One request in flight, one lock per machine, sends at least 2 blocks apart at epoch offset `safe_start+1 .. epoch_length-20`.
- `X-Request-Deadline-Ms` is absolute: now + 60 s. A POST is never retried.
- At most 4 POST per run and per epoch; the ledger entry is written before the send.
- The run stops on a suspected permit leak (408 with a permit height and no dispatch height), on a failed dispatch, on a reply without admission headers, on an unknown outcome, on a proxy protocol misconfiguration, and after two pre-dispatch rejections.

## Exit codes

`0` PASS · `1` FAIL · `2` INCONCLUSIVE · `3` BLOCKED · `4` stopped by a guard or refused.
`run --dry-run` exits `0` when READY and `3` when BLOCKED.
