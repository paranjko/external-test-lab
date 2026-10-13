#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo 'Run with sudo' >&2; exit 1; }

# JOIN owns a previously unused node.  It deliberately does not try to infer
# whether retained deployment state is safe to reuse: recovery has an explicit
# command and evidence contract. Base Host preparation (including
# /etc/gonka/host.env and the firewall) survives reset and is safe to reuse,
# so only node state below /srv/dai is a refusal.
for path in \
  /srv/dai/deploy \
  /srv/dai/data \
  /srv/dai/data.generations \
  /srv/dai/identity \
  /srv/dai/signer \
  /srv/dai/edge \
  /srv/dai/agent; do
  if [[ -e "$path" || -L "$path" ]]; then
    printf 'JOIN_TARGET_NOT_CLEAN retained_node_state=%s\n' "$path"
    exit 196
  fi
done

if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker.service; then
  running="$(docker ps --format '{{.Names}} {{.Labels}}' 2>/dev/null || true)"
  if [[ "$running" == *gonka* || "$running" == *gdc-* ]]; then
    echo 'JOIN_TARGET_NOT_CLEAN retained_gonka_container=true'
    exit 196
  fi
fi

echo 'READY JOIN target is clean'
