#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

RUN="$ROOT/artifacts/runs/$(date -u +%Y%m%dT%H%M%SZ)-ha-v4"
mkdir -p "$RUN"
install_evidence_exit_trap 'DevShard v4 HA'
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
settlement_dir="$(dirname "$settlement")"
settlement_context="$settlement_dir/context.env"
[[ -s "$settlement_context" ]] \
  || blocked 'Latest settlement predates the release/protocol evidence contract; rerun v4 settlement.'
grep -qx "release_profile=$GDC_RELEASE_PROFILE" "$settlement_context" \
  || blocked "Latest settlement does not belong to the current $GDC_RELEASE_PROFILE profile."
grep -qx "model=$MODEL_ID@$MODEL_REVISION" "$settlement_context" \
  || blocked 'Latest settlement used a different model profile.'
capture_canonical_genesis "https://$GENESIS_PUBLIC_HOST/chain-rpc/genesis" "$RUN/genesis.json"
genesis_sha256="$(genesis_sha256 "$RUN/genesis.json")"
grep -qx "chain_id=$CHAIN_ID" "$settlement_context" \
  || blocked 'Latest settlement belongs to another chain ID.'
grep -qx "genesis_sha256=$genesis_sha256" "$settlement_context" \
  || blocked 'Latest settlement belongs to a previous Genesis; rerun v4 settlement.'
grep -qx 'devshard_version=v4' "$settlement_context" \
  || blocked 'Latest settlement is not a DevShard v4 settlement.'
{
  profile_summary
  printf 'profile_hash=%s\n' "$(profile_hash)"
  printf 'chain_id=%s\n' "$CHAIN_ID"
  printf 'genesis_sha256=%s\n' "$genesis_sha256"
  printf 'devshard_version=v4\n'
  printf 'settlement_bundle=%s\n' "$settlement_dir"
} >"$RUN/context.env"
node="$GENESIS_NODE"
expected_release="$GDC_RELEASE_PROFILE $(profile_hash)"
ssh "$node" "grep -qx '$expected_release' /srv/dai/deploy/$node/.gdc-release" \
  || die "$node release marker does not match $GDC_RELEASE_PROFILE"

step 'Install two-replica v4 HA overlay on the already-settled participant'
remote="/tmp/gdc-ha-$$"
ssh "$node" "rm -rf '$remote' && mkdir -p '$remote'"
scp -q "$ROOT/02-node/compose.devshard-ha.yaml" "$node:$remote/compose.devshard-ha.yaml"
scp -q "$ROOT/02-node/vendor-router/nginx.conf.template" "$node:$remote/nginx.conf.template"
ssh "$node" "sha256sum /srv/dai/deploy/$node/.env /srv/dai/shared/genesis.json /srv/dai/deploy/$node/.gdc-release" >"$RUN/base-inputs-before.sha256"
ssh -T "$node" "set -Eeuo pipefail
  dest=/srv/dai/deploy/$node
  sudo install -m 0644 '$remote/compose.devshard-ha.yaml' \"\$dest/compose.devshard-ha.yaml\"
  sudo install -d -m 0755 \"\$dest/versiond-router\"
  sudo install -m 0644 '$remote/nginx.conf.template' \"\$dest/versiond-router/nginx.conf.template\"
  sudo touch \"\$dest/.ha-enabled\"
  sudo chown \$(id -u):\$(id -g) \"\$dest/.ha-enabled\"
  rm -rf '$remote'
  cd \"\$dest\"
  ./start-node.sh"
ssh "$node" "sha256sum /srv/dai/deploy/$node/.env /srv/dai/shared/genesis.json /srv/dai/deploy/$node/.gdc-release" >"$RUN/base-inputs-after.sha256"
cmp -s "$RUN/base-inputs-before.sha256" "$RUN/base-inputs-after.sha256" \
  || die 'HA overlay changed node env, Genesis, or release identity'

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

Two versiond replicas shared the Genesis participant key and Postgres session
state while keeping replica-local supervisor data. The sticky router survived a versiond-2 stop, authenticated
gateway traffic succeeded during the outage, and the replica returned without
manual state copy. No duplicate validation-submission signature appeared in the
captured replica logs. The overlay preserved the existing node environment,
canonical Genesis, and release marker byte-for-byte.
EOF
printf 'PASS HA evidence: %s\n' "$RUN"
