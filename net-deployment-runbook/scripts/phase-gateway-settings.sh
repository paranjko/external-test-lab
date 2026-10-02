#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"
load_project

action="${1:-}"
[[ "$action" =~ ^(preview|apply)$ ]] || die 'expected: ops gateway-settings preview or apply'
[[ $# -eq 1 ]] || die 'gateway-settings accepts exactly one action'
RUN="$GDC_HOME/runs/${GDC_RUN_ID:-manual}/gateway-settings-$action"
mkdir -p "$RUN"

targets="${GDC_GATEWAY_SETTINGS_TARGETS:-}"
jq -e '
  type == "array" and length > 0 and
  all(.[];
    type == "object" and (keys | sort) == ["id","node","port","secret_file"] and
    (.id | type == "string" and test("^[A-Z][A-Z0-9_-]*$")) and
    (.node | type == "string" and test("^[A-Za-z0-9._-]+$")) and
    (.port | type == "number" and floor == . and . >= 1024 and . <= 65535) and
    (.secret_file | type == "string" and test("^/srv/dai/broker-tests/[a-z0-9-]+/gateway\\.env$"))) and
  ([.[].id] | unique | length) == length
' <<<"$targets" >/dev/null \
  || die 'GDC_GATEWAY_SETTINGS_TARGETS must be a non-empty unique A/B target JSON array'

run_id="${GDC_RUN_ID:-manual}"
[[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die 'GDC run id is unsafe for gateway-settings staging'
stage="/srv/dai/ops/gdc-gateway-settings-$run_id"
attempt="$(date -u +%Y%m%dT%H%M%SZ)-$$"

deploy_helper() {
  local node="$1"
  ssh -n "$node" "install -d -m 0700 '$stage/04-ops' '$stage/scripts'"
  scp -q "$ROOT/04-ops/devshard-settings.py" "$ROOT/04-ops/devshard-instances.py" \
    "$node:$stage/04-ops/" < /dev/null
  scp -q "$ROOT/scripts/devshard-preview.py" "$node:$stage/scripts/" < /dev/null
  ssh -n "$node" "chmod 0700 '$stage/04-ops/'*.py '$stage/scripts/'*.py"
}

while IFS= read -r target; do
  id="$(jq -r '.id' <<<"$target")"
  node="$(jq -r '.node' <<<"$target")"
  port="$(jq -r '.port' <<<"$target")"
  secret_file="$(jq -r '.secret_file' <<<"$target")"
  topology_contains_node "$node" || die "gateway-settings target is not in inventory: $node"
  remote_evidence="$stage/evidence-$id-$action-$attempt"
  local_evidence="$RUN/gateway-settings-$id-$action-$attempt.json"
  deploy_helper "$node"
  preview="$(ssh -n "$node" "python3 '$stage/04-ops/devshard-settings.py' --port '$port' --secret-file '$secret_file' --model '$MODEL_ID' --evidence '$remote_evidence-preview'")" \
    || die "gateway-settings preview failed for $id; retained remote evidence=$remote_evidence-preview"
  jq -e '.schema == "gdc-devshard-settings/1" and .applied == false and (.before_sha256 | test("^[0-9a-f]{64}$")) and (.delta | type == "array")' \
    <<<"$preview" >/dev/null || die "gateway-settings preview receipt is invalid for $id"
  printf '%s\n' "$preview" >"$local_evidence"
  delta_count="$(jq '.delta | length' <<<"$preview")"
  if [[ "$action" == preview || "$delta_count" == 0 ]]; then
    suffix=''
    if [[ "$delta_count" == 0 ]]; then
      suffix=' no-op'
    fi
    printf 'READY gateway-settings %s target=%s delta_fields=%s%s\n' "$action" "$id" "$delta_count" \
      "$suffix"
    continue
  fi
  expected="$(jq -r '.before_sha256' <<<"$preview")"
  applied="$(ssh -n "$node" "python3 '$stage/04-ops/devshard-settings.py' --port '$port' --secret-file '$secret_file' --model '$MODEL_ID' --evidence '$remote_evidence-apply' --apply --expected-sha256 '$expected'")" \
    || die "gateway-settings apply failed for $id; retained remote evidence=$remote_evidence-apply"
  jq -e --arg expected "$expected" '.schema == "gdc-devshard-settings/1" and .applied == true and .outcome == "PASS" and .before_sha256 == $expected and .after_sha256 == .desired_sha256' \
    <<<"$applied" >/dev/null || die "gateway-settings apply receipt is invalid for $id"
  printf '%s\n' "$applied" >"$RUN/gateway-settings-$id-apply-$attempt.json"
  printf 'PASS gateway-settings apply target=%s\n' "$id"
done < <(jq -c '.[]' <<<"$targets")
