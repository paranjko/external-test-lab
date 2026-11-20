# DevNet operations with Ansible

`inventory/hosts.yml` lists the hosts, `inventory/group_vars/all/versions.yml` what they run.

| Playbook | Does |
|---|---|
| `monitoring-targets.yml` | writes the Prometheus target files on the monitoring host from the host list |
| `host-prep.yml` | prepares and hardens a host: Docker, NVIDIA driver and container toolkit on GPU roles, firewall, fail2ban, SSH by key only |

```bash
./run.sh monitoring-targets.yml --check --diff   # show the difference, change nothing
./run.sh monitoring-targets.yml                  # apply
./run.sh host-prep.yml -l node15 --check --diff  # one host
```

`run.sh` builds a pinned Ansible image and uses the caller's SSH config. Host `nodeN` is reached as `gdc-nodeN`. The firewall allows the monitoring host and, on an ML host, its validator; their addresses come from DNS at run time.

A new NVIDIA driver stops the run: reboot the host and run the playbook again.
