# Community DevNet runbook

## TLDL

Add the SSH alias:

```bash
cat >> ~/.ssh/config <<'EOL'
Host <ssh-alias>
  HostName <IP>
  User root
  Port <PORT> # optional
EOL
```

To add one independently operated Host, use the [JOIN guide](ROLE-JOIN.md).
Its complete interface is one optional local state directory and one command:

```bash
git clone https://github.com/paranjko/external-test-lab.git
alias gdc="$PWD/external-test-lab/net-deployment-runbook/gdc.sh"

# Local runtime data defaults to `GDC_HOME=$HOME/.gdc-data`
# Optional: choose a different local data directory
# export GDC_HOME=/absolute/path

gdc host join [--public-host <dns-name>] <ssh-alias> [<gpu-ssh-alias>]
```

For JOIN, use a lowercase SSH alias beginning with a letter or digit and
containing only lowercase letters, digits, `_`, or `-`.

## Local operator requirements

The supported macOS/Linux Host-operator contract requires stock command-line
tools, `Bash >= 5`, and `jq >= 1.6`. It covers `host join`, restore and plan
variants, `host backup`, and local report generation. `ssh` must be configured
for the Linux Host being managed. Docker, Python, Node.js, GNU coreutils, GNU
findutils, GNU sed, `flock`, `getent`, and GNU `timeout` are not local runtime
prerequisites for those commands. Other runbook command families remain
Linux-oriented and are outside this portability promise.

macOS ships Bash 3.2, which is intentionally unsupported. Install the two
required dependencies through Homebrew:

```bash
brew install bash jq
```

`gdc.sh` finds the brewed Bash automatically in `PATH`, `/opt/homebrew/bin`,
or `/usr/local/bin`. `gh` is optional and is needed only when publishing a
sanitized report with `gdc report github`. This contract is release evidence,
not a promise made by an in-progress checkout: it applies only after the
portable-operator CI gate passes for the exact release.

Check the required local capability before beginning an operation:

```bash
bash --version
jq --version
```

GDC serializes lifecycle writes for one operator state directory with an
atomic directory lock. A concurrent command fails without mutating state and
prints the lock location. Inspect it with:

```bash
gdc host lock inspect <ssh-alias>
```

GDC never deletes an existing lock automatically. If a process was interrupted,
first inspect the owner record, confirm that its PID and command are no longer
active, retain it with the incident evidence, and only then remove the owner
file and empty lock directory manually. Do not clear a lock for an active or
unknown owner.

Setup network:

```bash
gdc --release v2026.07.23 genesis gdc-node0 --public-edge gdc-node4
gdc host join gdc-node1
gdc host join gdc-node2
gdc host join gdc-node3
gdc host join gdc-node4 gdc-node4-ml # node net only + gpu net
```

## Overview

This package recreates a Gonka Community DevNet for release and
distributed-behaviour testing, the clean baseline is `v2026.07.23` with
chain ID `gonka-devnet-community`

Choose the document for your role, each role has separate authority and keeps
only the credentials it actually needs

| Role | Document | Owns | Must not own |
| --- | --- | --- | --- |
| OPS | [ROLE-OPS.md](ROLE-OPS.md) | [gonka-dev.net](https://gonka-dev.net/), Prometheus and the reference Telegram inference consumer | Genesis mnemonic, validator keys, Host accounts, gateway creator/admin keys |
| GENESIS | [ROLE-GENESIS.md](ROLE-GENESIS.md) | first validator, chain genesis, public bootstrap, faucet and initial access | later Host private keys |
| JOIN | [ROLE-JOIN.md](ROLE-JOIN.md) | one validator, its accounts, identity and ML permission | Genesis and other Host secrets |
| HOST | [ROLE-HOST.md](ROLE-HOST.md) | an active Host, its Network Node, MLNode and governance key | another Host's keys or OPS credentials |
| UPGRADE | [ROLE-UPGRADE.md](ROLE-UPGRADE.md) | one Host's immutable target preflight and activation watch | another Host's SSH or keyring |
| GATEWAY | [ROLE-GATEWAY.md](ROLE-GATEWAY.md) | gateway runtime, escrow creator and client-key pool | Host governance keys or public-observation administration |
| DEVELOPER | [ROLE-DEVELOPER.md](ROLE-DEVELOPER.md) | an application and its client API key | any infrastructure or signer credential |

`OPS` is an observation service, not a network controller, node collectors are
installed by `GENESIS` or the relevant `JOIN` operator, `OPS` scrapes published
endpoints and the website reads live chain participants, a down endpoint is
shown as down, a configured inventory entry is never treated as evidence that
it joined the chain

## Report a failed command to GitHub

After a failed `gdc` command, you can prepare a support report without
re-running the failed operation:

```bash
gdc report github
```

The command creates a local, permission-restricted report directory and a
sanitized archive. It collects the failed command's recorded stage and exit
status, runbook identity, selected non-secret runtime versions, UTC time, and
bounded terminal diagnostics only when they pass the public-safety checks. It
does not include raw logs, `.env` files, keys, keyrings, backups,
credentials, cookies, request content, or arbitrary files from your operator
directory.

The report is intended as evidence for maintainer review – it does not assign
root cause or claim a product defect. Before any GitHub write it shows the
exact public destination, the archive state, and the full Markdown body. The
default response is not to publish. You can create a new issue, add a comment
only to one of your own open issues, or cancel; cancellation always retains
the local report.

GitHub issues are public in this repository. The complete report is sent as
inline Markdown, so it remains useful with the stable GitHub CLI. Raw logs are
never uploaded. The local archive is attached only when the installed CLI
explicitly supports a compatible attachment option; otherwise it remains
local. When attachment is available, it is the sanitized archive rather than
the raw run log. If `gh` is missing, not authenticated, lacks permission, or
cannot reach GitHub, the command explains the next local recovery step and
keeps the report and archive.
