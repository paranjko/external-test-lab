# Cleanroom

A disposable Ubuntu 24.04 devcontainer with the GNU userland that `gdc.sh`
needs: bash 5, GNU coreutils, util-linux, git, gh, jq, rsync, and an OpenSSH
client. This optional environment works on macOS or anywhere you want to run
`gdc` from a fresh clone that holds no local secrets. For native operator setup
and its verification limits, see [native macOS](../../NATIVE-MACOS.md).

```bash
make cleanroom cmd=bash
```

`make cleanroom` rebuilds the image from the build cache, removes the previous
container, starts a new one, and runs `cmd` inside it as the unprivileged
`operator` user. Do not run it while a `gdc` phase is in progress: the phase
dies with the container. Open another shell in the running container with:

```bash
make cleanroom-shell
```

## What the container shares with your machine

- `~/.ssh/config` and `~/.ssh/known_hosts`, read-only. Host SSH aliases work
  unchanged.
- Your SSH agent. Private keys never enter the container; load the key your
  Host alias logs in with (`ssh-add ~/.ssh/<key>`) before you start.
- `.devcontainer/data/`, mounted as `GDC_HOME=/home/operator/.gdc-data`. Runs,
  state, and validator backup archives written there survive container
  recreation. Nothing else does, including a repository clone inside.

Because key files are not mounted, a Host entry must authenticate through the
agent. Do not set `IdentitiesOnly yes` in that entry: it limits ssh to the
`IdentityFile` paths, or without one to the default `~/.ssh/id_*` files, none
of which exist in the container, so the agent key is never offered. If you
keep the option, copy only the matching public key to the same path inside the
container after each start, for example:

```bash
cleanroom="$(docker ps -q --filter "label=devcontainer.config_file=$PWD/.devcontainer/cleanroom/devcontainer.json")"
docker exec -i -u operator "$cleanroom" bash -c 'mkdir -p ~/.ssh && cat > ~/.ssh/<key>.pub' < ~/.ssh/<key>.pub
```

## macOS

Docker Desktop cannot bind-mount the launchd agent socket that `SSH_AUTH_SOCK`
names; it exposes the host agent at `/run/host-services/ssh-auth.sock` inside
its VM instead. The cleanroom targets point the devcontainer there on Darwin;
override the path with `make cleanroom CLEANROOM_SSH_AUTH_SOCK=<path> ...` if
your setup differs. The forwarded socket is owned by root with mode 0660, so
the image adds `operator` to group `root`. If `ssh-add -l` inside the
container reports `Permission denied`, the container predates that change:
run `make cleanroom cmd=bash` again to rebuild it.

## Check the environment

```bash
ssh-add -l                        # lists the key for your Host alias
ssh -T <ssh-alias> true; echo $?  # prints 0
```

## Run a role

```bash
git clone https://github.com/paranjko/external-test-lab.git
./external-test-lab/net-deployment-runbook/gdc.sh host join --public-host <IP_or_DOMAIN> <ssh-alias>
```

`GDC_HOME` is preset. Downloaded bootstrap files must live inside the
container or under `.devcontainer/data/`. The validator backup archive that
JOIN creates appears in `.devcontainer/data/` on your machine; store it
elsewhere and keep it private.
