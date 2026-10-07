#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"
load_project

action="${1:-}"
[[ "$action" =~ ^(preview|apply)$ ]] || die 'expected: ops gateway-settings preview or apply'
[[ $# -eq 1 ]] || die 'gateway-settings accepts exactly one action'
policy="${GDC_GATEWAY_SETTINGS_POLICY:-settings}"
[[ "$policy" =~ ^(settings|fresh-inference|fresh-inference-lifecycle)$ ]] \
  || die 'GDC_GATEWAY_SETTINGS_POLICY must be settings, fresh-inference or fresh-inference-lifecycle'
run_id="${GDC_RUN_ID:-manual}"
[[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die 'GDC run id is unsafe for gateway-settings staging'
[[ "$policy" != fresh-inference-lifecycle ]] || umask 077
if [[ "$policy" == fresh-inference ]]; then
  [[ "$action" == preview ]] || die 'native cache-policy apply requires qualified drain and session preservation'
fi
RUN="$GDC_HOME/runs/${GDC_RUN_ID:-manual}/gateway-settings-$action"
[[ "$policy" != fresh-inference ]] || RUN="$GDC_HOME/runs/${GDC_RUN_ID:-manual}/gateway-cache-$action"
[[ "$policy" != fresh-inference-lifecycle ]] || RUN="$GDC_HOME/runs/${GDC_RUN_ID:-manual}/gateway-cache-lifecycle-$action"
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
if [[ "$policy" == fresh-inference* ]]; then
  jq -e 'all(.[]; (.id == "A" or .id == "B") and
    .secret_file == ("/srv/dai/broker-tests/ds502-" + (.id | ascii_downcase) + "/gateway.env"))' \
    <<<"$targets" >/dev/null || die 'native cache preview requires the exact existing A/B scopes'
fi
approvals="${GDC_GATEWAY_CACHE_APPROVALS:-}"
if [[ "$policy" == fresh-inference-lifecycle && "$action" == apply ]]; then
  jq -e --argjson targets "$targets" '
    type == "array" and length == ($targets | length) and
    all(.[]; type == "object" and (keys | sort) ==
      ["compose_before_sha256","compose_desired_sha256","id","node","port","settings_before_sha256"] and
      (.compose_before_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.compose_desired_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.settings_before_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      . as $approval | any($targets[]; .id == $approval.id and .node == $approval.node and .port == $approval.port)) and
    ([.[].id] | unique | length) == length
  ' <<<"$approvals" >/dev/null || die 'native lifecycle apply requires exact approved target and preimage receipts'
fi

while IFS= read -r node; do
  topology_contains_node "$node" || die "gateway-settings target is not in inventory: $node"
done < <(jq -r '.[].node' <<<"$targets")
stage="/srv/dai/ops/gdc-gateway-settings-$run_id"
attempt="$(date -u +%Y%m%dT%H%M%SZ)-$$"

deploy_helper() {
  local node="$1"
  if [[ "$policy" == fresh-inference-lifecycle ]]; then
    ssh -n "$node" "install -d -m 0700 '$stage'"
  fi
  ssh -n "$node" "install -d -m 0700 '$stage/04-ops' '$stage/scripts'"
  scp -q "$ROOT/04-ops/devshard-settings.py" "$ROOT/04-ops/devshard-instances.py" \
    "$node:$stage/04-ops/" < /dev/null
  scp -q "$ROOT/scripts/devshard-preview.py" "$node:$stage/scripts/" < /dev/null
  if [[ "$policy" == fresh-inference* ]]; then
    scp -q "$ROOT/04-ops/devshard-cache-policy.py" "$node:$stage/04-ops/" < /dev/null
  fi
  if [[ "$policy" == fresh-inference-lifecycle ]]; then
    scp -q "$ROOT/04-ops/devshard-cache-apply.py" "$ROOT/04-ops/devshard-cache-runtime.py" \
      "$ROOT/04-ops/devshard-cache-lifecycle.py" "$ROOT/04-ops/devshard-cache-drain.py" \
      "$ROOT/04-ops/devshard-cache-ledger.py" "$node:$stage/04-ops/" < /dev/null
  fi
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
  if [[ "$policy" == fresh-inference* ]]; then
    compose_file="${secret_file%/gateway.env}/compose.json"
    before="$(ssh -n "$node" "test ! -L '$compose_file' && test \"\$(readlink -f '$compose_file')\" = '$compose_file' && sha256sum '$compose_file'")" \
      || die "native Compose source is unavailable for $id"
    expected="${before%% *}"
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "native Compose digest is invalid for $id"
    if [[ "$policy" == fresh-inference-lifecycle ]]; then
      preview="$(ssh -n "$node" "python3 '$stage/04-ops/devshard-cache-apply.py' --preview --id '$id' --port '$port' --expected-compose-sha256 '$expected'")" \
        || die "native lifecycle preview refused for $id"
      jq -e --arg id "$id" --arg expected "$expected" --argjson port "$port" '
        .schema == "gdc-devshard-cache-lifecycle-preview/1" and .applied == false and .id == $id and
        .port == $port and .before_sha256 == $expected and .qualified_storage == true and
        .image == "ghcr.io/gonka-ai/devshard-gateway@sha256:735240e2f8dfa77c27caf72d4442019c31b33546e047c92ff34bd8286857e4e2" and
        .state_volume == ("gdc-ds502-" + ($id | ascii_downcase) + "-data") and
        (.settings_before_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        (.desired_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        (.delta | type == "array" and length <= 1 and all(.[];
          .field == "DEVSHARD_CHAT_CACHE_MAX_BYTES" and .after == "1"))' \
        <<<"$preview" >/dev/null || die "native lifecycle preview receipt is invalid for $id"
      printf '%s\n' "$preview" >"$local_evidence"
      chmod 0600 "$local_evidence"
      if [[ "$action" == preview ]]; then
        printf 'READY native lifecycle preview target=%s changed=%s, runtime unchanged\n' "$id" "$(jq '.delta | length' <<<"$preview")"
        continue
      fi
      approval="$(jq -c --arg id "$id" '.[] | select(.id == $id)' <<<"$approvals")"
      jq -e --argjson preview "$preview" '
        .compose_desired_sha256 == $preview.desired_sha256 and
        .settings_before_sha256 == $preview.settings_before_sha256 and
        (.compose_before_sha256 == $preview.before_sha256 or
          (($preview.delta | length) == 0 and .compose_desired_sha256 == $preview.before_sha256))' <<<"$approval" >/dev/null \
        || die "native lifecycle approval is stale for $id, no apply dispatch"
      settings_expected="$(jq -r '.settings_before_sha256' <<<"$preview")"
      applied="$(ssh -n "$node" "python3 '$stage/04-ops/devshard-cache-apply.py' --apply --id '$id' --port '$port' --expected-compose-sha256 '$expected' --expected-settings-sha256 '$settings_expected' --evidence '$remote_evidence'")" \
        || die "native lifecycle apply refused or inconclusive for $id, retain private journal=$remote_evidence"
      jq -e --arg id "$id" --argjson preview "$preview" '
        .identity == $id and .schema == "gdc-devshard-cache-lifecycle/1" and .outcome == "PASS" and
        .compose_after_sha256 == $preview.desired_sha256 and
        .settings_restored_sha256 == $preview.settings_before_sha256 and .ledger_preservation.preserved == true and
        .ledger_preservation.schema == "gdc-devshard-ledger-preservation/1"
        or (.id == $id and .schema == "gdc-devshard-cache-policy/1" and .outcome == "NO_CHANGE" and
          .applied == false and .delta == [] and .before_sha256 == $preview.before_sha256 and
          .desired_sha256 == $preview.desired_sha256 and .settings_sha256 == $preview.settings_before_sha256)
      ' <<<"$applied" >/dev/null || die "native lifecycle apply receipt is invalid for $id"
      printf '%s\n' "$applied" >"$RUN/gateway-cache-$id-apply-$attempt.json"
      chmod 0600 "$RUN/gateway-cache-$id-apply-$attempt.json"
      printf 'READY native lifecycle target=%s outcome=%s\n' "$id" "$(jq -r '.outcome' <<<"$applied")"
      continue
    fi
    preview="$(ssh -n "$node" "python3 '$stage/04-ops/devshard-cache-policy.py' --compose '$compose_file' --id '$id' --expected-sha256 '$expected'")" \
      || die "native cache-policy preview refused for $id"
    jq -e --arg expected "$expected" --arg id "$id" '
      .schema == "gdc-devshard-cache-policy/1" and .applied == false and .id == $id and
      .before_sha256 == $expected and (.desired_sha256 | test("^[0-9a-f]{64}$")) and
      (.delta | type == "array")' <<<"$preview" >/dev/null || die "native cache preview receipt is invalid for $id"
    printf '%s\n' "$preview" >"$local_evidence"
    chmod 0600 "$local_evidence"
    printf 'READY native cache preview target=%s changed=%s, runtime unchanged\n' \
      "$id" "$(jq '.delta | length' <<<"$preview")"
    continue
  fi
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
