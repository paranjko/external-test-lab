# Workload observation adapter contract

`net-deployment-runbook/04-ops/devshard-observe.py` converts fresh, retained
readbacks into the workload engine's admission/accounting observation. It is
a library, not yet a connected operator command. Its offline tests do not
prove network collection, a complete workload run or release acceptance.

The adapter supplies `read(kind, subject, deadline)`. Every result contains
`observed_at` (Unix seconds when the source was observed), `ok` and `value`.
Failed results retain their error/response instead of returning an empty
successful value. The collector calls `retain` before validating each result;
its final observation binds the canonical source receipts by SHA-256.
Collection has one absolute five-second deadline, not five seconds per source.
Re-reading an old file must not give its contents a new observation timestamp.

| Source | Subject | Required value |
|---|---|---|
| `status` | none | RPC `/status`, including chain identity, synchronization state and height |
| `epoch` | none | DAPI `/v1/epochs/latest`, including height, epoch stages, phase and explicit confirmation-PoC state |
| `blocks` | current height | Twenty-one consecutive RPC block responses, oldest first, ending at the observed height |
| `params` | none | Current inference params object, including `devshard_escrow_params` |
| `hosts` | none | Map from escrow slot participant to independently observed execution/model capacity evidence |
| `gateway` | A or B | Authenticated `/v1/admin/devshards`, including complete settings, runtime and model capacity |
| `escrow` | registered ID | Official chain `show-devshard-escrow` result, including `found` and the escrow |

Use the same verified chain endpoints and operator identities throughout a
run. Epoch and RPC positions may differ by at most two blocks. Real block
timestamps must be present and strictly increase; a fresh HTTP response does
not make an old chain head current. The latest block must not be in the future
or older than two observed maximum block intervals (with a five-second floor).
PoC, confirmation PoC, unavailable capacity or busy runtime remain quiet
observations. Unknown identity, policy or source freshness is a refusal.

For each Host slot, `hosts` supplies `model`, `artifact_sha256`,
`context_tokens`, `context_source` and the SHA-256 of its retained readback
receipt as `receipt_sha256`. The adapter must actually inspect the running
Host executable and serving model, retain that evidence and bind it to the
slot. An expected artifact hash, desired model configuration, gateway output
cap or an unverified operator assertion is not a Host observation. The library
checks the resulting values and receipt-binding shape; it cannot establish
the provenance of evidence invented by an adapter.

Real serving capacity uses `context_source=serving-runtime`. The distinct
`mock-unbounded` source is accepted only with `environment_kind=lab-mock` and
the fixed isolated chain ID. It describes a source-verified mock without an
input-context restriction, not a real ML context measurement. The mock chain's
zero block timestamps and mock DAPI's static epoch response cannot be passed
off as real block/phase observations; an isolated adapter still needs an
explicit, separately evidenced observation path for those sources.

The first implementation selects exactly one registered escrow per gateway.
It does not silently pick another escrow or mint a replacement. Both creator,
model and route bindings must match; automatic rotation/settlement remain off.
`nonce` and `balance` alone may be absent because the pinned gateway omits zero
values for those fields. Missing in-flight or cleanup counters are errors.

The conservative request reservation is the whole currently observed balance
and all remaining nonces below the chain's maximum of 20000. This is a risk
reservation, not an intended charge or permission to fund anything. The engine
still requires response/escrow/nonce correlation, observed balance accounting,
bounded drain and the persistent campaign spending/attempt limits. An
uncertain result keeps its reservation and is never automatically retried.

Run the source-shape and refusal contracts with:

```bash
make -C net-deployment-runbook test-devshard-observe
```

This target is also included in `test-devshard-workload` and `make test`.
