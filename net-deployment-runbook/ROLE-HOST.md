# HOST: operate a network participant

A Host runs a Network Node and one or more MLNodes. The Host operator owns its
accounts, identity and hardware. GENESIS creates the first Host; JOIN adds the
others.

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

## Operations

```bash
gdc host verify <ssh-alias>
gdc host stop <ssh-alias>
gdc host start <ssh-alias>
gdc host reset <ssh-alias>
```

Reset several Hosts sequentially with one command:

```bash
gdc host reset <ssh-alias-1> <ssh-alias-2> [<ssh-alias-3> ...]
```

Each Host is reset by the same phase as a separate command. If one reset
fails, later aliases are not touched.

Reset removes the deployment on the Host and the local joined marker. What it
does with the validator identity depends on the chain: before anything is
stopped or deleted it reads the participant of the local cold account through
the public API of the Bootstrap seeds retained by the last JOIN.

- Registered: identity and signer stay on the Host and locally; recover with
  `gdc host join --restore`. A Host that still keeps its signer below the
  deployment root is not reset at all until the archive exists.
- Not registered: the identity record and the cold account move to
  `state/recovery-partial-<timestamp>/`, the Host identity is archived under
  `/srv/dai/rejoin/<ssh-alias>/` and removed, and the next JOIN starts as
  `new`. Mnemonics stay.
- Unknown (no answer from the seeds, no retained Bootstrap, no cold account):
  everything is retained; rerun the reset when the public API answers.

`gdc host backup` needs the running deployment: create the archive before a
reset, not after it.

The Host's local accounts, imported public Genesis data, mnemonics, runs and
state are stored below `$GDC_HOME/<ssh-alias>/`; they are never shared with
another Host's directory.

Provide the GPU SSH alias during the initial JOIN when an MLNode runs on a
separate machine:

```bash
gdc host join <ssh-alias> <gpu-ssh-alias>
```

Use the standalone operation to reapply an already configured network-GPU
attachment:

```bash
gdc host ml-attach <ssh-alias>
```

### Lend an installed validator GPU

To lend the GPU of an installed validator to another Network Node, use the
donor alias directly. Setup stops the donor validator and exposes only its
existing ML runtime; it does not reset, reinstall or change its identity.

```bash
gdc host setup <parent-ssh-alias> add mlnode <donor-ssh-alias>

# Use this only when automatic endpoint discovery is ambiguous
gdc host setup <parent-ssh-alias> add mlnode \
  --mlnode-peer <mlnode-ip-or-domain> <donor-ssh-alias>

gdc host start <donor-ssh-alias>
```

`start` removes only the donor endpoint from its recorded parent, waits for
DAPI to release the worker, then restores the donor's existing services. If
release is uncertain, the donor remains stopped; do not reset it. The parent
validator and its other ML endpoints remain running.

This restores runtime ownership, not validator membership or signatures. Check
those separately before treating the donor as validating again.

### Add a clean ML-only Host

To add a second endpoint without changing validator identity or signer, use a
clean ML-only Host. Give DAPI its explicit reachable address; the SSH alias is
only used to install the MLNode:

```bash
gdc host setup <network-ssh-alias> add mlnode \
  --mlnode-peer <mlnode-ip-or-domain> <ml-ssh-alias>
gdc host setup <network-ssh-alias> status mlnode
```

The Network Node keeps its local ML endpoint. The API sends work to both
endpoints. `host reset <network-ssh-alias>` also resets ML-only Hosts recorded
by this command.

## JOIN monitoring

When the local operator inventory sets `GDC_PUBLIC_EDGE_NODE`, JOIN uses that
SSH alias as the monitoring collector and checks its Prometheus and discovery
directory before preparing the Host or creating its identity

`MONITORING_CIDR` is the collector's resolved public IPv4 address with `/32`,
not a Grafana URL, while `GDC_MONITORING_DOCKER_CIDR` is its private Docker
subnet, discovered from the running Compose `prometheus` service when no
explicit override is exported and retained in the generated Host inventory

After JOIN, GDC registers the Host, cAdvisor and chain endpoints and waits for
all three to report `up=1`, a monitoring failure does not undo a completed
JOIN or reset its identity

Retry registration and verification from the runbook directory without
repeating JOIN:

```bash
bash scripts/register-join-monitoring-targets.sh \
  --registry-host <collector-ssh-alias> \
  --node <host-ssh-alias> --public-host <host-ip-or-domain>
```

Without the operator's collector inventory, independent JOIN does not
register targets automatically and grants no additional Docker subnet access,
the network operator must arrange monitoring separately

## Governance

An active Host may vote with its current PoC-derived voting power. Query live
chain parameters before acting.

```bash
gdc governance vote <proposal-id> yes
gdc --composition <composition> governance devshard submit
gdc --composition <composition> governance devshard verify <proposal-id>
```

Keep the cold key on the operator's trusted machine. Never copy it to OPS,
Gateway, MLNode or public services.

## Sepolia observer

```bash
gdc bridge observer apply <ssh-alias>
gdc bridge observer verify <ssh-alias>
```
