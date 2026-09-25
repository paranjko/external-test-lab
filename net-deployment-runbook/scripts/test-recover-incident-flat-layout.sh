#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
incident="$ROOT/scripts/recover-incident.sh"
library="$ROOT/scripts/lib-recovery.sh"

bash -n "$incident" "$library"
grep -Fq 'RECOVERY_REMOTE_COMPOSE_DIR_TEMPLATE="${RECOVERY_REMOTE_COMPOSE_DIR_TEMPLATE:-/srv/dai/deploy}"' "$library"
grep -Fq 'RECOVERY_REMOTE_SOURCE_HOME_TEMPLATE="${RECOVERY_REMOTE_SOURCE_HOME_TEMPLATE:-/srv/dai/data/inference}"' "$library"
grep -Fq 'RECOVERY_REMOTE_TMKMS_STATE_TEMPLATE="${RECOVERY_REMOTE_TMKMS_STATE_TEMPLATE:-/srv/dai/signer/tmkms/state/priv_validator_state.json}"' "$library"
grep -Fq 'test("^/srv/dai/deploy$|^/srv/dai/deploy/' "$incident"
grep -Fq '[[ "$deploy" == /srv/dai/deploy ]] || node="${deploy##*/}"' "$incident"
grep -Fq '[[ "$signer" == /srv/dai/signer/tmkms' "$incident"

# shellcheck disable=SC1090 # The test computes the repository-local script path above.
source "$incident"
valid_source_location node7 /srv/dai/data/inference /srv/dai/data.generations/run-1/inference
! valid_source_location node7 /srv/dai/data/inference /srv/dai/data.generations/../outside/inference
! valid_source_location node7 /srv/dai/data/inference /tmp/inference

printf 'PASS incident handoff accepts the flat JOIN layout and retains bounded legacy paths\n'
