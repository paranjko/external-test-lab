#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
model=Qwen/Qwen3-0.6B

write_requests() {
  local failed_code="${1:-200}"
  cat >"$WORK/requests.jsonl" <<EOF
{"height":48,"window":"before","chain_phase":"Inference","http_code":200}
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

cat >"$WORK/requests.jsonl" <<EOF
{"height":50,"window":"poc","chain_phase":"PoCGenerate","http_code":200}
EOF
set +e
"$ROOT/scripts/classify-gateway-continuity.sh" "$model" "$WORK/snapshot-ready.json" "$WORK/requests.jsonl" "$WORK/verdict.md"
rc=$?
set -e
[[ "$rc" == 2 ]]
grep -qx '# Gateway continuity: INCONCLUSIVE' "$WORK/verdict.md"

printf 'PASS gateway continuity verdict contract\n'
