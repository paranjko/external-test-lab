#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
reference="${GONKA_REFERENCE:?set GONKA_REFERENCE to a local Gonka repository}"
revision=e9d56e2a4e810788ec4be39725026cd892cf1080
for command in git tar go; do
  command -v "$command" >/dev/null || { echo "required command missing: $command" >&2; exit 2; }
done
git -C "$reference" cat-file -e "$revision^{commit}"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
git -C "$reference" archive "$revision" | tar -xf - -C "$fixture"
cd "$fixture/devshard"
go run "$root/tools/v6-payload-preflight/main.go" "$@"
