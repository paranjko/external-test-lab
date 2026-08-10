# JOIN cleanroom

The cleanroom proves that JOIN needs only public network data and SSH access to
the new Host. It receives a fresh runbook snapshot in an isolated volume.
Previous `$GDC_HOME/runs/`, `$GDC_HOME/state/`, `$GDC_HOME/.env` and private
SSH keys are not copied.
The host SSH agent, SSH config and `known_hosts` are mounted so the operator's
approved SSH identities remain outside the container.
The runbook is placed at `/workspace`. The devcontainer explicitly sets
`GDC_HOME=/workspaces/.data`, keeping runtime data outside the clean checkout.

```bash
make cleanroom cmd='ssh -T gdc-node1'
make cleanroom cmd='./gdc.sh host reset gdc-node1'
make cleanroom cmd='./gdc.sh host join gdc-node1'
make cleanroom-fresh cmd='./gdc.sh host join gdc-node1'
make cleanroom cmd='./gdc.sh host join gdc-node1 gdc-node1-gpu'
make cleanroom-reset
```

`cleanroom` rebuilds the filtered image snapshot, replaces the previous
container and re-seeds the isolated workspace before executing the command.
This prevents a previous rehearsal from supplying either runtime state or an
older `gdc.sh`. `cleanroom-fresh` remains an explicit synonym used by the BDD
adapter.

Inside the cleanroom, use either `./gdc.sh` from `/workspace` or the installed
`gdc` command.

The join command downloads the checksum-protected public Genesis bundle and
creates its local role input under `$GDC_HOME/state/` automatically. Do not
create `.env` for JOIN.
