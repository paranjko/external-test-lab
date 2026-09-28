# End-to-end inference testing on Community DevNet

`testing/gonka-check` (command `gcheck`) checks inference through the public gateway `https://api.gonka-dev.net`. This guide takes a clean checkout to a dry run and a first smoke run.

## Requirements

- Python 3.10 or newer; standard library only, nothing to install
- HTTPS access to `api.gonka-dev.net` and `gonka-dev.net`
- a client API key from the DevNet Telegram key bot ([devnet/architecture.md](../devnet/architecture.md))

## Setup

```sh
git clone https://github.com/paranjko/external-test-lab.git
cd external-test-lab/testing/gonka-check
bin/gcheck selftest
```

`selftest` runs the unit tests against a local fake gateway and sends nothing to the network.

Store the key outside the repository, readable only by you:

```sh
(umask 077 && mkdir -p ~/.config/gonka-check && cat > ~/.config/gonka-check/devnet.key)
```

Paste the key, press Enter, then Ctrl-D.

## Dry run

```sh
bin/gcheck plan
bin/gcheck run --dry-run
```

`plan` prints the target, the budget and the checks without network access. `run --dry-run` sends GET requests only and prints `READY` (exit `0`) or `BLOCKED` (exit `3`) with one line per reason. While the chain or the gateway is not ready, it polls every 8 s for up to `--wait` seconds (default 420); `--wait 0` answers after one poll.

Each run writes `manifest.json`, `records.jsonl` and `summary.json` to `~/.local/share/gonka-check/runs/<run>/`.

## First smoke run

Only after a dry run reports `READY`:

```sh
bin/gcheck run --profile smoke
```

The run sends at most two completions inside the send window and prints one verdict per check. Exit codes: `0` PASS, `1` FAIL, `2` INCONCLUSIVE, `3` BLOCKED, `4` stopped by a guard. Checks, guards and limits: [gonka-check/README.md](gonka-check/README.md).

## Troubleshooting

- `CERTIFICATE_VERIFY_FAILED` with the python.org build on macOS: set `SSL_CERT_FILE=/etc/ssl/cert.pem` or run `Install Certificates.command` once.
- `key: key_missing` or `key: key_permissions`: the key file is absent or not mode `0600`.
- `lock: another live run holds …`: one live run per machine at a time.
