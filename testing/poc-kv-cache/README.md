# PoC v2 and the KV cache mode

Does PoC v2 of Qwen2.5-7B pass on one ML node with `--kv-cache-dtype fp8`, with `auto`, and after the switch back? The node generates PoC vectors for fixed inputs and validates them itself, in every mode, against the vectors of every mode run so far.

| File | What |
|---|---|
| `run-mode.sh` | One mode: records the vLLM launch arguments, attention backend, image and GPU; generates 32 vectors with `make_artifact.py`; validates each artifact of the run with `validate.py`, all 32 nonces in one batch and an evenly spread sample of 20; compares the vectors with the earlier modes |
| `compare-vectors.py` | L2 distance between two artifacts per nonce, raw and on unit vectors; `--subset` cuts an artifact to an evenly spread sample |

`make_artifact.py` and `validate.py` are the scripts of `mlnode/packages/benchmarks/scripts/poc_validation/` in gonka-ai/gonka. Thresholds are the chain `stat_test` of the model: `dist_threshold` 0.4, `p_mismatch` 0.1. `fraud_threshold` is 0.01, the ML node default; each report keeps `p_value`.

## Run

Linux host with `ssh` to the ML host, Python 3 with `requests`, a gonka-ai/gonka checkout.

1. One epoch before the run, disable the ML node in the API of its participant: `POST /admin/v1/nodes/<id>/disable`. From the next epoch it takes no inference, PoC or confirmation PoC.
2. In that next epoch, run the modes in order. For each mode, post the whole node record with the new model arguments to `POST /admin/v1/nodes`, and wait until vLLM serves again. A disabled node takes the new arguments too. Each run prints the launch arguments it found: go on only if they match the mode.

| Mode | Model arguments |
|---|---|
| `1-fp8` | the original record: `--kv-cache-dtype fp8` |
| `2-auto` | `--kv-cache-dtype auto` |
| `3-auto-flashinfer` | `--kv-cache-dtype auto --attention-backend FLASHINFER` |
| `4-fp8` | the original record again |

```bash
git clone https://github.com/gonka-ai/gonka.git && git -C gonka checkout 9e663130755ec60cd8c3f2be24c328353883a06c
export GONKA_DIR=$PWD/gonka
testing/poc-kv-cache/run-mode.sh <ssh host> 1-fp8 <run directory>
```

3. After `4-fp8`, check that the record equals the original, then enable the node: `POST /admin/v1/nodes/<id>/enable`. An enabled node takes requests at once and joins the next PoC, so enable at least 15 minutes before it; otherwise enable in the epoch after.

The API polls the node every minute and stops PoC work it did not start. A cut generation or validation shows as an error in the run log; run that mode again under a new label.

Mode 3 keeps the attention backend that vLLM picks for `fp8` while the cache is `auto`: it tells a cache effect from a backend effect.

## Results

`<run>/<mode>/validate-<from>-<all|sample>/validate_report.txt` has `n_mismatch`, `p_value` and `fraud_detected` for the vectors of mode `<from>` validated in `<mode>`. `<run>/<mode>/compare-<from>.txt` has the distances between the two modes. `node.txt` holds the launch arguments, and `SHA256SUMS` covers each mode.
