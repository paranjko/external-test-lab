#!/usr/bin/env bash
# Run a playbook from this folder in a pinned Ansible image, with the caller's SSH config and keys.
#   ./run.sh monitoring-targets.yml --check --diff
set -euo pipefail
cd "$(dirname "$0")"
docker build -q -t devnet-ansible . >/dev/null
agent=()
[[ -n "${SSH_AUTH_SOCK:-}" ]] && agent=(-v "$SSH_AUTH_SOCK:$SSH_AUTH_SOCK" -e SSH_AUTH_SOCK)
exec docker run --rm --network host --user "$(id -u):$(id -g)" \
  -v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro \
  -v "$HOME/.ssh:$HOME/.ssh:ro" -e HOME="$HOME" "${agent[@]}" \
  -v "$PWD:/ansible:ro" devnet-ansible ansible-playbook "$@"
