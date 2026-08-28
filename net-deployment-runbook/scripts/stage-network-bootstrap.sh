#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: $0 --bootstrap-file FILE --genesis-dir DIR --state-dir DIR [--secrets-dir DIR]" >&2
}

BOOTSTRAP_FILE=''
GENESIS_DIR=''
STATE_DIR=''
SECRETS_DIR=''
while (($#)); do
  case "$1" in
    --bootstrap-file) BOOTSTRAP_FILE="${2:-}"; shift 2 ;;
    --genesis-dir) GENESIS_DIR="${2:-}"; shift 2 ;;
    --state-dir) STATE_DIR="${2:-}"; shift 2 ;;
    --secrets-dir) SECRETS_DIR="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
[[ -n "$BOOTSTRAP_FILE" && -r "$BOOTSTRAP_FILE" && -n "$GENESIS_DIR" && -n "$STATE_DIR" && -n "$SECRETS_DIR" ]] || { usage; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$STATE_DIR" "$GENESIS_DIR" "$SECRETS_DIR"
temporary="$(mktemp -d "$STATE_DIR/.network-bootstrap.XXXXXX")"
trap 'rm -rf -- "$temporary"' EXIT
python3 "$ROOT/scripts/network-bootstrap.py" stage "$BOOTSTRAP_FILE" "$temporary"
install -m 0600 "$temporary/genesis.json" "$GENESIS_DIR/genesis.json"
sha256sum "$temporary/genesis.json" | awk '{print $1 "  genesis.json"}' >"$GENESIS_DIR/genesis.sha256"
chmod 0600 "$GENESIS_DIR/genesis.sha256"
install -m 0600 "$temporary/genesis-seeds.txt" "$GENESIS_DIR/genesis-seeds.txt"
install -m 0600 "$temporary/bootstrap.env" "$STATE_DIR/network-bootstrap.env"
