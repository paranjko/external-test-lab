#!/usr/bin/env bash
set -Eeuo pipefail

component="${1:-}"
host="${2:-}"
remote="${3:-}"
render="${4:-}"
[[ "$component" =~ ^[a-z][a-z0-9-]*$ ]] || { echo 'invalid operations component' >&2; exit 2; }
[[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'invalid operations host' >&2; exit 2; }
[[ "$remote" =~ ^/tmp/gdc-ops-[0-9]+$ ]] || { echo 'invalid operations staging path' >&2; exit 2; }
[[ -d "$render" ]] || { echo 'operations render directory is missing' >&2; exit 2; }

if [[ "$component" == faucet ]]; then
  for file in .env faucet.env gateway-reserve-signer.env; do
    [[ -s "$render/$file" ]] || { echo "faucet render $file is missing" >&2; exit 1; }
  done
  # scp does not create its destination directory, unlike rsync. Keep this
  # explicit so a fresh staging tree is as reliable as an existing one.
  ssh "$host" "mkdir -p '$remote/rendered'"
  scp -q "$render/.env" "$render/faucet.env" "$render/gateway-reserve-signer.env" \
    "$host:$remote/rendered/"
else
  rsync -a "$render/" "$host:$remote/rendered/"
fi
