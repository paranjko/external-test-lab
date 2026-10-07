# Public two-gateway document workload

Run from outside the stand using explicit TLS A/B client base URLs. This
command reuses the frozen 20-case public-document corpus, response validator,
and single-dispatch transport. It does not deploy, fund, mint, settle, or retry.
It checks the Community DevNet identity and approved official 5.0.2 archive.

Create a private JSON configuration with `endpoints`, `secret_files`, and
`creators` objects containing distinct `A` and `B` entries, plus `chain_base`
and an absolute private `lock_directory`. Endpoints are HTTPS bases without
`/v1`, query strings, or embedded credentials. `secret_files` refer to
mode-0600 files containing only one client token. Do not copy creator/admin
credentials to the client machine; full gateway environment files are refused.
The chain base exposes `/chain-rpc/status` and `/chain-api/` read routes.
Each client base exposes `/v1/status` and `/v1/admission-status` in addition to
completions. All invocations for the same endpoints must share the lock directory.

Use a mode-0700 evidence parent and a new campaign path:

```bash
python3 04-ops/devshard-public-workload.py --config /private/client-workload.json \
  --campaign /private/evidence/campaign-01 --run 1 --wall-seconds 1200
python3 04-ops/devshard-public-workload.py --config /private/client-workload.json \
  --campaign /private/evidence/campaign-01 --run 2 --wall-seconds 1200
```

Each invocation sends 20 requests per gateway, serially, with opposite JSON/SSE
modes on the second pass. Each request has a 60-second deadline and 128 output
tokens. The existing corpus hashes and payloads stay unchanged. Admission and
protocol-phase observations precede dispatch. The second pass requires a
successful first pass, and a used run directory is never overwritten or resumed.
An interrupted or failed request requires investigation, not automatic replay.

`events.jsonl` retains preflight, chain escrow ownership, exact intent, response
bytes, and terminal evidence. `summary.json` reports response-shape and
own-escrow attribution, latency, and observed SSE first-content timing. There
are no monetary GNK caps. Before/after wallet balances include background
rotation; they are not a fabricated per-request charge. Admin/accounting stay
private. A PASS here still requires separate review against the corpus factual
checklists, runtime artifact evidence, and the remaining issue criteria.

Run local contracts with `make test-devshard-public-workload` and
`make test-devshard-transport`.
