#!/usr/bin/env bash
set -euo pipefail

data_root=${1:?persistent data root is required}
run_id=${2:?qualification run id is required}
report_root=${3:-"$data_root/report/render/$run_id"}
results_root="$data_root/report/results/$run_id"
endpoint_file="$data_root/report/browser-endpoint.txt"
server_log="$data_root/report/browser-server.log"
browser_root="$data_root/report/browser-smoke"
profile="$browser_root/profiles/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$profile"
rm -f "$endpoint_file"

python3 - "$report_root" "$endpoint_file" >"$server_log" 2>&1 <<'PY' &
import functools
import http.server
import pathlib
import sys
root, endpoint = sys.argv[1:]
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=root)
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
pathlib.Path(endpoint).write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
PY
server_pid=$!
cleanup() { kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; }
trap cleanup EXIT
for _ in 1 2 3 4 5; do test -s "$endpoint_file" && break; sleep 1; done
test -s "$endpoint_file"
port=$(<"$endpoint_file")
base="http://127.0.0.1:$port"
curl -fsS "$base/awesomeBDD/index.html" >/dev/null
curl -fsS "$base/dashboard/index.html" >/dev/null
curl -fsS "$base/csv/report.csv" >/dev/null
test -n "$(find "$report_root/awesomeBDD" -type f \( -name '*.js' -o -name '*.css' \) -print -quit)"
test "$(find "$results_root" -maxdepth 1 -name '*-result.json' | wc -l)" -eq 4
rg -q '"steps": \[' "$results_root"/*-result.json
rg -q '"attachments": \[' "$results_root"/*-result.json
if rg -q '"start": 0|"stop": 0' "$results_root"/*-result.json; then echo 'zero placeholder timing found' >&2; exit 1; fi
node "$(dirname "$0")/browser-check.mjs" \
  --url "$base/awesomeBDD/index.html" --bundle "$report_root/awesomeBDD" \
  --evidence-dir "$browser_root" --profile "$profile"
