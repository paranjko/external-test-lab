#!/usr/bin/env bash
set -Eeuo pipefail
OUT="${1:-/var/lib/node_exporter/textfile_collector/nvidia.prom}"
TMP="${OUT}.tmp"
mkdir -p "$(dirname "$OUT")"
{
  echo '# HELP gdc_nvidia_available Whether nvidia-smi is operational.'
  echo '# TYPE gdc_nvidia_available gauge'
  if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi -L >/dev/null 2>&1; then
    echo 'gdc_nvidia_available 0'
  else
    echo 'gdc_nvidia_available 1'
    echo '# TYPE gdc_nvidia_temperature_celsius gauge'
  echo '# TYPE gdc_nvidia_utilization_percent gauge'
  echo '# TYPE gdc_nvidia_memory_total_bytes gauge'
  echo '# TYPE gdc_nvidia_memory_used_bytes gauge'
  echo '# TYPE gdc_nvidia_power_watts gauge'
  while IFS=',' read -r index name temp util total used power; do
    trim(){ local v="$1"; v="${v#${v%%[![:space:]]*}}"; v="${v%${v##*[![:space:]]}}"; printf '%s' "$v"; }
    index="$(trim "$index")"; name="$(trim "$name" | tr '"\\' '__')"; temp="$(trim "$temp")"; util="$(trim "$util")"
    total="$(trim "$total")"; used="$(trim "$used")"; power="$(trim "$power")"
    labels="gpu=\"$index\",gpu_name=\"$name\""
    echo "gdc_nvidia_temperature_celsius{$labels} $temp"
    echo "gdc_nvidia_utilization_percent{$labels} $util"
    awk -v l="$labels" -v v="$total" 'BEGIN{printf "gdc_nvidia_memory_total_bytes{%s} %.0f\n",l,v*1024*1024}'
    awk -v l="$labels" -v v="$used" 'BEGIN{printf "gdc_nvidia_memory_used_bytes{%s} %.0f\n",l,v*1024*1024}'
    [[ "$power" == "[N/A]" ]] || echo "gdc_nvidia_power_watts{$labels} $power"
    done < <(nvidia-smi --query-gpu=index,name,temperature.gpu,utilization.gpu,memory.total,memory.used,power.draw --format=csv,noheader,nounits)
  fi
} > "$TMP"
mv "$TMP" "$OUT"
