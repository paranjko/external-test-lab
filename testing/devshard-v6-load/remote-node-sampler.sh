#!/usr/bin/env bash
# Read-only sampling of the stand during a remote load run: gateway containers on the gateway node,
# CPU, memory and GPU of the model hosts. Stops on Ctrl+C or when <output directory>/DONE appears.
# Usage: remote-node-sampler.sh <output directory> <gateway ssh host> [model host ssh host ...]
set -uo pipefail

out=${1:?output directory of remote-ladder.sh}
gw=${2:?ssh host of the gateway node, e.g. gdc-node0}
shift 2
hosts=("$gw" "$@")
interval=${INTERVAL:-15}
mkdir -p "$out"
file="$out/nodes.tsv"
[ -s "$file" ] || printf 'time_utc\tnode\tmetric\tvalue\n' > "$file"

host_probe='printf "cpu_pct\t%s\n" "$(vmstat 1 2 | tail -1 | awk "{print 100-\$15}")"
free -m | awk "/^Mem:/{printf \"mem_used_mib\t%s/%s\n\", \$3, \$2}"
printf "load1\t%s\n" "$(cut -d" " -f1 /proc/loadavg)"
command -v nvidia-smi >/dev/null && nvidia-smi --query-gpu=index,utilization.gpu,memory.used,memory.total,temperature.gpu,clocks.sm,clocks_throttle_reasons.active --format=csv,noheader,nounits |
  awk -F", " "{printf \"gpu%s_util_pct\t%s\ngpu%s_mem_mib\t%s/%s\ngpu%s_temp_c\t%s\ngpu%s_sm_mhz\t%s\ngpu%s_throttle\t%s\n\", \$1, \$2, \$1, \$3, \$4, \$1, \$5, \$1, \$6, \$1, \$7}"'
gw_probe='docker stats --no-stream --format "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" | awk -F"\t" "/park-gateway|gateway/{printf \"%s_cpu\t%s\n%s_mem\t%s\n\", \$1, \$2, \$1, \$3}"'

sample() {
  local h=$1 probe=$host_probe now
  [ "$h" = "$gw" ] && probe="$host_probe
$gw_probe"
  now=$(date -u +%FT%TZ)
  timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=8 "$h" "$probe" < /dev/null 2>/dev/null |
    awk -F'\t' -v t="$now" -v n="$h" 'NF==2{print t "\t" n "\t" $1 "\t" $2}'
}

while [ ! -e "$out/DONE" ]; do
  start=$(date +%s)
  for h in "${hosts[@]}"; do sample "$h" > "$out/.sample.$h" & done
  wait
  for h in "${hosts[@]}"; do cat "$out/.sample.$h"; done >> "$file"
  rm -f "$out"/.sample.*
  sleep $(( interval - ($(date +%s) - start) > 0 ? interval - ($(date +%s) - start) : 0 ))
done
