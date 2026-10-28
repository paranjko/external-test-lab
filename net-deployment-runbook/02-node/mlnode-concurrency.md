# MLNode concurrency: JOIN and updates

Fresh `gdc host join --model=MODEL --public-host HOST SSH_ALIAS` selects the network model profile and records its concurrency in the generated JOIN profile before rendering `node-config.json`

| Model | DAPI `max_concurrent` | vLLM `--max-num-seqs` |
|---|---:|---:|
| `Qwen/Qwen3-4B-Instruct-2507` | 16 | 1 |
| `Qwen/Qwen2.5-7B-Instruct` | 32 | 32 |

`MLNODE_MAX_CONCURRENT` in the model lock sets DAPI admission independently of `MLNODE_MAX_NUM_SEQS`, which sets the engine's sequence limit, a higher DAPI limit can admit queued work and does not increase GPU capacity

JOIN retains `mlnode_max_concurrent` in its hashed profile, replay uses the retained value, older profiles without this field retain their original `mlnode_max_num_seqs` fallback

## Change an existing MLNode

JOIN installs the Bash helper beside `node-config.json`, run it on the Host owning the DAPI record, including for a remote MLNode

```bash
curl -fsS http://127.0.0.1:9200/admin/v1/nodes |
  jq '.[] | .node | {id, host, max_concurrent}'

sudo bash /srv/dai/deploy/mlnode-max_concurrent.sh 'EXACT_MLNODE_ID' 16
```

The helper saves `before.json`, creates `after.json` with only the selected limit changed, POSTs that file, verifies API readback, then updates the matching local bootstrap record without replacing its bind-mounted inode

Private backups are kept in `/srv/backup/mlnode-concurrency.XXXXXX`, IDs containing `/` are never used as file paths, `GDC_MLNODE_BACKUP_DIR` can select another backup directory

An ordinary DAPI restart retains its database, GDC start also POSTs `node-config.json`, updating both stores prevents the old file from restoring an earlier limit

API and file writes are not atomic, on failure inspect the saved request, response, live API and local file before retrying, the command does not retry POST or claim rollback, do not run other API or file writers concurrently

To undo a successful update, read the old limit from `before.json` and invoke the helper with that value

A completely new JOIN uses the selected profile defaults, arbitrary tuning of a previous installation is not automatically transferred, retain the tuned file in recovery material or encode the chosen default in the model profile before rebuilding

The defaults are deployment choices, not a measured capacity guarantee, qualify throughput, queueing, latency and errors for the intended hardware and workload
