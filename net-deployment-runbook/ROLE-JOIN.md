# JOIN: add a Host

JOIN is for an operator who owns the target Host. The operator creates and
keeps that Host's keys. No Genesis secrets or manual approval are required.

## Prerequisites

Add the SSH alias:

```bash
cat >> ~/.ssh/config <<'EOL'
Host <ssh-alias>
  HostName <IP>
  User root
  Port <PORT> # optional
EOL
```

## Join

```bash
./gdc.sh host join [--public-host <dns-name>] <ssh-alias> [<gpu-ssh-alias>]
```

The command imports the public Genesis data, detects the target DNS and GPU,
creates the Host's accounts, installs the pinned release, synchronizes the
node, registers it and waits for `ACTIVE`. No configuration file is required.
When the optional GPU SSH alias is provided, the command qualifies that GPU,
configures the validator to use it and attaches its MLNode automatically.

`ACTIVE` is an onboarding state, not a successful validator join. The command
continues through a bounded four-epoch acceptance window and returns
`JOIN_PASS` only after a chain-recorded exact runtime, positive PoC weight,
positive consensus voting power and an authenticated gateway regression. Give
the joining operator a separate client credential for that final regression:

```bash
export GDC_JOIN_GATEWAY_CLIENT_KEY_FILE=/absolute/path/to/client-key
chmod 600 "$GDC_JOIN_GATEWAY_CLIENT_KEY_FILE"
GDC_OPERATOR_MODE=external-operator ./gdc.sh host join <ssh-alias>
```

The file is read locally and is never copied into the runbook state, logs or
receipt. If it is not available or is not mode `0600`, the result is
`BLOCKED`, not success. A reachable chain that has not produced the required
epoch evidence before the deadline is `INCONCLUSIVE`.

For an independent Gate A proof, run the join from this operator's clean
checkout and separate `GDC_HOME`, set `GDC_OPERATOR_MODE=external-operator`,
then share only the resulting `join-acceptance-<ssh-alias>/` evidence bundle.
Its `receipt.json` contains public chain-verifiable identifiers and no
mnemonic, keyring, client credential or private account material.

The receipt also records the epoch and reconciled positive PoC weight that
made the bounded acceptance window eligible. A Gate A observer rejects a
receipt without this evidence or with a committed total that differs from the
accepted weight sum.

If the SSH alias uses an IP address and DNS cannot be detected automatically,
pass the node's public DNS name explicitly:

```bash
./gdc.sh host join --public-host node3.gonka-dev.net gdc-node3
```

## Host lifecycle

```bash
./gdc.sh host verify <ssh-alias>
./gdc.sh host stop <ssh-alias>
./gdc.sh host start <ssh-alias>
./gdc.sh host reset <ssh-alias>
./gdc.sh host join [--public-host <dns-name>] <ssh-alias> [<gpu-ssh-alias>]
```

To reuse a previously validated model installation without running the ML
qualification probe again:

```bash
./gdc.sh host join --skip-qualification [--public-host <dns-name>] <ssh-alias> [<gpu-ssh-alias>]
```

`host reset` removes only runbook-managed services and state for that Host.
Its chain account remains owned by the operator.

If the GPU runs on another machine, see `host ml-attach` in
[ROLE-HOST.md](ROLE-HOST.md).

## Post-merge user-test handoff

After this JOIN milestone is merged, test the two reserved Hosts from a fresh
checkout of the then-current `main`, each with its own operator-owned home and
separately delivered scoped client credential. Do not reuse a Genesis mnemonic,
validator keyring, gateway creator key or bot credential.

```bash
git clone https://github.com/paranjko/external-test-lab.git /absolute/operator/external-test-lab
cd /absolute/operator/external-test-lab/net-deployment-runbook
git switch main
export GDC_HOME=/absolute/operator/gdc-home
export GDC_DATA_ROOT="$GDC_HOME"
export GDC_OPERATOR_MODE=external-operator
export GDC_JOIN_GATEWAY_CLIENT_KEY_FILE=/absolute/operator/gateway.join-client-key
chmod 600 "$GDC_JOIN_GATEWAY_CLIENT_KEY_FILE"
```

`gdc-node2` is the colocated Network Node and local GPU exercise:

```bash
./gdc.sh --release v2026.07.23 host join --public-host node2.gonka-dev.net gdc-node2
```

`gdc-node4` plus `gdc-node4-ml` is the split Network Node/MLNode exercise:

```bash
./gdc.sh --release v2026.07.23 host join --public-host node4.gonka-dev.net gdc-node4 gdc-node4-ml
```

Keep the resulting `runs/<run-id>/join-acceptance-<host>/receipt.json` and
`verdict.md`. `JOIN_PASS` is the only success result; `ACTIVE` alone means the
Host is still waiting for the stated chain evidence. Neither command clears a
model cache.
