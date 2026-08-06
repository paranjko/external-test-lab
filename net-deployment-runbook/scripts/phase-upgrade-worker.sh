#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
[[ "$GDC_RELEASE_PROFILE" == testnet-0.2.15 ]] || die 'upgrade worker target must be testnet-0.2.15'
PROPOSAL_ID="${1:-}"
[[ "$PROPOSAL_ID" =~ ^[1-9][0-9]*$ ]] || die 'usage: upgrade-worker <passed-proposal-id>'
require_current_baseline_pass

UNIT="gdc-upgrade-proposal-${PROPOSAL_ID}"
step "Schedule state-based upgrade worker for proposal $PROPOSAL_ID"
systemctl --user stop "$UNIT.service" 2>/dev/null || true
systemctl --user stop "$UNIT.timer" 2>/dev/null || true
systemctl --user reset-failed "$UNIT.service" 2>/dev/null || true
systemd-run --user --unit="$UNIT" --on-active=5s --working-directory="$ROOT" \
  --property=TimeoutStartSec=6h --property=Restart=on-failure --property=RestartSec=30s \
  /usr/bin/env "GDC_UPGRADE_PROPOSAL_ID=$PROPOSAL_ID" GDC_UPGRADE_WAIT=true \
  "GDC_UPGRADE_WAIT_SECONDS=${GDC_UPGRADE_WAIT_SECONDS:-21600}" \
  ./gdc.sh --release testnet-0.2.15 upgrade

for _ in $(seq 1 20); do
  if systemctl --user is-active --quiet "$UNIT.timer"; then
    cat >"$ROOT/artifacts/runs/${GDC_RUN_ID}-upgrade-worker.md" <<EOF
# Upgrade worker: SCHEDULED

- Unit: $UNIT.service
- Timer: $UNIT.timer
- Passed proposal: $PROPOSAL_ID
- Target profile: testnet-0.2.15
- State source: node0 loopback RPC over SSH
- Delayed start: 5 seconds, after the scheduling command releases its lifecycle lock
- Restart policy: on-failure, 30 seconds
EOF
    printf 'SCHEDULED %s.timer -> %s.service\n' "$UNIT" "$UNIT"
    exit 0
  fi
  sleep 1
done
systemctl --user status "$UNIT.timer" "$UNIT.service" --no-pager >&2 || true
die "upgrade worker $UNIT.timer was not scheduled"
