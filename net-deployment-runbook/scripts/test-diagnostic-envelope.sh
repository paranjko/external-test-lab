#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENVELOPE="$ROOT/scripts/diagnostic-envelope.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

safe="$tmp/diagnostic-envelope.v1.json"
"$ENVELOPE" write "$safe" join join-node failed interrupted network curl 28 safe join-repeat 'network readback timed out'
"$ENVELOPE" validate "$safe"
[[ "$(stat -c '%a' "$safe")" == 600 ]]
jq -e '.resume.decision == "safe" and .resume.token == "join-repeat"' "$safe" >/dev/null

for mutation in \
  '.summary = ("x" * 241)' \
  '.resume.token = "curl"' \
  '.unknown = "x"' \
  '.phase = "<script>"'; do
  hostile="$tmp/hostile-$RANDOM.json"
  jq "$mutation" "$safe" >"$hostile"
  chmod 0600 "$hostile"
  if "$ENVELOPE" validate "$hostile" >/dev/null 2>&1; then
    echo "hostile diagnostic envelope unexpectedly validated: $mutation" >&2
    exit 1
  fi
done

if "$ENVELOPE" write "$tmp/unsafe.json" join join-node failed interrupted network curl 28 safe none 'unsafe resume token' >/dev/null 2>&1; then
  echo 'unsafe resume token unexpectedly wrote an envelope' >&2
  exit 1
fi

printf 'PASS diagnostic envelope schema, bounds, permissions, and resume allowlist\n'
