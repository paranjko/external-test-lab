# DevNet operations with Ansible

`inventory/hosts.yml` lists the hosts, `inventory/group_vars/all/versions.yml` what they run.

| Playbook | Does |
|---|---|
| `monitoring-targets.yml` | writes the Prometheus target files on the monitoring host from the host list |

```bash
./run.sh monitoring-targets.yml --check --diff   # show the difference, change nothing
./run.sh monitoring-targets.yml                  # apply
```

`run.sh` builds a pinned Ansible image and uses the caller's SSH config. Host `nodeN` is reached as `gdc-nodeN`.
