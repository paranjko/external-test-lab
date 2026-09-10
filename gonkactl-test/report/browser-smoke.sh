#!/usr/bin/env bash
set -euo pipefail

data_root=${1:?persistent data root is required}
report_root="$data_root/report/render/rerender-run-2"
endpoint_file="$data_root/report/browser-endpoint.txt"
server_log="$data_root/report/browser-server.log"
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
trap 'kill "$server_pid" 2>/dev/null || true' EXIT

for _ in 1 2 3 4 5; do
  test -s "$endpoint_file" && break
  sleep 1
done
port=$(cat "$endpoint_file")
base="http://127.0.0.1:$port"
curl -fsS "$base/awesomeBDD/index.html" >/dev/null
curl -fsS "$base/dashboard/index.html" >/dev/null
curl -fsS "$base/csv/report.csv" >/dev/null
google-chrome --headless --no-sandbox --disable-gpu --dump-dom "$base/awesomeBDD/index.html" | rg -q '<title> gonkactl-test M0 authentic event qualification </title>'
