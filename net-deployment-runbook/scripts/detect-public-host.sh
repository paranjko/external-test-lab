#!/usr/bin/env bash
set -Eeuo pipefail

usage() { echo "Usage: $0 SSH_ALIAS [PUBLIC_DNS]" >&2; }

[[ $# -ge 1 && $# -le 2 ]] || { usage; exit 2; }
alias_name="$1"
[[ "$alias_name" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'invalid SSH alias' >&2; exit 2; }
explicit_host="${2:-}"
[[ -z "$explicit_host" || "$explicit_host" =~ ^[A-Za-z0-9.-]+$ ]] || { echo 'invalid public DNS name' >&2; exit 2; }

ssh_host="$(ssh -G "$alias_name" 2>/dev/null | awk '$1 == "hostname" { print $2; exit }')"
[[ -n "$ssh_host" ]] || { echo "cannot resolve SSH alias $alias_name" >&2; exit 1; }

same_ipv4_target() {
  local candidate="$1" candidate_ip ssh_ip
  while read -r candidate_ip; do
    while read -r ssh_ip; do
      [[ "$candidate_ip" == "$ssh_ip" ]] && return 0
    done < <(getent ahostsv4 "$ssh_host" 2>/dev/null | awk '{ print $1 }' | sort -u)
  done < <(getent ahostsv4 "$candidate" 2>/dev/null | awk '{ print $1 }' | sort -u)
  return 1
}

if [[ -n "$explicit_host" ]]; then
  same_ipv4_target "$explicit_host" || {
    echo "public DNS $explicit_host does not resolve to the SSH HostName address for $alias_name" >&2
    exit 1
  }
  printf '%s\n' "$explicit_host"
  exit 0
fi

# The Community Lab publishes gdc-nodeN at nodeN.gonka-dev.net. Accept that
# convention only when DNS and the operator's SSH alias resolve to the same
# IPv4 address; an alias name alone is never treated as proof.
if [[ "$alias_name" =~ ^gdc-(node[0-9]+)$ ]]; then
  candidate="${BASH_REMATCH[1]}.gonka-dev.net"
  if same_ipv4_target "$candidate"; then
    printf '%s\n' "$candidate"
    exit 0
  fi
fi

# A DNS name explicitly configured as SSH HostName is already sufficient.
if [[ "$ssh_host" =~ [A-Za-z] && "$ssh_host" =~ ^[A-Za-z0-9.-]+$ ]] \
  && getent ahostsv4 "$ssh_host" >/dev/null 2>&1; then
  printf '%s\n' "$ssh_host"
  exit 0
fi

echo "cannot infer a public DNS name for $alias_name; pass --public-host DNS" >&2
exit 1
