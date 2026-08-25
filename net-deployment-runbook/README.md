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
