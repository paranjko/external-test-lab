#!/usr/bin/env bash
# Classify read-only monitoring drift without exposing Prometheus errors or
# operator paths in the persisted receipt.
set -Eeuo pipefail

usage() {
  echo "Usage: $0 --inventory FILE --gdc-data-root DIR --targets FILE --output FILE" >&2
}

INVENTORY=''
GDC_STATE_ROOT=''
TARGETS=''
OUTPUT=''
while (($#)); do
  case "$1" in
    --inventory) INVENTORY="${2:-}"; shift 2 ;;
    --gdc-data-root) GDC_STATE_ROOT="${2:-}"; shift 2 ;;
    --targets) TARGETS="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ -n "$INVENTORY" && -n "$GDC_STATE_ROOT" && -n "$TARGETS" && -n "$OUTPUT" ]] || { usage; exit 2; }
[[ -r "$INVENTORY" && -f "$INVENTORY" && ! -L "$INVENTORY" ]] || { echo 'monitoring inventory is unreadable or unsafe' >&2; exit 2; }
[[ -d "$GDC_STATE_ROOT" && ! -L "$GDC_STATE_ROOT" ]] || { echo 'GDC data root is unavailable or unsafe' >&2; exit 2; }
[[ -r "$TARGETS" && -f "$TARGETS" && ! -L "$TARGETS" ]] || { echo 'Prometheus target response is unreadable or unsafe' >&2; exit 2; }

# The OPS inventory is locally managed configuration. Source only the regular
# file after rejecting symlinks, then require the value's normal token form.
set -a
# shellcheck disable=SC1090
source "$INVENTORY"
set +a
[[ "${GDC_NODE_ALIASES:-}" =~ ^[A-Za-z0-9._-]+([[:space:]][A-Za-z0-9._-]+)*$ ]] \
  || { echo 'monitoring inventory has no valid node aliases' >&2; exit 2; }

jq -e '
  .status == "success" and (.data.activeTargets | type == "array") and
  all(.data.activeTargets[]?; (.labels | type == "object") and (.health | type == "string"))
' "$TARGETS" >/dev/null || { echo 'Prometheus target response has an unsupported schema' >&2; exit 2; }

declare -A inventory_nodes=() joined_nodes=() target_health=() target_error=()
read -r -a inventory_list <<<"$GDC_NODE_ALIASES"
for node in "${inventory_list[@]}"; do
  [[ -z "${inventory_nodes[$node]:-}" ]] || { echo 'monitoring inventory has duplicate node aliases' >&2; exit 2; }
  inventory_nodes[$node]=1
done

while IFS= read -r -d '' marker; do
  node="${marker##*/}"
  [[ "$node" =~ ^[A-Za-z0-9._-]+$ ]] || continue
  [[ -f "$marker" && ! -L "$marker" ]] || continue
  joined_nodes[$node]=1
done < <(find "$GDC_STATE_ROOT" -mindepth 4 -maxdepth 4 -type f -path '*/state/joined/*' -print0)

while IFS=$'\t' read -r host health last_error; do
  [[ "$host" =~ ^[A-Za-z0-9._-]+$ ]] || continue
  [[ -n "${target_health[$host]:-}" ]] && continue
  target_health[$host]="$health"
  target_error[$host]="$last_error"
done < <(jq -r '.data.activeTargets[]? | select(.labels.job == "gonka-node") | [(.labels.host // ""), .health, (.lastError // "")] | @tsv' "$TARGETS")

entries='[]'
for node in "${inventory_list[@]}"; do
  status=''
  if [[ -z "${target_health[$node]:-}" ]]; then
    status=deployed_target_missing
  elif [[ "${target_health[$node]}" == up ]]; then
    status=ready
  elif [[ "${target_error[$node]:-}" == *'404'* ]]; then
    status=endpoint_absent
  else
    status=scrape_down
  fi
  entries="$(jq -c --arg node "$node" --arg status "$status" '. + [{node:$node,status:$status}]' <<<"$entries")"
done
for node in "${!joined_nodes[@]}"; do
  [[ -n "${inventory_nodes[$node]:-}" ]] && continue
  entries="$(jq -c --arg node "$node" '. + [{node:$node,status:"inventory_missing"}]' <<<"$entries")"
done
entries="$(jq -c 'sort_by(.node)' <<<"$entries")"
status=pass
jq -e 'all(.[]; .status == "ready")' <<<"$entries" >/dev/null || status=drift

mkdir -p "$(dirname "$OUTPUT")"
[[ ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || { echo 'monitoring drift output already exists or is unsafe' >&2; exit 2; }
tmp="$(mktemp "$(dirname "$OUTPUT")/.monitoring-inventory-drift.XXXXXX")"
chmod 600 "$tmp"
jq -cn --arg status "$status" --arg generated_at "$(date -u +%FT%TZ)" --argjson entries "$entries" \
  '{schema_version:1,kind:"gdc-monitoring-inventory-drift",status:$status,generated_at:$generated_at,nodes:$entries}' >"$tmp"
jq -e '
  (keys | sort) == ["generated_at","kind","nodes","schema_version","status"] and
  .schema_version == 1 and .kind == "gdc-monitoring-inventory-drift" and
  (.status == "pass" or .status == "drift") and
  (.generated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z$")) and
  (.nodes | type == "array") and
  all(.nodes[]; (keys | sort) == ["node","status"] and
    (.node | test("^[A-Za-z0-9._-]+$")) and
    (.status | test("^(ready|inventory_missing|deployed_target_missing|scrape_down|endpoint_absent)$")))
' "$tmp" >/dev/null || { rm -f "$tmp"; echo 'monitoring drift receipt failed validation' >&2; exit 2; }
mv -f "$tmp" "$OUTPUT"
chmod 600 "$OUTPUT"

if [[ "$status" == pass ]]; then
  printf 'PASS monitoring inventory and deployed gonka-node targets agree\n'
  exit 0
fi
printf 'DRIFT monitoring inventory or deployed gonka-node targets need OPS reconciliation; run gdc ops monitoring after correcting inventory\n' >&2
exit 1
