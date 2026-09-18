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

printf 'PASS public Grafana target predicates reject aggregate, mislabeled, missing, and stale data\n'
printf 'PASS public Grafana source check accepts Grafana-owned fields and rejects changed, missing, or requeried panels\n'
