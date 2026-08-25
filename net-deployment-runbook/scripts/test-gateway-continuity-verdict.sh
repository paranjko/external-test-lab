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
{"height":48,"arrival_height":48,"permit_height":48,"dispatch_height":48,"response_height":48,"arrival_at_ms":1,"permit_at_ms":2,"dispatch_at_ms":3,"response_at_ms":4,"admission":"dispatched_once","response_id":"before","safe_generation":"8:41:Inference","upstream_http_status":200,"window":"before","chain_phase":"Inference","http_code":200}
{"height":49,"arrival_height":49,"permit_height":49,"dispatch_height":49,"response_height":49,"arrival_at_ms":5,"permit_at_ms":6,"dispatch_at_ms":7,"response_at_ms":8,"admission":"dispatched_once","response_id":"immediate-before","safe_generation":"8:41:Inference","upstream_http_status":200,"target_anchor":50,"window":"before","coverage":"immediate-before","chain_phase":"Inference","http_code":200}
{"height":50,"arrival_height":50,"permit_height":50,"dispatch_height":50,"response_height":50,"arrival_at_ms":9,"permit_at_ms":10,"dispatch_at_ms":11,"response_at_ms":12,"admission":"dispatched_once","response_id":"anchor","safe_generation":"8:41:Inference","upstream_http_status":$anchor_code,"target_anchor":50,"window":"anchor","coverage":"at-anchor","chain_phase":"PoCGenerate","http_code":$anchor_code}
{"height":50,"arrival_height":50,"permit_height":50,"dispatch_height":50,"response_height":50,"arrival_at_ms":13,"permit_at_ms":14,"dispatch_at_ms":15,"response_at_ms":16,"admission":"dispatched_once","response_id":"poc","safe_generation":"8:41:Inference","upstream_http_status":$failed_code,"window":"poc","chain_phase":"PoCGenerate","http_code":$failed_code}
{"height":68,"arrival_height":68,"permit_height":68,"dispatch_height":68,"response_height":68,"arrival_at_ms":17,"permit_at_ms":18,"dispatch_at_ms":19,"response_at_ms":20,"admission":"dispatched_once","response_id":"after","safe_generation":"8:41:Inference","upstream_http_status":200,"window":"after","chain_phase":"Inference","http_code":200}
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

# An exact-boundary upstream failure is a real FAIL even when no later
# recovery window was captured. Failure responses need no fabricated ID.
cat >"$WORK/requests.jsonl" <<EOF
{"height":49,"target_anchor":50,"arrival_height":49,"permit_height":68,"dispatch_height":68,"response_height":68,"arrival_at_ms":1,"permit_at_ms":2,"dispatch_at_ms":3,"response_at_ms":4,"admission":"dispatched_once","response_id":"","safe_generation":"8:41:Inference","upstream_http_status":429,"error_class":"upstream_http_429","window":"before","coverage":"immediate-before","chain_phase":"Inference","http_code":429}
EOF
set +e
"$ROOT/scripts/classify-gateway-continuity.sh" "$model" "$WORK/snapshot-ready.json" "$WORK/requests.jsonl" "$WORK/verdict.md"
rc=$?
set -e
[[ "$rc" == 1 ]]
grep -qx '# Gateway continuity: FAIL' "$WORK/verdict.md"
grep -q 'observed continuity failure, not' "$WORK/verdict.md"

# A coherent exact-boundary dispatch attempt can fail at the original client
# deadline without an upstream HTTP response. Classify it before coverage: its
# missing response ID and later windows are consequences of the tested failure.
cat >"$WORK/requests.jsonl" <<EOF
{"height":49,"target_anchor":50,"arrival_height":49,"permit_height":51,"dispatch_height":51,"response_height":0,"arrival_at_ms":1000,"permit_at_ms":1100,"dispatch_at_ms":1100,"response_at_ms":1900,"admission":"dispatch_attempt_failed","response_id":"","safe_generation":"8:41:Inference","upstream_http_status":0,"error":"gateway_dispatch_timeout","error_class":"gateway_dispatch_timeout","window":"before","coverage":"immediate-before","chain_phase":"Inference","http_code":504,"admission_record":{"deadline_ms":1800,"response_at_ms":1900}}
EOF
set +e
"$ROOT/scripts/classify-gateway-continuity.sh" "$model" "$WORK/snapshot-ready.json" "$WORK/requests.jsonl" "$WORK/verdict.md"
rc=$?
set -e
[[ "$rc" == 1 ]]
grep -qx '# Gateway continuity: FAIL' "$WORK/verdict.md"
grep -q 'Terminal dispatch-attempt timeouts: 1' "$WORK/verdict.md"

# A request that remained in the PoC fence until its original deadline is also
# a terminal exact-boundary failure and must precede incomplete-coverage logic.
cat >"$WORK/requests.jsonl" <<EOF
{"height":50,"target_anchor":50,"arrival_height":50,"permit_height":0,"dispatch_height":0,"response_height":0,"arrival_at_ms":1000,"permit_at_ms":0,"dispatch_at_ms":0,"response_at_ms":1900,"admission":"pre_dispatch_rejected","response_id":"","safe_generation":"","upstream_http_status":0,"error":"admission_poc_fence","error_class":"admission_poc_fence","window":"anchor","coverage":"at-anchor","chain_phase":"PoCGenerate","http_code":503,"admission_record":{"deadline_ms":1800,"response_at_ms":1900}}
EOF
set +e
"$ROOT/scripts/classify-gateway-continuity.sh" "$model" "$WORK/snapshot-ready.json" "$WORK/requests.jsonl" "$WORK/verdict.md"
rc=$?
set -e
[[ "$rc" == 1 ]]
grep -qx '# Gateway continuity: FAIL' "$WORK/verdict.md"
grep -q 'Terminal PoC-fence deadline expirations: 1' "$WORK/verdict.md"

write_requests 200
"$ROOT/scripts/classify-gateway-continuity.sh" "$model" "$WORK/snapshot-ready.json" "$WORK/requests.jsonl" "$WORK/verdict.md"
grep -qx '# Gateway continuity: PASS' "$WORK/verdict.md"
grep -q 'Preserved model runtimes: 1' "$WORK/verdict.md"
grep -q 'At-anchor observations: 1' "$WORK/verdict.md"

# A planned anchor cannot substitute for the actual recorded arrival.
jq 'if .coverage == "at-anchor" then .arrival_height = 51 else . end' "$WORK/requests.jsonl" >"$WORK/late.jsonl"
mv "$WORK/late.jsonl" "$WORK/requests.jsonl"
set +e
"$ROOT/scripts/classify-gateway-continuity.sh" "$model" "$WORK/snapshot-ready.json" "$WORK/requests.jsonl" "$WORK/verdict.md"
rc=$?
set -e
[[ "$rc" == 2 ]]
grep -qx '# Gateway continuity: INCONCLUSIVE' "$WORK/verdict.md"

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
grep -Fq 'capture_recovery_readiness' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'preflight_ready_samples < 3' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'preflight_ready_samples == 3' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'GDC_GATEWAY_PREFLIGHT_TIMEOUT_SECONDS must be positive' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'recovery-readiness.jsonl' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'evaluate-recovery-readiness.sh' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'gateway-status-routable.sh' "$ROOT/scripts/evaluate-recovery-readiness.sh"
grep -Fq 'gateway_status_routable' "$ROOT/scripts/evaluate-recovery-readiness.sh"
grep -Fq 'active_unblocked_inference_runtime' "$ROOT/scripts/evaluate-recovery-readiness.sh"
grep -Fq '"$admission" == dispatched_once' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'if (.result.sync_info | has("catching_up"))' "$ROOT/scripts/capture-gateway-observability.sh"
grep -Fq 'host-sync-verdict.sh' "$ROOT/scripts/capture-gateway-observability.sh"
grep -Fq 'host_sync_accepts' "$ROOT/scripts/capture-gateway-observability.sh"
grep -Fq 'public chain RPC identity does not match local CometBFT' "$ROOT/scripts/capture-gateway-observability.sh"
grep -Fq 'public chain RPC identity is not unique' "$ROOT/scripts/capture-gateway-observability.sh"
grep -Fq 'identity_matches:true' "$ROOT/scripts/capture-gateway-observability.sh"
grep -Fq 'contemporaneous canonical reference' "$ROOT/scripts/capture-gateway-observability.sh"
grep -Fq 'artificial lag failures' "$ROOT/scripts/capture-gateway-observability.sh"
grep -Fq 'host_progress_deadline' "$ROOT/scripts/capture-gateway-observability.sh"
grep -Fq 'node_height <= first_height' "$ROOT/scripts/capture-gateway-observability.sh"
grep -Fq 'validator-voting-power.json' "$ROOT/scripts/capture-gateway-observability.sh"
grep -Fq 'every displayed Host must be ACTIVE with positive validator voting power' "$ROOT/scripts/capture-gateway-observability.sh"
grep -Fq 'stopped near-tip Host satisfied synchronized acceptance' "$ROOT/scripts/test-host-sync-verdict.sh"
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
grep -Fq 'curl_topology_resolve+=(--resolve "$host:443:$transport_ip")' "$ROOT/scripts/capture-gateway-observability.sh"
grep -Fq 'rc == 6 || rc == 28' "$ROOT/scripts/capture-gateway-observability.sh"
grep -Fq 'continuity_curl()' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'continuity_ssh()' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'topology_ssh()' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'timeout --foreground --kill-after=2 10' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'timeout --foreground --kill-after=2 15' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'ServerAliveInterval=5 -o ServerAliveCountMax=1' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'continuity_ssh "$GATEWAY_NODE"' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'continuity_ssh "$PUBLIC_EDGE_NODE"' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq -- '--resolve "$GENESIS_PUBLIC_HOST:443:$chain_transport_ip"' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq -- '--resolve "$API_HOST:443:$edge_transport_ip"' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'continuity_curl -fsS "$chain_base/chain-rpc/status"' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'GDC_GATEWAY_CONTINUITY_TIMEOUT_SECONDS:-1800' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'GDC_GATEWAY_CONTINUITY_REQUEST_TIMEOUT_SECONDS:-930' "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq "printf 'continuity_timeout_seconds=%s\\n'" "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq "printf 'request_timeout_seconds=%s\\n'" "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq "printf 'post_success_target=%s\\n'" "$ROOT/scripts/phase-gateway-continuity.sh"
grep -Fq 'use_operator_inventory' "$ROOT/gdc.sh"

printf 'PASS gateway continuity verdict contract\n'
