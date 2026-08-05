#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: $0 --inventory FILE --node-name gdc-nodeN --output FILE" >&2
}

INVENTORY=''
NODE=''
OUTPUT=''

while (($#)); do
  case "$1" in
    --inventory)
      INVENTORY="$2"
      shift 2
      ;;
    --node-name)
      NODE="$2"
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

[[ "$NODE" =~ ^gdc-node[0-4]$ && -n "$OUTPUT" ]] || {
  usage
  exit 2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_env "$INVENTORY"
source "$ROOT/scripts/profile.sh"
load_profiles

INDEX="${NODE#gdc-node}"
HOST_VARIABLE="NODE${INDEX}_PUBLIC_HOST"

values=(
  "PUBLIC_HOST=${!HOST_VARIABLE}"
  "ACME_EMAIL=$ACME_EMAIL"
  "CADDY_IMAGE=$CADDY_IMAGE"
  "GRAFANA_IMAGE=$GRAFANA_IMAGE"
)

# The three public DevNet origins deliberately terminate only on node4.  Its
# canonical Network Node endpoint is node4.gonka-dev.net. Keeping this
# selection in the rendered env prevents every participant edge proxy from
# attempting to obtain the same ACME certificates.
if [[ "$NODE" == gdc-node4 ]]; then
  values+=(
    "PUBLIC_EDGE=true"
    "SITE_HOST=$SITE_HOST"
    "API_HOST=$API_HOST"
    "GRAFANA_HOST=$GRAFANA_HOST"
    "NODE0_PUBLIC_HOST=$NODE0_PUBLIC_HOST"
  )
else
  values+=("PUBLIC_EDGE=false")
fi

write_env "$OUTPUT" "${values[@]}"
