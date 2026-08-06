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
min_kb=$((40*1024*1024)); [[ "$ROLE" == network-gpu || "$ROLE" == network-only ]] && min_kb=$((50*1024*1024))
if [[ -d /srv && -d /srv/dai && -w /srv/dai ]]; then
  pass '/srv and /srv/dai writable'
else
  fail '/srv or /srv/dai is missing or not writable'
fi
for storage_path in /srv/dai /var/lib/docker /var/lib/containerd; do
  if [[ -d "$storage_path" ]]; then
    free_kb=$(df -Pk "$storage_path" | awk 'NR==2{print $4}')
    if [[ "$free_kb" =~ ^[0-9]+$ ]] && (( free_kb >= min_kb )); then
      pass "$storage_path free space threshold"
    else
      fail "$storage_path has insufficient free disk"
    fi
  else
    fail "$storage_path missing"
  fi
done
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
if [[ -r /etc/gonka/host.env ]]; then
  # shellcheck disable=SC1091
  source /etc/gonka/host.env
  if [[ -n "${ML_CALLBACK_CIDR:-}" ]]; then
    iptables -t mangle -S GONKA_INGRESS 2>/dev/null \
      | grep -Fq -- "-s $ML_CALLBACK_CIDR -p tcp -m tcp --dport 9100 -j RETURN" \
      && pass 'ML callback ingress source' || fail 'ML callback ingress source is stale'
  fi
  if [[ "$ROLE" == ml-only ]]; then
    iptables -t mangle -S GONKA_INGRESS 2>/dev/null \
      | grep -F -- "-s $ML_CLIENT_CIDR -p tcp" \
      | grep -Fq -- '--dports 5000,8080' \
      && pass 'ML client ingress source' || fail 'ML client ingress source is stale'
  fi
fi
exit "$failed"
