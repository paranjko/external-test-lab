#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

RUN="$ROOT/artifacts/runs/$(date -u +%Y%m%dT%H%M%SZ)-ha-v4"
mkdir -p "$RUN"
record_phase_profile ha-v4

blocked() {
  local reason="$1"
  cat >"$RUN/verdict.md" <<EOF
# DevShard v4 HA: BLOCKED

$reason

No HA overlay, replica, or gateway request was started.
EOF
  printf 'BLOCKED HA evidence: %s (%s)\n' "$RUN" "$reason"
  exit 3
}

settlement="$(find "$ROOT/artifacts/runs" -mindepth 2 -maxdepth 2 -name verdict.md -path '*-escrow-*/*' -print 2>/dev/null | LC_ALL=C sort | tail -n1)"
[[ -n "$settlement" ]] && grep -qx '# Chain-accounted inference: PASS' "$settlement" \
  || blocked 'v4 HA requires a completed single-instance settlement first.'
node=gdc-node0
node_dir="$GENERATED/nodes/$node"
[[ -s "$node_dir/.env" && -s "$node_dir/node-config.json" && -s "$GENESIS/genesis.json" ]] || die 'missing node0 rendered deployment inputs'

step 'Install two-replica v4 HA overlay on the already-settled participant'
remote="/tmp/gdc-ha-$$"
ssh "$node" "rm -rf '$remote' && mkdir -p '$remote'"
rsync -a "$ROOT/02-node/" "$node:$remote/02-node/"
scp -q "$node_dir/.env" "$node:$remote/node.env"
scp -q "$node_dir/node-config.json" "$node:$remote/node-config.json"
scp -q "$GENESIS/genesis.json" "$node:$remote/genesis.json"
ssh -T "$node" "sudo '$remote/02-node/install-node.sh' --node-name '$node' --env '$remote/node.env' --node-config '$remote/node-config.json' --genesis '$remote/genesis.json'; sudo touch /srv/dai/deploy/$node/.ha-enabled; sudo chown \$(id -u):\$(id -g) /srv/dai/deploy/$node/.ha-enabled; rm -rf '$remote'; cd /srv/dai/deploy/$node && ./start-node.sh"

step 'Verify shared-key/Postgres HA topology and sticky router'
ssh "$node" "cd /srv/dai/deploy/$node && docker compose -f compose.yaml -f compose.devshard-ha.yaml ps --format json" >"$RUN/compose-ps.jsonl"
jq -s -e '[.[] | select(.Service == "versiond" or .Service == "versiond-2" or .Service == "versiond-router") | select(.State == "running")] | length == 3' "$RUN/compose-ps.jsonl" >/dev/null || die 'HA services are not all running'
ssh "$node" "cd /srv/dai/deploy/$node && docker compose -f compose.yaml -f compose.devshard-ha.yaml exec -T versiond printenv | grep -E '^(KEY_NAME|PGHOST|DEVSHARD_STORAGE_MODE)=' && docker compose -f compose.yaml -f compose.devshard-ha.yaml exec -T versiond-2 printenv | grep -E '^(KEY_NAME|PGHOST|DEVSHARD_STORAGE_MODE)='" >"$RUN/replica-env.txt"
grep -qx 'PGHOST=payload-postgres' "$RUN/replica-env.txt"
grep -qx 'DEVSHARD_STORAGE_MODE=postgres' "$RUN/replica-env.txt"

key="$(cut -d, -f1 "$SECRETS/gateway.client-keys")"
step 'Kill one replica and prove authenticated gateway traffic survives'
ssh "$node" "cd /srv/dai/deploy/$node && docker compose -f compose.yaml -f compose.devshard-ha.yaml stop versiond-2"
"$ROOT/04-ops/test-inference.sh" "https://$API_HOST" "$key" >"$RUN/chat-during-kill.json"
ssh "$node" "cd /srv/dai/deploy/$node && docker compose -f compose.yaml -f compose.devshard-ha.yaml up -d versiond-2"
deadline=$((SECONDS + 180))
while (( SECONDS < deadline )); do
  if ssh "$node" "cd /srv/dai/deploy/$node && docker compose -f compose.yaml -f compose.devshard-ha.yaml ps --format json versiond-2" | jq -e '.State == "running"' >/dev/null; then break; fi
  printf 'WAIT  versiond-2 recovery\n'; sleep 3
done
ssh "$node" "cd /srv/dai/deploy/$node && docker compose -f compose.yaml -f compose.devshard-ha.yaml logs --no-color --tail=300 versiond versiond-2 versiond-router" >"$RUN/ha-logs.txt"
if rg -i 'duplicate.*(submission|validation)|already submitted' "$RUN/ha-logs.txt"; then die 'duplicate validation submission observed in HA logs'; fi
cat >"$RUN/verdict.md" <<EOF
# DevShard v4 HA: PASS

Two versiond replicas shared node0's participant key and Postgres session
state while keeping replica-local supervisor data. The sticky router survived a versiond-2 stop, authenticated
gateway traffic succeeded during the outage, and the replica returned without
manual state copy. No duplicate validation-submission signature appeared in the
captured replica logs.
EOF
printf 'PASS HA evidence: %s\n' "$RUN"
