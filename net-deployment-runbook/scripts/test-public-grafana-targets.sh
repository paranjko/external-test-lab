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

printf 'PASS public Grafana target predicates reject aggregate, mislabeled, missing, and stale data\n'
