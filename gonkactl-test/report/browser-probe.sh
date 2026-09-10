#!/usr/bin/env bash
set -uo pipefail

data_root=${1:?persistent data root is required}
probe_root="$data_root/report/browser-probe"
stdout="$probe_root/stdout.log"
stderr="$probe_root/stderr.log"
receipt="$probe_root/receipt.txt"
mkdir -p "$probe_root"

chrome=$(command -v google-chrome)
version=$($chrome --version 2>&1)
mode='headless about:blank; flags=--headless --no-sandbox --disable-gpu --enable-logging=stderr --v=1'
set +e
"$chrome" --headless --no-sandbox --disable-gpu --enable-logging=stderr --v=1 --dump-dom about:blank >"$stdout" 2>"$stderr"
status=$?
set -e
signal=0
if test "$status" -gt 128; then signal=$((status - 128)); fi
first_fatal=$(rg -m1 'FATAL|Trace/breakpoint trap|ERROR' "$stderr" || true)
if test -z "$first_fatal" && test "$signal" -ne 0; then
  first_fatal="process terminated by signal $signal; Chrome emitted no FATAL/ERROR line"
fi
{
  printf 'executable=%s\n' "$chrome"
  printf 'version=%s\n' "$version"
  printf 'execution_mode=%s\n' "$mode"
  printf 'exit_code=%s\n' "$status"
  printf 'signal=%s\n' "$signal"
  printf 'stdout=%s\n' "$stdout"
  printf 'stderr=%s\n' "$stderr"
  printf 'first_fatal=%s\n' "$first_fatal"
} >"$receipt.tmp"
mv "$receipt.tmp" "$receipt"
exit "$status"
