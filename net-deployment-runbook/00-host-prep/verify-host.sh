#!/usr/bin/env bash
set -Eeuo pipefail
ROLE=""; MIN_DRIVER=580
while (($#)); do
  case "$1" in
    --role) ROLE="$2"; shift 2;;
    *) echo "Usage: $0 --role network-gpu|network-only|ml-only" >&2; exit 2;;
  esac
done
[[ "$ROLE" =~ ^(network-gpu|network-only|ml-only)$ ]] || exit 2
failed=0
pass(){ printf 'PASS  %s\n' "$*"; }
fail(){ printf 'FAIL  %s\n' "$*" >&2; failed=1; }
command -v docker >/dev/null && pass docker || fail docker
docker info >/dev/null 2>&1 && pass 'docker daemon' || fail 'docker daemon'
docker compose version >/dev/null 2>&1 && pass 'docker compose plugin' || fail 'docker compose plugin'
systemctl is-active --quiet chrony && pass chrony || fail chrony
fail2ban-client status sshd >/dev/null 2>&1 && pass 'fail2ban sshd jail' || fail 'fail2ban sshd jail'
chronyc tracking 2>/dev/null | grep -q 'Leap status.*Normal' && pass 'NTP synchronized' || fail 'NTP not synchronized'
if [[ -d /srv/dai && -w /srv/dai ]]; then
  pass '/srv/dai writable'
  free_kb=$(df -Pk /srv/dai | awk 'NR==2{print $4}')
  min_kb=$((40*1024*1024)); [[ "$ROLE" == network-gpu || "$ROLE" == network-only ]] && min_kb=$((50*1024*1024))
  (( free_kb >= min_kb )) && pass 'disk free threshold' || fail 'insufficient free disk'
else
  fail '/srv/dai not writable'
fi
if [[ "$ROLE" == network-gpu || "$ROLE" == ml-only ]]; then
  if nvidia-smi >/dev/null 2>&1; then
    version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1)
    major=${version%%.*}
    (( major >= MIN_DRIVER )) && pass "NVIDIA driver $version" || fail "NVIDIA driver $version < required $MIN_DRIVER"
  else
    fail 'nvidia-smi'
  fi
  timeout 300 docker run --rm --gpus all nvidia/cuda:12.8.1-base-ubuntu24.04 nvidia-smi >/dev/null 2>&1 \
    && pass 'GPU visible in CUDA 12.8 container' || fail 'GPU unavailable in CUDA 12.8 container'
fi
systemctl is-active --quiet gonka-firewall && pass 'pre-DNAT firewall service' || fail 'pre-DNAT firewall service'
iptables -t mangle -S GONKA_INGRESS 2>/dev/null | grep -q -- '-j DROP' \
  && pass 'IPv4 ingress policy' || fail 'IPv4 ingress policy'
ip6tables -t mangle -S GONKA_INGRESS 2>/dev/null | grep -q -- '-j DROP' \
  && pass 'IPv6 ingress policy' || fail 'IPv6 ingress policy'
exit "$failed"
