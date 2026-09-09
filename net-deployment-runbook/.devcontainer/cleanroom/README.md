# Cleanroom

```bash
make cleanroom
```

`GDC_HOME=/home/operator/.gdc-data` is mounted from
`.devcontainer/data/`. Host SSH aliases work through read-only SSH config,
known_hosts, and the forwarded SSH agent.

```bash
git clone https://github.com/paranjko/external-test-lab.git
./external-test-lab/net-deployment-runbook/gdc.sh host join --public-host node3.gonka-dev.net gdc-node3
```
