#!/usr/bin/env bash
set -Eeuo pipefail

CHAIN=GONKA_INGRESS
while iptables -w -t mangle -C PREROUTING -j "$CHAIN" 2>/dev/null; do
  iptables -w -t mangle -D PREROUTING -j "$CHAIN"
done
while ip6tables -w -t mangle -C PREROUTING -j "$CHAIN" 2>/dev/null; do
  ip6tables -w -t mangle -D PREROUTING -j "$CHAIN"
done
systemctl disable gonka-firewall.service 2>/dev/null || true
logger -t gonka-firewall 'Automatic rollback removed the ingress firewall'
