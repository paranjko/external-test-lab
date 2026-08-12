# JOIN: add a Host

JOIN is a single command for the operator who owns the target Host. The
operator creates and keeps the Host's accounts and identities; the command
imports only the public Genesis bootstrap.

## Join

```bash
cat >> ~/.ssh/config <<'EOL'
Host gdc-node3
  HostName <IP>
  User root
  Port <PORT> # optional
EOL

git clone https://github.com/paranjko/external-test-lab.git

export GDC_HOME=$HOME/.gdc-data # optional; default: ./net-deployment-data

./external-test-lab/net-deployment-runbook/gdc.sh --release v2026.07.23 host join [--public-host <dns-name>] <ssh-alias> [<gpu-ssh-alias>]
```

The command verifies and imports the public Genesis bootstrap, creates the
Host's accounts, installs the pinned release, synchronizes the node, registers
it, and waits for `ACTIVE`. With an optional GPU SSH alias, it qualifies and
attaches that MLNode automatically.

`ACTIVE` is an onboarding state, not a successful validator join. The command
continues through a bounded four-epoch acceptance window and returns
`JOIN_PASS` only after it proves a chain-recorded runtime, positive PoC weight,
positive consensus voting power, and authenticated gateway inference.

The verified public bootstrap includes a join-only DevShard client credential.
The runbook stores it in the operator's state with mode `0600` and uses it only
for the final gateway regression. It never accepts a Genesis mnemonic,
validator keyring, gateway creator key, administrator credential, or bot
credential from the JOIN operator. The credential is omitted from logs and the
sanitized receipt. A missing or malformed bootstrap credential yields
`BLOCKED`; an unmet chain-evidence deadline yields `INCONCLUSIVE`.

For an independent proof, use a clean checkout and a separate `GDC_HOME`, then
share only the resulting `join-acceptance-<ssh-alias>/` evidence bundle. Its
`receipt.json` contains public chain-verifiable identifiers and no mnemonic,
keyring, client credential, or private account material.

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
checkout of the then-current `main`, each with its own operator-owned home. Do
not reuse a Genesis mnemonic, validator keyring, gateway creator key, or bot
credential.

```bash
git clone https://github.com/paranjko/external-test-lab.git /absolute/operator/external-test-lab
export GDC_HOME=/absolute/operator/gdc-home
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
