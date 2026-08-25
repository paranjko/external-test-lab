#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
model=Qwen/Qwen3-0.6B

cat >"$WORK/snapshot-missing.json" <<EOF
{"found":false,"snapshot":{"episode_anchor_height":"50","model_preserved_nodes":[]}}
EOF
cat >"$WORK/requests.jsonl" <<EOF
{"height":49,"target_anchor":50,"window":"before","coverage":"immediate-before","chain_phase":"Inference","http_code":200}
{"height":50,"target_anchor":50,"window":"anchor","coverage":"at-anchor","chain_phase":"PoCGenerate","http_code":200}
{"height":50,"window":"poc","chain_phase":"PoCGenerate","http_code":200}
{"height":68,"window":"after","chain_phase":"Inference","http_code":200}
EOF
set +e
"$ROOT/scripts/classify-gateway-continuity.sh" "$model" "$WORK/snapshot-missing.json" "$WORK/requests.jsonl" "$WORK/verdict.md"
rc=$?
set -e
[[ "$rc" == 2 ]]
grep -qx '# Gateway continuity: INCONCLUSIVE' "$WORK/verdict.md"
grep -q 'not evidence that the model had zero' "$WORK/verdict.md"

write_requests() {
  local failed_code="${1:-200}"
  local anchor_code="${2:-200}"
  cat >"$WORK/requests.jsonl" <<EOF
{"height":48,"window":"before","chain_phase":"Inference","http_code":200}
{"height":49,"target_anchor":50,"window":"before","coverage":"immediate-before","chain_phase":"Inference","http_code":200}
{"height":50,"target_anchor":50,"window":"anchor","coverage":"at-anchor","chain_phase":"PoCGenerate","http_code":$anchor_code}
{"height":50,"window":"poc","chain_phase":"PoCGenerate","http_code":$failed_code}
{"height":68,"window":"after","chain_phase":"Inference","http_code":200}
EOF
}

cat >"$WORK/snapshot-empty.json" <<EOF
{"found":true,"snapshot":{"episode_anchor_height":"50","model_preserved_nodes":[]}}
EOF
write_requests 429
set +e
"$ROOT/scripts/classify-gateway-continuity.sh" "$model" "$WORK/snapshot-empty.json" "$WORK/requests.jsonl" "$WORK/verdict.md"
rc=$?
set -e
[[ "$rc" == 3 ]]
grep -qx '# Gateway continuity: BLOCKED' "$WORK/verdict.md"
grep -q 'no preserved runtime' "$WORK/verdict.md"

cat >"$WORK/snapshot-ready.json" <<EOF
{"found":true,"snapshot":{"episode_anchor_height":"50","model_preserved_nodes":[{"model_id":"$model","participants":[{"participant_id":"gonka1test","node_ids":["node-a"]}]}]}}
EOF
write_requests 429
set +e
"$ROOT/scripts/classify-gateway-continuity.sh" "$model" "$WORK/snapshot-ready.json" "$WORK/requests.jsonl" "$WORK/verdict.md"
rc=$?
set -e
[[ "$rc" == 1 ]]
grep -qx '# Gateway continuity: FAIL' "$WORK/verdict.md"

write_requests 200
"$ROOT/scripts/classify-gateway-continuity.sh" "$model" "$WORK/snapshot-ready.json" "$WORK/requests.jsonl" "$WORK/verdict.md"
grep -qx '# Gateway continuity: PASS' "$WORK/verdict.md"
grep -q 'Preserved model runtimes: 1' "$WORK/verdict.md"
grep -q 'At-anchor observations: 1' "$WORK/verdict.md"

write_requests 200 429
set +e
"$ROOT/scripts/classify-gateway-continuity.sh" "$model" "$WORK/snapshot-ready.json" "$WORK/requests.jsonl" "$WORK/verdict.md"
rc=$?
set -e
[[ "$rc" == 1 ]]
grep -qx '# Gateway continuity: FAIL' "$WORK/verdict.md"

cat >"$WORK/requests.jsonl" <<EOF
{"height":49,"target_anchor":50,"window":"before","coverage":"immediate-before","chain_phase":"Inference","http_code":200}
{"height":50,"window":"poc","chain_phase":"PoCGenerate","http_code":200}
{"height":68,"window":"after","chain_phase":"Inference","http_code":200}
EOF
set +e
"$ROOT/scripts/classify-gateway-continuity.sh" "$model" "$WORK/snapshot-ready.json" "$WORK/requests.jsonl" "$WORK/verdict.md"
rc=$?
set -e
[[ "$rc" == 2 ]]
grep -qx '# Gateway continuity: INCONCLUSIVE' "$WORK/verdict.md"

cat >"$WORK/requests.jsonl" <<EOF
{"height":50,"window":"poc","chain_phase":"PoCGenerate","http_code":200}
EOF
set +e
"$ROOT/scripts/classify-gateway-continuity.sh" "$model" "$WORK/snapshot-ready.json" "$WORK/requests.jsonl" "$WORK/verdict.md"
rc=$?
set -e
[[ "$rc" == 2 ]]
grep -qx '# Gateway continuity: INCONCLUSIVE' "$WORK/verdict.md"

grep -Fq 'capture-poc-snapshot.sh' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'GDC_GATEWAY_CONTINUITY_MIN_LEAD_BLOCKS' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'target_anchor - current_height < minimum_lead_blocks' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'snapshot_pid=$!' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'snapshot_not_captured' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'capture-gateway-observability.sh' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'observability_pids+=("$!")' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'INCONCLUSIVE continuity observability snapshots' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'observability_incomplete=false' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'observability_incomplete=true' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq '"$observability_incomplete" == true && "$verdict_rc" == 0' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'last_post_observation_height' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'height > last_post_observation_height' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq '"$admission" == dispatched_once' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'if (.result.sync_info | has("catching_up"))' "$ROOT/scripts/capture-gateway-observability.sh"
grep -Fq '[[ "$catching" == false ]]' "$ROOT/scripts/capture-gateway-observability.sh"
grep -Fq 'dashboard-results.jsonl' "$ROOT/scripts/capture-gateway-observability.sh"
grep -Fq 'expected Prometheus target is down or mislabeled' "$ROOT/scripts/capture-gateway-observability.sh"
grep -Fq '.data.result[]?' "$ROOT/scripts/capture-gateway-observability.sh"
grep -Fq 'https://$SITE_HOST/status/gateway-health' "$ROOT/scripts/capture-gateway-observability.sh"
grep -Fq 'gateway-status-raw.json' "$ROOT/scripts/capture-gateway-observability.sh"
grep -Fq 'public-health-raw.json' "$ROOT/scripts/capture-gateway-observability.sh"
grep -Fq 'X-Request-Deadline-Ms' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'X-GDC-Dispatch-Height' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'admission_record' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'upstream_http_status' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'error_class' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'arrival_at_ms' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq '"DEGRADED"' "$ROOT/scripts/capture-gateway-observability.sh"
grep -Fq 'curl_dns_retry()' "$ROOT/scripts/capture-gateway-observability.sh"
grep -Fq "grep -q 'Resolving timed out'" "$ROOT/scripts/capture-gateway-observability.sh"

printf 'PASS gateway continuity verdict contract\n'
