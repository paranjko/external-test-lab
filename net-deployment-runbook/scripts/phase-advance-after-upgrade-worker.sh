#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project
[[ "$GDC_RELEASE_PROFILE" == v2026.08.06 ]] || die 'follow-up worker target must be v2026.08.06'

proposal_id="${1:-}"
[[ "$proposal_id" =~ ^[1-9][0-9]*$ ]] || die 'usage: advance-after-upgrade-worker <upgrade-proposal-id>'
unit="gdc-advance-after-upgrade-${proposal_id}"

step "Schedule post-upgrade lifecycle worker for proposal $proposal_id"
systemctl --user stop "$unit.service" 2>/dev/null || true
systemctl --user reset-failed "$unit.service" 2>/dev/null || true
systemd-run --user --unit="$unit" --working-directory="$ROOT" \
  --property=TimeoutStartSec=10h --property=Restart=no \
  /usr/bin/env "GDC_HOME=$GDC_HOME" "GDC_ADVANCE_AFTER_UPGRADE_WAIT_SECONDS=${GDC_ADVANCE_AFTER_UPGRADE_WAIT_SECONDS:-28800}" \
  ./gdc.sh --release v2026.08.06 advance-after-upgrade "$proposal_id"

for _ in $(seq 1 20); do
  if systemctl --user is-active --quiet "$unit.service"; then
    cat >"$GDC_HOME/runs/${GDC_RUN_ID}-advance-after-upgrade-worker.md" <<EOF
# Post-upgrade lifecycle worker: SCHEDULED

- Unit: $unit.service
- Upgrade proposal: $proposal_id
- Gate: independently written `# DevNet upgrade: PASS` evidence
- Sequence after the gate: governance, vote, v3 settlement, v4 settlement, HA
EOF
    printf 'SCHEDULED %s.service\n' "$unit"
    exit 0
  fi
  sleep 1
done
systemctl --user status "$unit.service" --no-pager >&2 || true
die "post-upgrade lifecycle worker $unit.service did not become active"
