#!/usr/bin/env bash
set -Eeuo pipefail

usage() { echo "Usage: $0 --json FILE --env FILE --published-root DIR" >&2; }
JSON=''; ENV_FILE=''; PUBLISHED_ROOT=''
while (($#)); do
  case "$1" in
    --json) JSON="${2:-}"; shift 2 ;;
    --env) ENV_FILE="${2:-}"; shift 2 ;;
    --published-root) PUBLISHED_ROOT="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ -r "$JSON" && -r "$ENV_FILE" && -n "$PUBLISHED_ROOT" ]] || { usage; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$ROOT/scripts/network-bootstrap.py" verify "$JSON" >/dev/null
expected_env="$(mktemp)"; trap 'rm -f -- "$expected_env"' EXIT
python3 "$ROOT/scripts/network-bootstrap.py" env "$JSON" >"$expected_env"
cmp -s "$expected_env" "$ENV_FILE" || { echo 'bootstrap ENV does not match deterministic JSON projection' >&2; exit 1; }
chain_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["chain_id"])' "$JSON")"
target="$PUBLISHED_ROOT/$chain_id"; mkdir -p "$PUBLISHED_ROOT"
stage="$(mktemp -d "$PUBLISHED_ROOT/.${chain_id}.XXXXXX")"; trap 'rm -rf -- "$stage"; rm -f -- "$expected_env"' EXIT
install -m 0644 "$JSON" "$stage/bootstrap.json"; install -m 0644 "$ENV_FILE" "$stage/bootstrap.env"
python3 "$ROOT/scripts/network-bootstrap.py" verify "$stage/bootstrap.json" >/dev/null
cmp -s "$expected_env" "$stage/bootstrap.env"
if [[ -d "$target" ]] && cmp -s "$target/bootstrap.json" "$stage/bootstrap.json" && cmp -s "$target/bootstrap.env" "$stage/bootstrap.env"; then
  printf 'PASS published bootstrap pair unchanged chain_id=%s\n' "$chain_id"; exit 0
fi
previous="${target}.previous"; rm -rf -- "$previous"
if [[ -d "$target" ]]; then mv "$target" "$previous"; fi
if ! mv "$stage" "$target"; then
  [[ ! -d "$previous" ]] || mv "$previous" "$target"
  echo "bootstrap pair publication failed chain_id=$chain_id stage=replace" >&2; exit 1
fi
rm -rf -- "$previous"
printf 'PASS atomically published bootstrap pair chain_id=%s json_sha256=%s env_sha256=%s\n' "$chain_id" "$(sha256sum "$target/bootstrap.json" | awk '{print $1}')" "$(sha256sum "$target/bootstrap.env" | awk '{print $1}')"
