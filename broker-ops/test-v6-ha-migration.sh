#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
reference="${GONKA_REFERENCE:?set GONKA_REFERENCE to a local Gonka repository}"
revision=e9d56e2a4e810788ec4be39725026cd892cf1080
for command in git tar go docker python3; do
  command -v "$command" >/dev/null || { echo "required verification command missing: $command" >&2; exit 2; }
done
docker info >/dev/null
git -C "$reference" cat-file -e "$revision^{commit}"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
# Export immutable bytes, never edit or build in the reference checkout.
git -C "$reference" archive "$revision" | tar -xf - -C "$fixture"
python3 - "$fixture" "$root/fixtures" <<'PY'
import json, pathlib, sys
root, source = map(pathlib.Path, sys.argv[1:])
files = sorted(source.glob('v6-ha-*_test.go'))
if len(files) != 2:
    raise SystemExit('expected both session and payload qualification fixtures')
(root / 'lab-overlay.json').write_text(json.dumps({'Replace': {
    str(root / 'devshard/storage' / ('lab_' + file.name.replace('-', '_'))): str(file)
    for file in files}}))
PY
cd "$fixture/devshard"
go test -count=1 -timeout=12m -overlay="$fixture/lab-overlay.json" ./storage -run '^TestV6HAMigrationPostgres' -v
go test -count=1 -timeout=6m "$root/tools/v6-payload-preflight/main.go" "$root/tools/v6-payload-preflight/main_test.go" -v
