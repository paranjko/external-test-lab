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

Setup network:

```bash
git clone git@github.com:paranjko/external-test-lab.git
cd external-test-lab/net-deployment-runbook

gdc --release v2026.07.23 genesis gdc-node0
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
| GATEWAY | [ROLE-GATEWAY.md](ROLE-GATEWAY.md) | gateway runtime, escrow creator and client-key pool | Host governance keys or public-observation administration |
| DEVELOPER | [ROLE-DEVELOPER.md](ROLE-DEVELOPER.md) | an application and its client API key | any infrastructure or signer credential |

`OPS` is an observation service, not a network controller, node collectors are
installed by `GENESIS` or the relevant `JOIN` operator, `OPS` scrapes published
endpoints and the website reads live chain participants, a down endpoint is
shown as down, a configured inventory entry is never treated as evidence that
it joined the chain
