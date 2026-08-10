#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/04-ops/site/src"
DESTINATION="$ROOT/04-ops/site"
FLOW_VERSION="${FLOW_VERSION:-0.281.0}"
FLOW_REMOVE_TYPES_VERSION="${FLOW_REMOVE_TYPES_VERSION:-2.281.0}"
PRETTIER_VERSION="${PRETTIER_VERSION:-3.6.2}"
MODE="${1:---write}"

case "$MODE" in
  --write | --check) ;;
  *)
    echo "Usage: $0 [--write|--check]" >&2
    exit 2
    ;;
esac

run_flow() {
  if command -v flow >/dev/null 2>&1; then
    flow "$@"
  else
    npx --yes "flow-bin@$FLOW_VERSION" "$@"
  fi
}

run_flow_remove_types() {
  if command -v flow-remove-types >/dev/null 2>&1; then
    flow-remove-types "$@"
  else
    npx --yes "flow-remove-types@$FLOW_REMOVE_TYPES_VERSION" "$@"
  fi
}

run_prettier() {
  if command -v prettier >/dev/null 2>&1; then
    prettier "$@"
  else
    npx --yes "prettier@$PRETTIER_VERSION" "$@"
  fi
}

run_flow check --max-warnings 0

output="$DESTINATION"
temporary_output=''
if [[ "$MODE" == '--check' ]]; then
  temporary_output="$(mktemp -d)"
  trap 'rm -rf "$temporary_output"' EXIT
  output="$temporary_output"
fi

(
  cd "$SOURCE"
  run_flow_remove_types --pretty --quiet --out-dir "$output" \
    app.js \
    config.js \
    gateway-state.js \
    software-versions.js
)

files=(app.js config.js gateway-state.js software-versions.js)
generated_files=()
for file in "${files[@]}"; do
  sed -i "1s|^//  strict$|// Generated from src/$file - edit the Flow source and run make site-js|" "$output/$file"
  generated_files+=("$output/$file")
done

run_prettier --write --log-level silent "${generated_files[@]}"

for file in "${files[@]}"; do
  node --check "$output/$file"
  if [[ "$MODE" == '--check' ]]; then
    cmp "$DESTINATION/$file" "$output/$file"
  fi
done

if [[ "$MODE" == '--check' ]]; then
  echo 'PASS Flow types and generated public-site JavaScript'
else
  echo "READY generated browser JavaScript in $DESTINATION"
fi
