# Cleanroom

A disposable Ubuntu environment for running `gdc` on macOS or from a clean
workstation. Docker Desktop and an SSH key loaded in the host agent are
required.

Start the cleanroom:

```bash
make cleanroom cmd=bash
```

This recreates the container. To open another shell without recreating it:

```bash
make cleanroom-shell
```

Your SSH configuration is mounted read-only and private keys remain in the
host agent. Host aliases that use `IdentitiesOnly yes` are not supported.
On macOS, SSH-agent forwarding is configured automatically; rebuild the
container if `ssh-add -l` reports `Permission denied`.

```bash
ssh-add -l
ssh -T <ssh-alias> true
```

Clone the repository inside the container and run the required role:

```bash
git clone https://github.com/paranjko/external-test-lab.git
./external-test-lab/net-deployment-runbook/gdc.sh host join --public-host <IP_or_DOMAIN> <ssh-alias>
```

`GDC_HOME` data and validator backups persist in `.devcontainer/data/` on the
host. Store completed backups elsewhere and keep them private.
