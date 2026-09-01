#!/usr/bin/env bash
# Fence the runbook-owned signer on this Host before activating the recovered
# identity. Failure to prove it is stopped is a hard safety stop.
set -Eeuo pipefail
[[ $# -eq 1 ]] || { echo "Usage: sudo $0 DEPLOY_DIR" >&2; exit 2; }
deploy="$1"
[[ $EUID -eq 0 && -d "$deploy" && -r "$deploy/.env" && -r "$deploy/compose.yaml" ]] || { echo 'invalid signer-fence input' >&2; exit 2; }
docker compose --env-file "$deploy/.env" -f "$deploy/compose.yaml" --profile signer stop tmkms >/dev/null 2>&1 || true
running="$(docker compose --env-file "$deploy/.env" -f "$deploy/compose.yaml" ps -q tmkms 2>/dev/null || true)"
[[ -z "$running" ]] || { echo 'signer_activation_unsafe: existing TMKMS remains running on the recovery Host' >&2; exit 1; }
printf 'PASS existing runbook-owned TMKMS is fenced on recovery Host\n'
