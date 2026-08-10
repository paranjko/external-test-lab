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
