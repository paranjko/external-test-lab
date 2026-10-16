#!/usr/bin/env bash
# Offline rendering only. No transport, service changes or DAPI registration.
set -Eeuo pipefail
[[ $# == 2 && $1 =~ ^gonka1[023456789acdefghjklmnpqrstuvwxyz]{38}$ ]] || {
  echo 'Usage: bash render.sh PARTICIPANT NEW_OUTPUT_DIRECTORY' >&2
  exit 2
}
here=$(cd "$(dirname "$0")" && pwd)
umask 077
mkdir "$2"
jq '.primary' "$here/profiles.json" > "$2/primary-models.json"
jq --arg id "qwen3-4b:$1--local-second" '
  {id:$id,host:"gdc-dual-4b-router",inference_port:5000,poc_port:8080,
   max_concurrent:1,models:.secondary}' "$here/profiles.json" > "$2/secondary-worker.json"
printf 'Rendered candidate only; verify obligations, memory, PoC and serving before acceptance.\n'
