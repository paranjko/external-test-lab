#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  echo "Usage: $0 --receipt FILE --image sha256:DIGEST" >&2
}

receipt=''
image=''
while (($#)); do
  case "$1" in
    --receipt) receipt="${2:-}"; shift 2 ;;
    --image) image="${2:-}"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done

[[ -f "$receipt" && ! -L "$receipt" && "$image" =~ ^sha256:[a-f0-9]{64}$ ]] || {
  usage
  exit 2
}

expected="$(jq -er '.mlnode.image | capture("@(?<digest>sha256:[a-f0-9]{64})$").digest' "$receipt")" \
  || { echo 'Bootstrap MLNode receipt is invalid' >&2; exit 1; }
[[ "$image" == "$expected" ]] || {
  echo 'Network Node MLNode image does not match the current Bootstrap; complete a normal Host JOIN before adding an ML endpoint' >&2
  exit 1
}
