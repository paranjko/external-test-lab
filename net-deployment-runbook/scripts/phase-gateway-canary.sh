#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

action="${1:-}"
requested_target="${2:-}"
canary_state="$STATE/gateway-canaries/active.env"

load_canary_state() {
  [[ -f "$canary_state" && ! -L "$canary_state" ]] || die 'no retained gateway canary exists'
  # shellcheck disable=SC1090
  source "$canary_state"
  [[ "${schema_version:-}" == 1 && "${kind:-}" == canary \
    && "${phase:-}" =~ ^(preparing|prepared|failed|stopped)$ \
    && "${remote_dir:-}" == /srv/dai/ops/gateway-canaries/* \
    && "${target_version:-}" =~ ^v[45]$ \
    && "${target_port:-}" =~ ^[1-9][0-9]{0,4}$ \
    && "${target_project:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ \
    && ( "${target_escrow_id:-}" =~ ^[1-9][0-9]*$ || "${target_escrow_id:-}" == pending ) ]] \
    || die 'retained gateway canary state is invalid'
  remote_helper="$remote_dir/04-ops/gateway-migration-remote.sh"
}

write_canary_state() {
  local next_phase="$1" escrow="$2"
  write_env "$canary_state" \
    'schema_version=1' 'kind=canary' "phase=$next_phase" \
    "remote_dir=$remote_dir" "target_version=$target_version" \
    "target_port=$target_port" "target_project=$target_project" \
    "target_escrow_id=$escrow"
  chmod 0600 "$canary_state"
}

read_remote_status() {
  ssh -T "$GATEWAY_NODE" "sudo '$remote_helper' canary-status '$remote_dir'"
}

restage_unmaterialized_canary() {
  printf 'WAIT retained gateway canary preparation has no remote manifest; restaging target=%s\n' \
    "$requested_target"
  export GDC_GATEWAY_VERSION="$requested_target"
  export GDC_GATEWAY_CANARY_PREPARE=true
  "$ROOT/scripts/phase-ops.sh" gateway
}

case "$action" in
  prepare)
    [[ "$requested_target" =~ ^v[45]$ ]] || die 'gateway canary prepare requires target v4 or v5'
    if [[ -s "$canary_state" ]]; then
      load_canary_state
      [[ "$requested_target" == "$target_version" ]] || die 'retained gateway canary target conflicts with request'
      if ! remote_status="$(read_remote_status 2>&1)"; then
        if [[ "$phase" == preparing && "$remote_status" == *'gateway canary state is unavailable'* ]]; then
          restage_unmaterialized_canary
          exit 0
        fi
        die "retained gateway canary remote status is unavailable phase=$phase"
      fi
      remote_phase="$(jq -er .phase <<<"$remote_status")"
      target_available="$(jq -r '.target.available // false' <<<"$remote_status")"
      [[ "$target_available" =~ ^(true|false)$ ]] \
        || die 'retained gateway canary availability is invalid'
      [[ "$remote_phase" == prepared && "$target_available" == true ]] && {
        printf 'READY matching gateway canary is already prepared target=%s\n' "$target_version"
        exit 0
      }
      [[ "$remote_phase" =~ ^(prepared|stopped|failed)$ ]] \
        || die "retained gateway canary is not resumable phase=$remote_phase"
      ssh -T "$GATEWAY_NODE" \
        "sudo '$remote_helper' canary-prepare '$remote_dir' '$remote_dir/target.env' '$remote_dir/target-compose.env' '$target_project' '$target_port'"
      remote_status="$(read_remote_status)"
      jq -e '.phase == "prepared" and .target.available == true' <<<"$remote_status" >/dev/null \
        || die 'gateway canary did not become available after resume'
      target_escrow_id="$(jq -er --arg route "/devshard/$target_version" --arg model "$MODEL_ID" '
        [.target.devshards[]? | select(.route_prefix == $route and .model == $model) | .id]
        | unique | if length == 1 then .[0] | tostring else error("ambiguous target escrow") end
      ' <<<"$remote_status")"
      [[ "$target_escrow_id" =~ ^[1-9][0-9]*$ ]] \
        || die 'resumed gateway canary escrow identity is unavailable'
      write_canary_state prepared "$target_escrow_id"
      printf 'READY matching gateway canary resumed target=%s\n' "$target_version"
      exit 0
    fi
    export GDC_GATEWAY_VERSION="$requested_target"
    export GDC_GATEWAY_CANARY_PREPARE=true
    "$ROOT/scripts/phase-ops.sh" gateway
    ;;
  status)
    [[ -z "$requested_target" ]] || die 'gateway canary status takes no target version'
    load_canary_state
    ssh -T "$GATEWAY_NODE" "sudo '$remote_helper' canary-status '$remote_dir'"
    ;;
  stop)
    [[ -z "$requested_target" ]] || die 'gateway canary stop takes no target version'
    load_canary_state
    ssh -T "$GATEWAY_NODE" "sudo '$remote_helper' canary-stop '$remote_dir'"
    write_canary_state stopped "$target_escrow_id"
    ;;
  *) die 'expected gateway canary prepare v4|v5, status, or stop' ;;
esac
