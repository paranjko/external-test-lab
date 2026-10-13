#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 3 ]] || { echo "Usage: $0 STAGING_DIR SSH_ALIAS PROXY_BIND_ADDRESS" >&2; exit 2; }
staging="$1"
status=0
if sudo "$staging/edge/reconcile-proxy-ingress.sh" "$2" "$3"; then :; else
  status=$?
fi
cleanup_status=0
if rm -rf -- "$staging"; then :; else
  cleanup_status=$?
fi
if (( status != 0 )); then
  exit "$status"
fi
exit "$cleanup_status"
