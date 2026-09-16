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
