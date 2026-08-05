#!/usr/bin/env bash
set -Eeuo pipefail

# Filter public traffic in mangle/PREROUTING, before Docker applies DNAT to
# published ports. Keep project rules isolated; never flush a built-in chain.
# shellcheck disable=SC1091
source /etc/gonka/host.env

CHAIN=GONKA_INGRESS
EXTERNAL_IF="$(ip -4 route show default | awk 'NR == 1 { print $5 }')"
[[ -n "$EXTERNAL_IF" ]] || { echo 'Cannot determine the external interface' >&2; exit 1; }
[[ "$ROLE" =~ ^(network-gpu|network-only|ml-only)$ ]] || { echo "Invalid role: $ROLE" >&2; exit 1; }
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || { echo "Invalid SSH port: $SSH_PORT" >&2; exit 1; }

install_ipv4() {
  iptables -w -t mangle -N "$CHAIN" 2>/dev/null || true
  iptables -w -t mangle -F "$CHAIN"
  iptables -w -t mangle -C PREROUTING -j "$CHAIN" 2>/dev/null \
    || iptables -w -t mangle -I PREROUTING 1 -j "$CHAIN"

  iptables -w -t mangle -A "$CHAIN" ! -i "$EXTERNAL_IF" -j RETURN
  iptables -w -t mangle -A "$CHAIN" -m addrtype ! --dst-type LOCAL -j RETURN
  iptables -w -t mangle -A "$CHAIN" -m conntrack --ctstate INVALID -j DROP
  iptables -w -t mangle -A "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  iptables -w -t mangle -A "$CHAIN" -p icmp -j RETURN
  iptables -w -t mangle -A "$CHAIN" -p tcp --dport "$SSH_PORT" -j RETURN

  if [[ "$ROLE" == network-gpu || "$ROLE" == network-only ]]; then
    iptables -w -t mangle -A "$CHAIN" -p tcp -m multiport --dports 80,443,5000 -j RETURN
    iptables -w -t mangle -A "$CHAIN" -p udp --dport 443 -j RETURN
  fi
  if [[ "$(hostname)" == gdc-node0 ]]; then
    iptables -w -t mangle -A "$CHAIN" -p tcp -m multiport --dports 3000,8000,8081,8082,18080 -j RETURN
    if [[ -n "${METER_EDGE_CIDR:-}" ]]; then
      iptables -w -t mangle -A "$CHAIN" -s "$METER_EDGE_CIDR" -p tcp --dport 18000 -j RETURN
      iptables -w -t mangle -A "$CHAIN" -s "$METER_EDGE_CIDR" -p tcp --dport 9099 -j RETURN
    fi
  fi
  iptables -w -t mangle -A "$CHAIN" -s "$MONITORING_CIDR" -p tcp \
    -m multiport --dports 26660,8088,9101 -j RETURN
  if [[ -n "${ML_CALLBACK_CIDR:-}" ]]; then
    iptables -w -t mangle -A "$CHAIN" -s "$ML_CALLBACK_CIDR" -p tcp --dport 9100 -j RETURN
  fi
  if [[ "$ROLE" == ml-only ]]; then
    iptables -w -t mangle -A "$CHAIN" -s "$ML_CLIENT_CIDR" -p tcp \
      -m multiport --dports 5000,8080 -j RETURN
  fi
  iptables -w -t mangle -A "$CHAIN" -j DROP

  # Remove the superseded post-DNAT project chain, but leave all foreign rules intact.
  iptables -w -C DOCKER-USER -j GONKA-PUBLISHED 2>/dev/null \
    && iptables -w -D DOCKER-USER -j GONKA-PUBLISHED || true
  iptables -w -F GONKA-PUBLISHED 2>/dev/null || true
  iptables -w -X GONKA-PUBLISHED 2>/dev/null || true
}

install_ipv6() {
  ip6tables -w -t mangle -N "$CHAIN" 2>/dev/null || true
  ip6tables -w -t mangle -F "$CHAIN"
  ip6tables -w -t mangle -C PREROUTING -j "$CHAIN" 2>/dev/null \
    || ip6tables -w -t mangle -I PREROUTING 1 -j "$CHAIN"

  ip6tables -w -t mangle -A "$CHAIN" ! -i "$EXTERNAL_IF" -j RETURN
  ip6tables -w -t mangle -A "$CHAIN" -m addrtype ! --dst-type LOCAL -j RETURN
  ip6tables -w -t mangle -A "$CHAIN" -m conntrack --ctstate INVALID -j DROP
  ip6tables -w -t mangle -A "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  ip6tables -w -t mangle -A "$CHAIN" -p ipv6-icmp -j RETURN
  ip6tables -w -t mangle -A "$CHAIN" -p tcp --dport "$SSH_PORT" -j RETURN
  if [[ "$ROLE" == network-gpu || "$ROLE" == network-only ]]; then
    ip6tables -w -t mangle -A "$CHAIN" -p tcp -m multiport --dports 80,443,5000 -j RETURN
    ip6tables -w -t mangle -A "$CHAIN" -p udp --dport 443 -j RETURN
  fi
  if [[ "$(hostname)" == gdc-node0 ]]; then
    ip6tables -w -t mangle -A "$CHAIN" -p tcp -m multiport --dports 3000,8000,8081,8082,18080 -j RETURN
  fi
  ip6tables -w -t mangle -A "$CHAIN" -j DROP
}

install_ipv4
install_ipv6
