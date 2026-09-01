#!/usr/bin/env bash
# Promote a verified generation atomically. The caller has stopped the
# signerless candidate; old data remains as a rollback directory until the
# canonical restart succeeds.
set -Eeuo pipefail
[[ $# -eq 3 ]] || { echo "Usage: sudo $0 NODE GENERATION_DIR CANONICAL_DIR" >&2; exit 2; }
node="$1"; generation="$2"; canonical="$3"
[[ $EUID -eq 0 && "$node" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo 'invalid promotion input' >&2; exit 2; }
[[ "$generation" =~ ^/srv/dai/data/${node}\.generations/[A-Za-z0-9._-]+$ && "$canonical" == "/srv/dai/data/$node" ]] || { echo 'invalid generation path' >&2; exit 2; }
[[ -d "$generation/inference" ]] || { echo 'state-sync generation has no inference data' >&2; exit 1; }
deploy="/srv/dai/deploy/$node"; backup="${canonical}.gdc-rollback.$(date -u +%Y%m%dT%H%M%SZ)"
[[ -d "$deploy" && -s "$deploy/.env" ]] || { echo 'deployment environment is absent' >&2; exit 1; }
grep -qx "DATA_DIR=$generation" "$deploy/.env" || { echo 'deployment is not bound to this generation' >&2; exit 1; }
[[ ! -e "$backup" ]] || { echo 'stale data rollback path exists' >&2; exit 1; }
[[ ! -e "$canonical" ]] || mv "$canonical" "$backup"
mv "$generation" "$canonical"
sed -i "s|^DATA_DIR=.*$|DATA_DIR=$canonical|" "$deploy/.env"
printf 'READY promoted verified state-sync generation canonical=%s rollback=%s\n' "$canonical" "$backup"
