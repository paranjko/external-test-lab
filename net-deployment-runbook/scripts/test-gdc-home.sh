#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
unset GDC_HOME STATE
source "$ROOT/scripts/lib.sh"

expected_default="$(dirname "$ROOT")/net-deployment-data"
[[ "$GDC_HOME" == "$expected_default" ]]
[[ "$STATE" == "$expected_default/state" ]]

override_root="$(mktemp -d)/operator-data"
GDC_HOME="$override_root"
init_gdc_paths
[[ "$GDC_HOME" == "$override_root" ]]
[[ "$STATE" == "$override_root/state" ]]
init_gdc_data_root
select_node_data_home gdc-node1
[[ "$GDC_DATA_ROOT" == "$override_root" ]]
[[ "$GDC_HOME" == "$override_root/gdc-node1" ]]
[[ "$STATE" == "$override_root/gdc-node1/state" ]]
[[ "$(inferenced_runs_path "$GDC_HOME/runs/example/proposal.json")" == /gdc-runs/example/proposal.json ]]
if (inferenced_runs_path /tmp/outside-gdc-home.json >/dev/null 2>&1); then
  echo 'inferenced accepted a file outside GDC_HOME/runs' >&2
  exit 1
fi

relative_root="gdc-test-data-$$"
GDC_HOME="$relative_root"
init_gdc_paths
[[ "$GDC_HOME" == "$PWD/$relative_root" ]]

if GDC_HOME=/ init_gdc_paths 2>/dev/null; then
  echo 'GDC_HOME accepted the filesystem root' >&2
  exit 1
fi
if GDC_HOME=/.. init_gdc_paths 2>/dev/null; then
  echo 'GDC_HOME accepted a path resolving to the filesystem root' >&2
  exit 1
fi

grep -Fq 'ENV_FILE="${GDC_ENV:-$GDC_HOME/.env}"' "$ROOT/scripts/lib.sh"
grep -Fq 'GDC_HOME="$GDC_DATA_ROOT/$node"' "$ROOT/scripts/lib.sh"
grep -Fq 'ENV_FILE="${GDC_ENV:-$GDC_HOME/.env}"' "$ROOT/scripts/deploy-telegram-bot.sh"
grep -Fq 'exec "$BIN" --home "$HOME_DIR" "$@"' "$ROOT/scripts/inferenced.sh"
! grep -Fq 'docker run' "$ROOT/scripts/inferenced.sh"
! grep -R -q 'inferenced_runs_path' "$ROOT/scripts/phase-"*.sh
! grep -R --include='*.sh' --exclude='test-gdc-home.sh' -q '\$ROOT/(state|artifacts)' "$ROOT"
! grep -R --include='*.sh' --exclude='test-gdc-home.sh' -q 'GDC_STATE_DIR' "$ROOT"
[[ ! -e "$ROOT/.env" && ! -e "$ROOT/state" && ! -e "$ROOT/artifacts" ]]

printf 'PASS runtime data is isolated under GDC_HOME\n'
