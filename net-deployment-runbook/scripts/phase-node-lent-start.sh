#!/usr/bin/env bash
# Start an installed validator. A donor with a durable lending record is first
# detached from its recorded parent; no alias is inferred and no reset occurs.
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"

NODE="${1:-}"
[[ "$NODE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
  echo 'Usage: phase-node-lent-start.sh SSH_ALIAS' >&2
  exit 2
}

record_rc=0
record="$("$ROOT/scripts/read-lent-ml-record.sh" "$NODE")" || record_rc=$?
if [[ "$record_rc" == 10 ]]; then
  exec bash "$ROOT/scripts/node-container-control.sh" start "$NODE"
fi
(( record_rc == 0 )) || exit "$record_rc"
PARENT="$(jq -r .parent_alias <<<"$record")"
ENDPOINT="$(jq -r .endpoint <<<"$record")"
NODE_ID="$(jq -r .node_id <<<"$record")"

RUN="$GDC_HOME/runs/${GDC_RUN_ID:-manual}/node-start-$NODE/lent-ml-release"
mkdir -p "$RUN"
chmod 0700 "$RUN"
printf 'READY reclaiming %s from recorded Network Node %s\n' "$NODE" "$PARENT"

# detach-network-ml-host verifies the parent configuration and DAPI readback
# after DELETE. If it cannot prove removal, reclaim and validator start never
# run, leaving the donor stopped rather than creating competing controllers.
"$ROOT/scripts/detach-network-ml-host.sh" \
  --network "$PARENT" --ml-host "$NODE" --data-root "$GDC_DATA_ROOT" --run-dir "$RUN" \
  --expected-endpoint "$ENDPOINT" --expected-node-id "$NODE_ID"
bash "$ROOT/scripts/node-container-control.sh" reclaim "$NODE"
exec bash "$ROOT/scripts/node-container-control.sh" start "$NODE"
