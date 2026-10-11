#!/usr/bin/env bash
set -Eeuo pipefail

node="${1:-}"
[[ "$node" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
  echo 'Usage: check-running-network-node.sh SSH_ALIAS' >&2
  exit 2
}

ssh -T "$node" 'set -Eeuo pipefail
  sudo test -s /srv/dai/deploy/compose.yaml
  sudo test -s /srv/dai/deploy/node-config.json
  curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:9200/admin/v1/nodes \
    | jq -e "type == \"array\" and length > 0" >/dev/null'
