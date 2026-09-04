#!/usr/bin/env bash
# Atomically switch the active data pointer only after a signerless canary is
# stopped. The journal makes the only crash-recovery branches explicit.
set -Eeuo pipefail

[[ $# -eq 3 ]] || { echo "Usage: sudo $0 NODE GENERATION_DIR CANONICAL_DIR" >&2; exit 2; }
node="$1"; generation="$2"; canonical="$3"
data_root=/srv/dai/data
deploy_root=/srv/dai/deploy
if [[ "${GDC_PROMOTION_TEST_MODE:-false}" == true ]]; then
  test_root="${GDC_PROMOTION_TEST_ROOT:-}"
  [[ "$test_root" =~ ^/tmp/gdc-promotion-test\.[A-Za-z0-9._-]+$ ]] || { echo 'invalid promotion test root' >&2; exit 2; }
  data_root="$test_root/data"
  deploy_root="$test_root/deploy"
  [[ -d "$data_root" && -d "$deploy_root" ]] || { echo 'invalid promotion test layout' >&2; exit 2; }
elif [[ $EUID -ne 0 ]]; then
  echo 'invalid promotion input' >&2
  exit 2
fi
[[ "$node" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo 'invalid promotion input' >&2; exit 2; }
[[ "$generation" =~ ^${data_root//\//\\/}/${node}\.generations/[A-Za-z0-9._-]+$ && "$canonical" == "$data_root/$node" ]] \
  || { echo 'invalid generation path' >&2; exit 2; }
[[ -d "$generation/inference" ]] || { echo 'state-sync generation has no inference data' >&2; exit 1; }

deploy="$deploy_root/$node"
next="${canonical}.next"
receipt="$deploy/.promotion-receipt.json"
data_parent="$(dirname "$canonical")"
[[ -d "$deploy" && -s "$deploy/.env" && -d "$data_parent" ]] || { echo 'deployment environment is absent' >&2; exit 1; }
[[ "$(df -P "$(dirname "$generation")" | awk 'NR == 2 {print $1}')" == "$(df -P "$data_parent" | awk 'NR == 2 {print $1}')" ]] \
  || { echo 'promotion_pointer_conflict: generation and active pointer are on different filesystems' >&2; exit 1; }

if ! running="$(docker compose --env-file "$deploy/.env" -f "$deploy/compose.yaml" ps -q node)"; then
  echo 'canary_still_running: cannot inspect node container before promotion' >&2
  exit 1
fi
[[ -z "$running" ]] || { echo 'canary_still_running: refuse promotion while a node container is running' >&2; exit 1; }

active_target() {
  if [[ -L "$canonical" ]]; then
    readlink "$canonical"
  elif [[ -e "$canonical" ]]; then
    echo 'promotion_pointer_conflict: canonical data path is a legacy directory; run the explicit layout migration before JOIN promotion' >&2
    return 2
  fi
}

sync_dir() { sync -f "$1"; }

write_receipt() {
  local state="$1" previous="$2" temporary
  temporary="$(mktemp "$deploy/.promotion-receipt.XXXXXX")"
  chmod 600 "$temporary"
  jq -cn --arg node "$node" --arg generation "$generation" --arg previous "$previous" --arg next "$next" \
    --arg state "$state" --arg recorded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema_version:1,kind:"gdc-state-sync-promotion",state:$state,node_name:$node,generation:$generation,previous_active:(if $previous == "" then null else $previous end),active_next:$next,recorded_at:$recorded_at}' \
    >"$temporary"
  sync -f "$temporary"
  mv -f "$temporary" "$receipt"
  sync_dir "$deploy"
}

set_canonical_env() {
  local temporary
  temporary="$(mktemp "$deploy/.env.XXXXXX")"
  chmod 600 "$temporary"
  awk -v canonical="$canonical" 'BEGIN {seen=0} /^DATA_DIR=/ {print "DATA_DIR=" canonical; seen=1; next} {print} END {if (!seen) exit 1}' "$deploy/.env" >"$temporary" \
    || { rm -f "$temporary"; echo 'promotion_pointer_conflict: deployment environment has no DATA_DIR' >&2; exit 1; }
  sync -f "$temporary"
  mv -f "$temporary" "$deploy/.env"
  sync_dir "$deploy"
}

receipt_state=''
previous=''
if [[ -e "$receipt" ]]; then
  jq -e --arg node "$node" --arg generation "$generation" '
    .schema_version == 1 and .kind == "gdc-state-sync-promotion" and
    .node_name == $node and .generation == $generation and
    (.state == "PROMOTING" or .state == "PROMOTED") and
    (.previous_active == null or (.previous_active | type == "string")) and
    (.active_next | type == "string")
  ' "$receipt" >/dev/null || { echo 'promotion_pointer_conflict: promotion journal is malformed or belongs to another generation' >&2; exit 1; }
  receipt_state="$(jq -r .state "$receipt")"
  previous="$(jq -r '.previous_active // empty' "$receipt")"
fi

current="$(active_target)" || exit $?
if [[ -z "$receipt_state" ]]; then
  [[ ! -e "$next" && ! -L "$next" ]] || { echo 'promotion_pointer_conflict: stale active.next exists without a promotion journal' >&2; exit 1; }
  [[ "$(grep -c "^DATA_DIR=$generation$" "$deploy/.env")" == 1 ]] \
    || { echo 'promotion_pointer_conflict: deployment environment is not bound to this generation' >&2; exit 1; }
  previous="$current"
  ln -s "$generation" "$next"
  sync_dir "$data_parent"
  write_receipt PROMOTING "$previous"
  receipt_state=PROMOTING
fi

if [[ "$receipt_state" == PROMOTED ]]; then
  [[ "$current" == "$generation" ]] || { echo 'promotion_pointer_conflict: promoted journal disagrees with active pointer' >&2; exit 1; }
  grep -qx "DATA_DIR=$canonical" "$deploy/.env" || { echo 'promotion_pointer_conflict: promoted journal disagrees with deployment environment' >&2; exit 1; }
  printf 'READY state-sync generation was already promoted active=%s previous=%s receipt=%s\n' "$canonical" "${previous:-none}" "$receipt"
  exit 0
fi

[[ "$receipt_state" == PROMOTING ]] || { echo 'promotion_pointer_conflict: unsupported promotion journal state' >&2; exit 1; }
if [[ -n "$previous" ]]; then
  [[ "$current" == "$previous" || "$current" == "$generation" ]] \
    || { echo 'promotion_pointer_conflict: active pointer changed outside the recorded promotion' >&2; exit 1; }
else
  [[ -z "$current" || "$current" == "$generation" ]] \
    || { echo 'promotion_pointer_conflict: active pointer changed outside the recorded promotion' >&2; exit 1; }
fi
if [[ "$current" != "$generation" ]]; then
  if [[ -e "$next" || -L "$next" ]]; then
    [[ -L "$next" && "$(readlink "$next")" == "$generation" ]] \
      || { echo 'promotion_pointer_conflict: active.next disagrees with recorded candidate' >&2; exit 1; }
  else
    ln -s "$generation" "$next"
    sync_dir "$data_parent"
  fi
  mv -Tf "$next" "$canonical"
  sync_dir "$data_parent"
fi
[[ -L "$canonical" && "$(readlink "$canonical")" == "$generation" ]] \
  || { echo 'promotion_pointer_conflict: active pointer readback differs from candidate generation' >&2; exit 1; }
set_canonical_env
grep -qx "DATA_DIR=$canonical" "$deploy/.env" \
  || { echo 'promotion_pointer_conflict: deployment environment readback differs from active pointer' >&2; exit 1; }
write_receipt PROMOTED "$previous"
printf 'READY promoted verified state-sync generation active=%s previous=%s receipt=%s\n' "$canonical" "${previous:-none}" "$receipt"
