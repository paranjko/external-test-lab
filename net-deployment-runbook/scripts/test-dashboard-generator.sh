#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GENERATOR="$ROOT/04-ops/grafana/generate-dashboards.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The panel helpers are the single source of truth for both boards. Evaluate them
# from the generator itself rather than restating them here, so a helper that
# changes shape cannot pass a stale copy of its own contract.
helpers="$(awk '/^    def ds:/,/^    def base\(\$uid;\$title;\$from;\$panels\): base/' "$GENERATOR")"
[[ -n "$helpers" ]] || { echo 'could not extract the panel helpers from the generator' >&2; exit 1; }

probe() { jq -ne "$helpers $1"; }

# A regenerated board must equal the committed one. Run the generator against a
# copy of the tree: a test that writes into tracked files would both dirty the
# working tree and quietly overwrite a hand edit it was supposed to report.
mkdir -p "$tmp/tree/04-ops/edge-node/public-grafana/dashboards"
cp -R "$ROOT/04-ops/grafana" "$tmp/tree/04-ops/grafana"
bash "$tmp/tree/04-ops/grafana/generate-dashboards.sh" >/dev/null
for board in gdc-network gdc-inference gdc-overview; do
  cmp -s "$ROOT/04-ops/grafana/dashboards/$board.json" "$tmp/tree/04-ops/grafana/dashboards/$board.json" \
    || { echo "the committed monitoring definition of $board is not what the generator produces" >&2; exit 1; }
  cmp -s "$ROOT/04-ops/edge-node/public-grafana/dashboards/$board.json" "$tmp/tree/04-ops/edge-node/public-grafana/dashboards/$board.json" \
    || { echo "the committed public definition of $board is not what the generator produces" >&2; exit 1; }
  cmp -s "$ROOT/04-ops/grafana/dashboards/$board.json" "$ROOT/04-ops/edge-node/public-grafana/dashboards/$board.json" \
    || { echo "$board differs between the monitoring and public directories" >&2; exit 1; }
done

# The short arities must keep producing exactly what they produced before the
# empty-state parameters existed: no description, no field-config override.
probe 'stat(1;"t";"up";"";0;0;4) | has("description") | not' >/dev/null \
  || { echo 'the short stat arity emitted a description' >&2; exit 1; }
probe 'stat(1;"t";"up";"";0;0;4) | .options.colorMode == "none"' >/dev/null \
  || { echo 'the short stat arity changed its options' >&2; exit 1; }
probe 'ts(1;"t";"up";"l";"";0;0;12;8) | .options.legend.calcs == ["lastNotNull"]' >/dev/null \
  || { echo 'the short ts arity changed its legend calcs' >&2; exit 1; }
probe 'table(1;"t";"up";0;0;12;8) | .fieldConfig.defaults.custom.align == "auto"' >/dev/null \
  || { echo 'the short table arity lost its custom block' >&2; exit 1; }
probe 'base("u";"t";"now-1h";[]) | .editable == false' >/dev/null \
  || { echo 'the short base arity changed the board keys' >&2; exit 1; }

# A panel must be able to say what a value means and what its absence means.
probe 'stat(1;"t";"up";"";0;0;4;"why this is here";{noValue:"no series"};{colorMode:"value"})
       | .description == "why this is here"
         and .fieldConfig.defaults.noValue == "no series"
         and .options.colorMode == "value"' >/dev/null \
  || { echo 'stat did not carry description, noValue and options through' >&2; exit 1; }

# colorMode is "none" on every stat, so a threshold or mapping colour is invisible
# unless options can be overridden. Guard the combination, not just the parts.
probe 'stat(1;"t";"up";"";0;0;4;"";{mappings:[{type:"special",options:{match:"null",result:{text:"no series",color:"text"}}}]};{colorMode:"value"})
       | (.fieldConfig.defaults.mappings | length) == 1 and .options.colorMode == "value"' >/dev/null \
  || { echo 'stat could not combine a value mapping with a visible colour mode' >&2; exit 1; }

# A custom override merges into the shared block. Replacing it would silently drop
# drawStyle, lineWidth and the axis settings and the panel would render as dots.
probe 'ts(1;"t";"up";"l";"";0;0;12;8;"";{custom:{fillOpacity:0,spanNulls:false}};["lastNotNull","min"])
       | .fieldConfig.defaults.custom.drawStyle == "line"
         and .fieldConfig.defaults.custom.lineWidth == 2
         and .fieldConfig.defaults.custom.fillOpacity == 0
         and .fieldConfig.defaults.custom.spanNulls == false
         and .options.legend.calcs == ["lastNotNull","min"]' >/dev/null \
  || { echo 'the ts custom override replaced the shared custom block instead of merging' >&2; exit 1; }

probe 'ts(1;"t";"up";"l";"none";0;0;12;8;"why this is here";{noValue:"no series",unit:"percent",mappings:[{type:"special"}],custom:{fillOpacity:0}};["lastNotNull","min"])
       | .description == "why this is here"
         and .fieldConfig.defaults.noValue == "no series"
         and .fieldConfig.defaults.unit == "percent"
         and (.fieldConfig.defaults.mappings | length) == 1
         and .fieldConfig.defaults.custom.fillOpacity == 0
         and .fieldConfig.defaults.custom.drawStyle == "line"' >/dev/null \
  || { echo 'ts dropped a description, an empty-state field or a unit override' >&2; exit 1; }

probe 'table(1;"t";"up";0;0;12;8;"d";{noValue:"nothing collected",custom:{inspect:true}})
       | .description == "d"
         and .fieldConfig.defaults.noValue == "nothing collected"
         and .fieldConfig.defaults.custom.align == "auto"
         and .fieldConfig.defaults.custom.inspect == true' >/dev/null \
  || { echo 'the table custom override replaced the shared custom block instead of merging' >&2; exit 1; }

probe 'base("u";"t";"now-1h";[];{editable:true}) | .editable == true' >/dev/null \
  || { echo 'base did not apply the board override' >&2; exit 1; }

# A duplicate panel id makes Grafana drop a panel silently, and a panel wider than
# the grid is clipped on the public board.
for board in gdc-network gdc-inference gdc-overview; do
  file="$ROOT/04-ops/grafana/dashboards/$board.json"
  jq -e '[.panels[].id] | length == (unique | length)' "$file" >/dev/null \
    || { echo "$board has duplicate panel ids" >&2; exit 1; }
  jq -e '[.panels[] | select(.gridPos.x + .gridPos.w > 24)] | length == 0' "$file" >/dev/null \
    || { echo "$board has a panel that overflows the 24-column grid" >&2; exit 1; }
  jq -e '[.panels[] | select(.type != "row" and .type != "text") | select((.targets | length) == 0)] | length == 0' "$file" >/dev/null \
    || { echo "$board has a query panel with no target" >&2; exit 1; }
  jq -e '.editable == false and .timezone == "utc"' "$file" >/dev/null \
    || { echo "$board is editable or does not render in UTC" >&2; exit 1; }
done

for board in gdc-network gdc-inference gdc-overview; do
  file="$ROOT/04-ops/grafana/dashboards/$board.json"
  jq -e '[.panels[] | select((.fieldConfig.defaults.noValue // "") != "") | select((.description // "") == "")] | length == 0' "$file" >/dev/null \
    || { echo "$board declares an empty state without documenting why it can happen" >&2; exit 1; }
done

# The dashed disk lines claim to be the alert levels. Read both from their sources.
alert_percent() {
  awk -v rule="alert: $1" '$0 ~ rule {found=1} found && /expr:/ {print; exit}' "$ROOT/04-ops/prometheus/alerts.yml" \
    | grep -Eo '< [0-9.]+' | awk '{print $2 * 100}'
}
disk_warning="$(alert_percent GdcDiskLow)"
disk_critical="$(alert_percent GdcDiskCritical)"
[[ -n "$disk_warning" && -n "$disk_critical" ]] || { echo 'could not read the disk alert levels from alerts.yml' >&2; exit 1; }
for board in gdc-network gdc-overview; do
  jq -e --argjson warning "$disk_warning" --argjson critical "$disk_critical" '
    [.panels[] | select(.title == "Operational disk free")
     | [.fieldConfig.defaults.thresholds.steps[].value | select(. != null)]]
    | length > 0 and all(. == [$critical, $warning])' "$ROOT/04-ops/grafana/dashboards/$board.json" >/dev/null \
    || { echo "$board draws disk lines that are not the alert levels $disk_critical/$disk_warning" >&2; exit 1; }
done

# Every node counts the same committed transactions, so a sum multiplies the rate
# by the number of scraped nodes.
jq -e '[.panels[].targets[]?.expr | select(test("cometbft_consensus_total_txs")) | select(test("^\\s*sum"))] | length == 0' \
  "$ROOT/04-ops/grafana/dashboards/gdc-network.json" >/dev/null \
  || { echo 'gdc-network sums the per-node transaction rate across nodes' >&2; exit 1; }

# A table renames the labels its query groups by. A key the query never returns
# renames nothing, and a label left out keeps its raw name beside the renamed ones.
for board in gdc-network gdc-inference gdc-overview; do
  mismatched="$(jq -r '.panels[] | select(.type == "table")
    | select(.targets[0].expr | test("^[a-z_]+ by \\("))
    | (.targets[0].expr | capture("^[a-z_]+ by \\((?<labels>[^)]*)\\)").labels | split(",") | map(gsub(" "; ""))) as $grouped
    | ([.transformations[]?.options.renameByName // {} | keys[]] - ["Value"]) as $renamed
    | select(($renamed - $grouped | length) > 0 or ($grouped - $renamed | length) > 0)
    | "\(.id) \(.title)"' "$ROOT/04-ops/grafana/dashboards/$board.json")"
  [[ -z "$mismatched" ]] \
    || { echo "$board has a table whose column names do not match its grouping: $mismatched" >&2; exit 1; }
done

printf 'PASS dashboard generator regenerates both boards unchanged\n'
printf 'PASS every grouped table names exactly the labels it groups by\n'
printf 'PASS disk lines are the alert levels and the transaction rate is not summed over nodes\n'
printf 'PASS every panel that declares an empty state also documents why it can happen\n'
printf 'PASS dashboard helpers carry descriptions, empty-state field config and options without dropping shared defaults\n'
