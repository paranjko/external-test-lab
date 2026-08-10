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
./gdc.sh host verify <ssh-alias>
./gdc.sh host stop <ssh-alias>
./gdc.sh host start <ssh-alias>
./gdc.sh host reset <ssh-alias>
```

Reset several Hosts sequentially with one command:

```bash
./gdc.sh host reset <ssh-alias-1> <ssh-alias-2> [<ssh-alias-3> ...]
```

Each Host is reset by the same phase as a separate command. If one reset
fails, later aliases are not touched.

The Host's local accounts, imported public Genesis data, mnemonics, runs and
state are stored below `$GDC_HOME/<ssh-alias>/`; they are never shared with
another Host's directory.

Provide the GPU SSH alias during the initial JOIN when an MLNode runs on a
separate machine:

```bash
./gdc.sh host join <ssh-alias> <gpu-ssh-alias>
```

Use the standalone operation to reapply an already configured network-GPU
attachment:

```bash
./gdc.sh host ml-attach <ssh-alias>
```

## Governance

An active Host may vote with its current PoC-derived voting power. Query live
chain parameters before acting.

```bash
./gdc.sh governance vote <proposal-id> yes
./gdc.sh governance devshard submit
./gdc.sh governance devshard verify <proposal-id>
```

Keep the cold key on the operator's trusted machine. Never copy it to OPS,
Gateway, MLNode or public services.

## Sepolia observer

```bash
./gdc.sh bridge observer apply <ssh-alias>
./gdc.sh bridge observer verify <ssh-alias>
```
