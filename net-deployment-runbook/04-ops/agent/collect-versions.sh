#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE=/srv/dai/monitoring-agent/.env
[[ -s "$ENV_FILE" ]] || exit 1
# shellcheck disable=SC1090
source "$ENV_FILE"
[[ -n "${GDC_MONITOR_HOST:-}" ]] || exit 1

output_dir=/var/lib/node_exporter/textfile_collector
output="$output_dir/gdc-component-versions.prom"
tmp="$(mktemp "$output_dir/.gdc-component-versions.XXXXXX")"
trap 'rm -f "${tmp:-}"' EXIT

prom_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  printf '%s' "$value"
}

emit_component() {
  local component="$1" instance="$2" version="$3" commit="$4" image="$5" source="$6"
  printf 'gdc_component_info{host="%s",component="%s",component_instance="%s",version="%s",commit="%s",image="%s",source="%s"} 1\n' \
    "$(prom_escape "$GDC_MONITOR_HOST")" "$(prom_escape "$component")" \
    "$(prom_escape "$instance")" "$(prom_escape "${version:-unreported}")" \
    "$(prom_escape "${commit:-unreported}")" "$(prom_escape "${image:-unreported}")" \
    "$(prom_escape "$source")" >>"$tmp"
}

printf '# HELP gdc_component_info Runtime and deployed-image software inventory\n# TYPE gdc_component_info gauge\n' >"$tmp"
versions="$(curl -fsS --max-time 10 http://127.0.0.1:8000/v1/versions 2>/dev/null || true)"
if jq -e '.api_version and .node_version' >/dev/null 2>&1 <<<"$versions"; then
  while IFS=$'\t' read -r component instance version commit; do
    emit_component "$component" "$instance" "$version" "$commit" '' runtime
  done < <(jq -r '
    [
      ["inference-chain", .node_version.application_name, .node_version.version, .node_version.commit],
      ["decentralized-api", .api_version.application_name, .api_version.version, .api_version.commit]
    ][] | @tsv
  ' <<<"$versions")
  while IFS=$'\t' read -r instance version; do
    emit_component mlnode "$instance" "$version" '' '' runtime
  done < <(jq -r '.mlnodes[]? | [.node_id, (.version // "")] | @tsv' <<<"$versions")
  scrape_success=1
else
  scrape_success=0
fi

for component in tmkms node api mlnode versiond explorer proxy; do
  container_id="$(docker ps --filter "label=com.docker.compose.project=$GDC_MONITOR_HOST" --filter "label=com.docker.compose.service=$component" --format '{{.ID}}' | head -n1)"
  [[ -n "$container_id" ]] || continue
  image="$(docker inspect --format '{{.Config.Image}}' "$container_id")"
  reference="${image%@*}"
  leaf="${reference##*/}"
  version=unreported
  [[ "$leaf" == *:* ]] && version="${leaf##*:}"
  emit_component "$component" "$component" "$version" '' "$image" container
done

printf '# HELP gdc_component_inventory_scrape_success Whether the local runtime version endpoint was readable\n# TYPE gdc_component_inventory_scrape_success gauge\ngdc_component_inventory_scrape_success{host="%s"} %s\n' \
  "$(prom_escape "$GDC_MONITOR_HOST")" "$scrape_success" >>"$tmp"
chmod 0644 "$tmp"
mv "$tmp" "$output"
trap - EXIT
