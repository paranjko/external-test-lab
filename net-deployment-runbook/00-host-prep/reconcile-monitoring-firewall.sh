#!/usr/bin/env bash
set -Eeuo pipefail

action="${1:-}"
shift || true
[[ "$action" =~ ^(preview|apply)$ ]] || { echo 'expected preview or apply' >&2; exit 2; }

monitoring_cidr=''
expected_current=''
while (($#)); do
  case "$1" in
    --monitoring-cidr) monitoring_cidr="${2:-}"; shift 2 ;;
    --expected-current-cidr) expected_current="${2:-}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo 'run as root' >&2; exit 1; }
[[ "$monitoring_cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/(3[0-2]|[12]?[0-9])$ ]] \
  || { echo 'invalid monitoring CIDR' >&2; exit 2; }
[[ -r /etc/gonka/host.env && ! -L /etc/gonka/host.env ]] \
  || { echo 'managed host environment is unavailable' >&2; exit 1; }

current="$(awk -F= '$1 == "MONITORING_CIDR" { print $2; exit }' /etc/gonka/host.env)"
[[ "$current" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/(3[0-2]|[12]?[0-9])$ ]] \
  || { echo 'managed host environment has no valid MONITORING_CIDR' >&2; exit 1; }
if [[ -n "$expected_current" && "$current" != "$expected_current" ]]; then
  echo 'monitoring CIDR changed after preview; refusing stale apply' >&2
  exit 1
fi

receipt() {
  local applied="$1" outcome="$2"
  jq -cn --arg host "$(hostname)" --arg current "$current" --arg desired "$monitoring_cidr" \
    --argjson applied "$applied" --arg outcome "$outcome" \
    '{schema:"gdc-monitoring-firewall/1",host:$host,current_monitoring_cidr:$current,desired_monitoring_cidr:$desired,applied:$applied,outcome:$outcome,delta:(if $current == $desired then [] else [{field:"MONITORING_CIDR",before:$current,after:$desired}] end)}'
}

if [[ "$action" == preview || "$current" == "$monitoring_cidr" ]]; then
  receipt false "$(if [[ "$current" == "$monitoring_cidr" ]]; then printf NOOP; else printf DRIFT; fi)"
  exit 0
fi

tmp="$(mktemp /etc/gonka/host.env.XXXXXX)"
trap 'rm -f -- "$tmp"' EXIT
awk -F= -v cidr="$monitoring_cidr" '
  $1 == "MONITORING_CIDR" { print "MONITORING_CIDR=" cidr; seen = 1; next }
  { print }
  END { if (!seen) exit 1 }
' /etc/gonka/host.env >"$tmp"
install -m 0600 "$tmp" /etc/gonka/host.env
systemctl restart gonka-firewall.service
iptables -w -t mangle -S GONKA_INGRESS | grep -Fq -- "-s $monitoring_cidr -p tcp -m multiport --dports 26660,8088,9101 -j ACCEPT" \
  || { echo 'managed monitoring firewall rule did not converge' >&2; exit 1; }
current="$monitoring_cidr"
receipt true PASS
