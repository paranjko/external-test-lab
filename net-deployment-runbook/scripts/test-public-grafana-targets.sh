#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GDC_GRAFANA_VERIFIER_LIBRARY=true source "$ROOT/scripts/verify-public-grafana.sh"

if verify_expected_target_result gdc-node4-ml gdc-node4 <<'JSON' >/dev/null
{"status":"success","data":{"result":[{"metric":{"host":"gdc-node0","validator":"gdc-node0"},"value":[0,"1"]}]}}
JSON
then
  echo 'aggregate data from another Host satisfied the expected-target check' >&2
  exit 1
fi

if verify_expected_target_result gdc-node4-ml gdc-node4 <<'JSON' >/dev/null
{"status":"success","data":{"result":[{"metric":{"host":"gdc-node4-ml","validator":"wrong-validator"},"value":[0,"1"]}]}}
JSON
then
  echo 'mislabeled split GPU target satisfied the expected-target check' >&2
  exit 1
fi

verify_expected_target_result gdc-node4-ml gdc-node4 <<'JSON' >/dev/null
{"status":"success","data":{"result":[{"metric":{"host":"gdc-node4-ml","validator":"gdc-node4"},"value":[0,"1"]}]}}
JSON

if verify_linked_gpu_result gdc-node4-ml <<'JSON' >/dev/null
{"status":"success","data":{"result":[]}}
JSON
then
  echo 'missing linked GPU series satisfied the inventory check' >&2
  exit 1
fi

if verify_linked_gpu_freshness_result gdc-node4-ml <<'JSON' >/dev/null
{"status":"success","data":{"result":[{"metric":{"host":"gdc-node4-ml"},"value":[0,"121"]}]}}
JSON
then
  echo 'stale linked GPU series satisfied the freshness check' >&2
  exit 1
fi

verify_linked_gpu_result gdc-node4-ml <<'JSON' >/dev/null
{"status":"success","data":{"result":[{"metric":{"host":"gdc-node4-ml"},"value":[0,"1"]}]}}
JSON
verify_linked_gpu_freshness_result gdc-node4-ml <<'JSON' >/dev/null
{"status":"success","data":{"result":[{"metric":{"host":"gdc-node4-ml"},"value":[0,"120"]}]}}
JSON

source_dashboard="$ROOT/04-ops/edge-node/public-grafana/dashboards/gdc-inference.json"
served_dashboard() {
  jq -c --argjson id 7 --argjson version 42 '{meta: {provisioned: true}, dashboard: (. + {id: $id, version: $version})}' "$source_dashboard"
}

served_dashboard | verify_dashboard_matches_source "$source_dashboard" \
  || { echo 'the committed definition with Grafana-owned id and version failed the source check' >&2; exit 1; }

if served_dashboard | jq -c '.dashboard.panels[0].title = "renamed panel"' | verify_dashboard_matches_source "$source_dashboard"
then
  echo 'a served dashboard with a changed panel satisfied the source check' >&2
  exit 1
fi

if served_dashboard | jq -c 'del(.dashboard.panels[-1])' | verify_dashboard_matches_source "$source_dashboard"
then
  echo 'a served dashboard missing a panel satisfied the source check' >&2
  exit 1
fi

if served_dashboard | jq -c '.dashboard.panels[1].targets[0].expr = "vector(1)"' | verify_dashboard_matches_source "$source_dashboard"
then
  echo 'a served dashboard with a changed query satisfied the source check' >&2
  exit 1
fi

# Grafana serves a committed 0.70 as 0.7. That is the same definition, not drift;
# a changed value still is.
numeric_source='{"panels":[{"id":1,"fieldConfig":{"defaults":{"thresholds":{"steps":[{"value":0.70}]}}}}]}'
verify_dashboard_matches_source <(printf '%s\n' "$numeric_source") \
  <<<'{"dashboard":{"id":3,"version":1,"panels":[{"id":1,"fieldConfig":{"defaults":{"thresholds":{"steps":[{"value":0.7}]}}}}]}}' \
  || { echo 'a number Grafana wrote back as 0.7 failed the source check against 0.70' >&2; exit 1; }
if verify_dashboard_matches_source <(printf '%s\n' "$numeric_source") \
  <<<'{"dashboard":{"panels":[{"id":1,"fieldConfig":{"defaults":{"thresholds":{"steps":[{"value":0.8}]}}}}]}}'
then
  echo 'a served dashboard with a changed threshold satisfied the source check' >&2
  exit 1
fi

board_with() {
  jq -cn --argjson panels "$1" '{dashboard: {uid: "gdc-test", panels: $panels}}'
}

pinned='sum(up{job="gonka-node"} == 1)'
present_panel='[{"id":1,"title":"Nodes online","targets":[{"expr":"sum(up{job=\"gonka-node\"} == 1)"}]}]'
other_panel='[{"id":1,"title":"Chain height","targets":[{"expr":"max(cometbft_consensus_height)"}]}]'

board_with "$present_panel" | verify_required_expression_on_board "$pinned" >/dev/null \
  || { echo 'a pinned expression present on the board failed the drift check' >&2; exit 1; }

if board_with "$other_panel" | verify_required_expression_on_board "$pinned" >/dev/null
then
  echo 'a pinned expression absent from the board satisfied the drift check' >&2
  exit 1
fi

# A panel explains an empty result through a noValue field or a description.
# Anything else must be reported as unexplained.
inventory_state() {
  board_with "$1" | dashboard_panel_inventory gdc-test | cut -f4
}

[[ "$(inventory_state '[{"id":7,"title":"Bare","targets":[{"expr":"up"}]}]')" == unexplained ]] \
  || { echo 'a panel with neither noValue nor description was not reported as unexplained' >&2; exit 1; }

[[ "$(inventory_state '[{"id":7,"title":"With noValue","fieldConfig":{"defaults":{"noValue":"no series"}},"targets":[{"expr":"up"}]}]')" == explained ]] \
  || { echo 'a panel carrying noValue was not accepted as explained' >&2; exit 1; }

[[ "$(inventory_state '[{"id":7,"title":"With description","description":"empty until traffic flows","targets":[{"expr":"up"}]}]')" == explained ]] \
  || { echo 'a panel carrying a description was not accepted as explained' >&2; exit 1; }

[[ "$(inventory_state '[{"id":7,"title":"Empty strings","description":"","fieldConfig":{"defaults":{"noValue":""}},"targets":[{"expr":"up"}]}]')" == unexplained ]] \
  || { echo 'empty description and noValue strings were accepted as an explanation' >&2; exit 1; }

# Rows and text panels carry no query and must not enter the judgement at all.
[[ -z "$(board_with '[{"id":100,"type":"row","title":"Network now"},{"id":99,"type":"text","title":"Data contract"}]' | dashboard_panel_inventory gdc-test)" ]] \
  || { echo 'a row or text panel entered the panel judgement' >&2; exit 1; }

# The classifier decides the deploy. Feed it each shape it must tell apart,
# including the two that must never be confused: a query that failed and a query
# that succeeded with nothing in it.
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
populated="$(b64 '{"status":"success","data":{"result":[{"value":[0,"1"]}]}}')"
empty="$(b64 '{"status":"success","data":{"result":[]}}')"
errored="$(b64 '{"status":"error","errorType":"bad_data"}')"
allnan="$(b64 '{"status":"success","data":{"result":[{"metric":{},"value":[0,"NaN"]}]}}')"
somenan="$(b64 '{"status":"success","data":{"result":[{"metric":{"a":"1"},"value":[0,"NaN"]},{"metric":{"a":"2"},"value":[0,"0"]}]}}')"

classify_line() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$(b64 "$5")" "$6" | classify_panel_results | cut -f1
}

[[ "$(classify_line gdc-network 1 "Chain height" unexplained "max(x)" "$populated")" == data ]] \
  || { echo 'a panel with series was not classified as data' >&2; exit 1; }
[[ "$(classify_line gdc-inference 63 "Requests by outcome" explained "sum(x)" "$empty")" == explained ]] \
  || { echo 'an empty panel that explains itself was not classified as explained' >&2; exit 1; }
[[ "$(classify_line gdc-inference 74 "Executor wins" unexplained "sum(x)" "$empty")" == unexplained ]] \
  || { echo 'an empty panel with no explanation was not classified as unexplained' >&2; exit 1; }
[[ "$(classify_line gdc-network 1 "Chain height" explained "max(x)" QUERY_FAILED)" == failed ]] \
  || { echo 'a failed query was excused as an explained empty panel' >&2; exit 1; }
[[ "$(classify_line gdc-network 1 "Chain height" explained "max(x)" "$errored")" == failed ]] \
  || { echo 'a Prometheus error response was excused as an explained empty panel' >&2; exit 1; }
[[ "$(classify_line gdc-network 1 "Chain height" explained "max(x)" "")" == failed ]] \
  || { echo 'a missing answer was excused as an explained empty panel' >&2; exit 1; }

# A histogram quantile over a window with no observations answers NaN. That is a
# panel with nothing to draw, not a measurement.
[[ "$(classify_line gdc-inference 71 "First content p50" explained "histogram_quantile(0.5, x)" "$allnan")" == explained ]] \
  || { echo 'an all-NaN panel that declares an empty state was not classified as explained' >&2; exit 1; }
[[ "$(classify_line gdc-inference 71 "First content p50" unexplained "histogram_quantile(0.5, x)" "$allnan")" == unexplained ]] \
  || { echo 'an all-NaN panel with no declared empty state was accepted' >&2; exit 1; }
[[ "$(classify_line gdc-inference 71 "First content p50" explained "histogram_quantile(0.5, x)" "$somenan")" == data ]] \
  || { echo 'a vector with one finite value among NaNs was not classified as data' >&2; exit 1; }

# The target checks call prom_query inside while-read loops. An ssh that reads
# stdin would swallow the remaining lines and leave every later host unchecked.
fake_bin="$(mktemp -d)"
trap 'rm -rf "$fake_bin"' EXIT
cat >"$fake_bin/ssh" <<'SSH'
#!/usr/bin/env bash
cat >/dev/null
printf '{"status":"success","data":{"result":[]}}\n'
SSH
chmod +x "$fake_bin/ssh"
checked=0
while IFS= read -r _; do
  (PATH="$fake_bin:$PATH"; GATEWAY_NODE=gdc-node4; prom_query 'up') >/dev/null
  checked=$((checked + 1))
done <<'HOSTS'
gdc-node0
gdc-node1
gdc-node2
HOSTS
[[ "$checked" == 3 ]] || { echo "prom_query consumed the target list: $checked of 3 hosts checked" >&2; exit 1; }

# A panel can carry more than one query; each one is judged on its own.
inventory="$(jq -n '{dashboard:{panels:[{id:7,title:"Two queries",fieldConfig:{defaults:{}},targets:[{refId:"A",expr:"up"},{refId:"B",expr:"sum(up)"}]}]}}' \
  | dashboard_panel_inventory gdc-network | cut -f3,5)"
[[ "$inventory" == $'Two queries [A]\tup\nTwo queries [B]\tsum(up)' ]] \
  || { echo "a panel query after the first was not judged: $inventory" >&2; exit 1; }

printf 'PASS public Grafana target predicates reject aggregate, mislabeled, missing, and stale data\n'
printf 'PASS public Grafana gate judges every query of a panel\n'
printf 'PASS public Grafana target checks read every expected host\n'
printf 'PASS public Grafana gate rejects a drifted pin and an unexplained empty panel\n'
printf 'PASS public Grafana panel classifier separates data, explained absence, unexplained absence and a failed query\n'
printf 'PASS public Grafana source check accepts Grafana-owned fields and rejects changed, missing, or requeried panels\n'
