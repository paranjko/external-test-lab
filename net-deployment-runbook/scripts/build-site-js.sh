#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/04-ops/site/src"
DESTINATION="$ROOT/04-ops/site"
FLOW_VERSION="${FLOW_VERSION:-0.281.0}"
FLOW_REMOVE_TYPES_VERSION="${FLOW_REMOVE_TYPES_VERSION:-2.281.0}"
PRETTIER_VERSION="${PRETTIER_VERSION:-3.6.2}"
MODE=--write
DESTINATION="$ROOT/04-ops/site"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --write|--check) MODE="$1" ;;
    --output)
      DESTINATION="${2:-}"
      [[ -n "$DESTINATION" ]] || { echo 'missing value for --output' >&2; exit 2; }
      shift
      ;;
    *) echo "Usage: $0 [--write|--check] [--output DIRECTORY]" >&2; exit 2 ;;
  esac
  shift
done

DESTINATION="$(realpath -m -- "$DESTINATION")"

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
  # Generated assets are compared byte-for-byte with the public deployment.
  # A globally installed Prettier is not a reproducible build input, so always
  # use the version fixed above.
  npx --yes "prettier@$PRETTIER_VERSION" "$@"
}

(
  cd "$ROOT"
  run_flow check --max-warnings 0
)

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
    host-state.js \
    software-versions.js
)

files=(app.js config.js gateway-state.js host-state.js software-versions.js)
generated_files=()
for file in "${files[@]}"; do
  sed -i "1s|^//  strict$|// Generated from src/$file - edit the Flow source and run make site-js|" "$output/$file"
  header_normalized="$(mktemp "$output/.${file}.XXXXXX")"
  awk '
    NR == 1 { print; header = 1; next }
    header && $0 == "" { next }
    header { print ""; header = 0 }
    { print }
  ' "$output/$file" >"$header_normalized"
  mv "$header_normalized" "$output/$file"
  generated_files+=("$output/$file")
done

run_prettier --write --log-level silent "${generated_files[@]}"

for file in "${files[@]}"; do
  node --check "$output/$file"
  if [[ "$MODE" == '--check' && -f "$DESTINATION/$file" ]]; then
    cmp "$DESTINATION/$file" "$output/$file"
  fi
done

if [[ "$MODE" == '--check' ]]; then
  echo 'PASS Flow types and generated public-site JavaScript'
else
  echo "READY generated browser JavaScript in $DESTINATION"
fi
