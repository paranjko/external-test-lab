#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: $0 --inventory FILE --host HOST --output FILE" >&2
}

INVENTORY=''
HOST=''
OUTPUT=''

while (($#)); do
  case "$1" in
    --inventory)
      INVENTORY="$2"
      shift 2
      ;;
    --host)
      HOST="$2"
      shift 2
      ;;
    --output)
      OUTPUT="$2"
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[[ -n "$INVENTORY" && -n "$OUTPUT" ]] || {
  usage
  exit 2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_env "$INVENTORY"
source "$ROOT/scripts/profile.sh"
load_profiles
valid_host=false
for node in $GDC_NODE_ALIASES; do
  [[ "$HOST" == "$node" ]] && valid_host=true
done
for mapping in ${GDC_NODE_ML_HOSTS:-}; do
  [[ "$HOST" == "${mapping#*=}" && "$mapping" == *=* ]] && valid_host=true
done
[[ "$valid_host" == true && "$HOST" =~ ^[A-Za-z0-9._-]+$ ]] || {
  echo "host is not configured in inventory: $HOST" >&2
  exit 2
}
write_env "$OUTPUT" "GDC_MONITOR_HOST=$HOST" "NODE_EXPORTER_IMAGE=$NODE_EXPORTER_IMAGE" "CADVISOR_IMAGE=$CADVISOR_IMAGE"
