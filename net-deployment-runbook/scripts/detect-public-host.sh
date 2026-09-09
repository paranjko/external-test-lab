#!/bin/sh
# Resolve a public Host name through SSH itself. macOS does not provide getent;
# do not add a second DNS utility to the local operator dependency contract.
set -eu

usage() { printf 'Usage: %s SSH_ALIAS [PUBLIC_DNS]\n' "$0" >&2; }

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage; exit 2; }
alias_name=$1
printf '%s\n' "$alias_name" | grep -Eq '^[A-Za-z0-9._-]+$' || { printf 'invalid SSH alias\n' >&2; exit 2; }
explicit_host=${2:-}
printf '%s\n' "$explicit_host" | grep -Eq '^$|^[A-Za-z0-9.-]+$' || { printf 'invalid public DNS name\n' >&2; exit 2; }

ssh_host=$(ssh -G "$alias_name" 2>/dev/null | awk '$1 == "hostname" { print $2; exit }')
[ -n "$ssh_host" ] || { printf 'cannot resolve SSH alias %s\n' "$alias_name" >&2; exit 1; }

resolved_ipv4() {
  # This non-mutating, batch-mode probe never prompts. OpenSSH emits the
  # resolved peer in "Connecting to … [A.B.C.D]" before authentication.
  gdc_ssh_debug=$(ssh -o BatchMode=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o ConnectTimeout=5 -vvv -T "$1" true 2>&1 || true)
  printf '%s\n' "$gdc_ssh_debug" | awk '
    /Connecting to / {
      for (i = 1; i <= NF; i++) {
        value = $i
        gsub(/^\[/, "", value)
        gsub(/\]$/, "", value)
        if (value ~ /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/) { print value; exit }
      }
    }
  '
}

same_ipv4_target() {
  candidate_ip=$(resolved_ipv4 "$1")
  ssh_ip=$(resolved_ipv4 "$alias_name")
  [ -n "$candidate_ip" ] && [ "$candidate_ip" = "$ssh_ip" ]
}

if [ -n "$explicit_host" ]; then
  same_ipv4_target "$explicit_host" || {
    printf 'public DNS %s does not resolve to the SSH HostName address for %s\n' "$explicit_host" "$alias_name" >&2
    exit 1
  }
  printf '%s\n' "$explicit_host"
  exit 0
fi

# The Community Lab publishes gdc-nodeN at nodeN.gonka-dev.net. Accept that
# convention only after SSH resolves both names to the same IPv4 address.
case "$alias_name" in
  gdc-node[0-9]*)
    candidate=${alias_name#gdc-}.gonka-dev.net
    if same_ipv4_target "$candidate"; then
      printf '%s\n' "$candidate"
      exit 0
    fi
    ;;
esac

# An explicit DNS SSH HostName is sufficient only if SSH resolves it to IPv4.
printf '%s\n' "$ssh_host" | grep -Eq '.*[A-Za-z].*' && \
  printf '%s\n' "$ssh_host" | grep -Eq '^[A-Za-z0-9.-]+$' && \
  [ -n "$(resolved_ipv4 "$alias_name")" ] && {
    printf '%s\n' "$ssh_host"
    exit 0
  }

printf 'cannot infer a public DNS name for %s; pass --public-host DNS\n' "$alias_name" >&2
exit 1
