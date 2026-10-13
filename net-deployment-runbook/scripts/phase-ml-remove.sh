#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

NODE="${1:-}"
ML_HOST="${2:-}"
topology_contains_node "$NODE" || die "ml remove expects an alias from GDC_NODE_ALIASES, got: $NODE"
[[ "$ML_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$ML_HOST" != "$NODE" ]] \
  || die 'ml remove requires a distinct ML SSH alias'

# `remove mlnode` is ML-only disposal. A validator donor has a durable remote
# lending record and must be returned by `host start`, which first detaches the
# exact recorded parent and reclaims the existing containers. Never use reset
# as an alternate GPU-return implementation.
lending_state=''
if lending_state="$(ssh -T "$ML_HOST" 'sudo -n bash -s -- gdc-lent-ml-record' <<'REMOTE'
set -Eeuo pipefail
[[ "$1" == gdc-lent-ml-record ]]
record=/srv/dai/deploy/.node-control/lent-ml.json
[[ ! -e "$record" && ! -L "$record" ]] && exit 10
[[ -f "$record" && ! -L "$record" ]] || exit 11
[[ "$(stat -c %u "$record")" == 0 && "$(stat -c %a "$record")" == 600 ]] || exit 11
cat "$record"
REMOTE
)"; then
  if ! jq -e '
    .schema_version == 1 and .kind == "gdc-lent-validator-ml" and
    (.parent_alias | test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
    (.endpoint | test("^[A-Za-z0-9.-]+$")) and
    (.node_id | test("^[A-Za-z0-9][A-Za-z0-9._:-]*$"))
  ' <<<"$lending_state" >/dev/null; then
    printf 'OPERATOR ACTION REQUIRED cannot determine whether %s is a lent validator; leave it unchanged and restore SSH access before retrying\n' "$ML_HOST" >&2
    exit 195
  fi
  printf 'OPERATOR ACTION REQUIRED %s is a lent validator; run gdc host start %s to detach it and restore its validator services\n' "$ML_HOST" "$ML_HOST" >&2
  exit 195
else
  lending_rc=$?
  if [[ "$lending_rc" -ne 10 ]]; then
    printf 'OPERATOR ACTION REQUIRED cannot determine whether %s is a lent validator; leave it unchanged and restore SSH access before retrying\n' "$ML_HOST" >&2
    exit 195
  fi
fi

RUN="$GDC_HOME/runs/${GDC_RUN_ID:-manual}/ml-remove-$NODE-$ML_HOST"
step "Remove ML endpoint $ML_HOST from $NODE"
"$ROOT/scripts/detach-network-ml-host.sh" \
  --network "$NODE" --ml-host "$ML_HOST" --data-root "$GDC_DATA_ROOT" --run-dir "$RUN"

step "Reset detached ML-only Host $ML_HOST"
if ! GDC_HOME="$GDC_DATA_ROOT" GDC_INTERNAL_DATA_ROOT="$GDC_DATA_ROOT" \
  "$ROOT/gdc.sh" host reset "$ML_HOST"; then
  die "$ML_HOST endpoint was detached from $NODE but its Host reset did not complete; inspect it and rerun gdc host reset $ML_HOST"
fi
printf 'PASS detached and reset ML-only Host %s from %s\n' "$ML_HOST" "$NODE"
