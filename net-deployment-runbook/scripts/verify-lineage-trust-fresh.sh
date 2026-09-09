#!/usr/bin/env bash
# Refuse to consume a stale state-sync trust decision. This is intentionally
# dependency-light because it runs locally before canary launch and on the
# Host before canary acceptance.
set -Eeuo pipefail

[[ $# -eq 1 && -r "$1" ]] || { echo "Usage: $0 LINEAGE_RECEIPT" >&2; exit 2; }
expires_at="$(jq -er '.bootstrap.trust.expires_at // empty' "$1" 2>/dev/null || true)"
expires_epoch="$(date -u -d "$expires_at" +%s 2>/dev/null || true)"
now_epoch="$(date -u +%s)"
[[ "$expires_epoch" =~ ^[0-9]+$ && "$expires_epoch" -gt "$now_epoch" ]] || {
  echo 'lineage_trust_expired: state-sync trust receipt has expired; run a fresh JOIN lineage preflight before starting or accepting the canary' >&2
  exit 1
}
printf 'PASS lineage trust remains fresh until %s\n' "$expires_at"
