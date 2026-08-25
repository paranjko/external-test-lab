#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
# Reset needs both public-observability hosts and the deployment inventory for
# the pre-reset chain snapshot. Loading only .env leaves topology-derived state
# unset under `set -u` before any host has been touched.
load_project
load_public_observability_hosts
reset_nodes=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      reset_confirmed=true
      shift
      ;;
    --hosts)
      [[ -n "${2:-}" ]] || die 'reset --hosts requires a comma-separated SSH alias list'
      IFS=',' read -r -a reset_nodes <<<"$2"
      shift 2
      ;;
    *)
      die 'reset accepts only --yes and optional --hosts <SSH_ALIAS[,SSH_ALIAS...]>'
      ;;
  esac
done
[[ "${reset_confirmed:-false}" == true ]] || die 'reset destroys the rehearsal; run ./gdc.sh reset --yes'
if (( ${#reset_nodes[@]} == 0 )); then
  reset_nodes=("${GDC_NODES[@]}")
fi
declare -A reset_node_seen=()
for host in "${reset_nodes[@]}"; do
  topology_contains_node "$host" || die "reset --hosts contains an unknown SSH alias: $host"
  [[ -z "${reset_node_seen[$host]:-}" ]] || die "reset --hosts repeats SSH alias: $host"
  reset_node_seen["$host"]=true
done
[[ -n "${reset_node_seen[$GENESIS_NODE]:-}" ]] || die "reset --hosts must include the Genesis node: $GENESIS_NODE"
CHROME_BIN="${CHROME_BIN:-google-chrome}"
command -v "$CHROME_BIN" >/dev/null || die 'reset requires google-chrome for public reset-state evidence; install it or set CHROME_BIN before destructive work'
MANIFEST_DIR="$GDC_HOME/reset-manifests/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$MANIFEST_DIR"

snapshot_run_evidence() {
  local output="$1"
  local -a find_args=(runs -type f)
  if [[ -n "${GDC_RUN_ID:-}" ]]; then
    # Reset writes its lifecycle log to <run-id>/ and its browser evidence to
    # <run-id>-homepage/. Neither is prior evidence, so both must be excluded
    # from the before/after integrity comparison.
    find_args+=(
      ! -path "runs/$GDC_RUN_ID/*"
      ! -path "runs/$GDC_RUN_ID-homepage/*"
    )
  fi
  (
    cd "$GDC_HOME"
    # `reset` itself now has normal lifecycle evidence under GDC_RUN_ID.  It
    # is not prior evidence and naturally changes while this phase runs.
    # Excluding only that active bundle preserves the cross-reset integrity
    # check for every earlier bundle without making reset self-conflicting.
    find "${find_args[@]}" -print0 2>/dev/null \
      | LC_ALL=C sort -z \
      | xargs -0 -r sha256sum
  ) >"$output"
}

reset_started_at="$(date -u +%FT%TZ)"
pre_reset_chain_id=UNAVAILABLE
pre_reset_genesis_sha256=UNAVAILABLE
if capture_canonical_genesis "https://${GENESIS_PUBLIC_HOST}/chain-rpc/genesis" "$MANIFEST_DIR/pre-reset-genesis.json"; then
  pre_reset_chain_id="$(jq -er '.chain_id' "$MANIFEST_DIR/pre-reset-genesis.json")"
  pre_reset_genesis_sha256="$(genesis_sha256 "$MANIFEST_DIR/pre-reset-genesis.json")"
fi
{
  printf 'reset_started_at=%s\n' "$reset_started_at"
  printf 'pre_reset_chain_id=%s\n' "$pre_reset_chain_id"
  printf 'pre_reset_genesis_sha256=%s\n' "$pre_reset_genesis_sha256"
} >"$MANIFEST_DIR/pre-reset.env"
snapshot_run_evidence "$MANIFEST_DIR/runs.before.sha256"

preservation_manifest() {
  local host="$1" phase="$2"
  ssh "$host" 'set -Eeuo pipefail
    docker image ls --no-trunc --format "{{.ID}} {{.Repository}}:{{.Tag}}" | LC_ALL=C sort
    printf "%s\\n" "-- hf-cache --"
    if [[ -d /srv/dai/hf-cache ]]; then
      find /srv/dai/hf-cache -type f -printf "%P %s %T@\n" | LC_ALL=C sort
    fi
    printf "%s\n" "-- preserved-secondary-state --"
    if [[ -d /srv/dai/gonka-devnet-bot ]]; then
      find /srv/dai/gonka-devnet-bot -maxdepth 2 -type f -name "*.db" -printf "telegram/%P %s %m\n" | LC_ALL=C sort
    fi' >"$MANIFEST_DIR/$host.$phase"
}

genesis_reset=false
managed_aliases=("${reset_nodes[@]}")
for node in "${reset_nodes[@]}"; do
  ml_host="$(node_ml_host "$node" || true)"
  [[ -z "$ml_host" ]] || managed_aliases+=("$ml_host")
done
managed_aliases_serialized="${managed_aliases[*]}"
printf '%s\n' "${reset_nodes[@]}" >"$MANIFEST_DIR/reset-hosts.txt"
for host in "${reset_nodes[@]}"; do
  step "Reset $host"
  if ! ssh_ready "$host"; then
    echo "SKIP  $host is unreachable"
    continue
  fi
  preservation_manifest "$host" before
  reset_remote_env="GDC_RESET_MANAGED_ALIASES=$(printf '%q' "$managed_aliases_serialized")"
  # The public edge is independent of the chain lifecycle. Keep its TLS
  # listener and static site available while the network is reset.
  if [[ "$host" == "$PUBLIC_EDGE_NODE" ]]; then
    reset_remote_env+=" GDC_RESET_PRESERVE_PUBLIC_EDGE=true"
  fi
  ssh "$host" "sudo env $reset_remote_env bash -s" \
    <"$ROOT/scripts/reset-remote-host.sh"
  preservation_manifest "$host" after
  cmp -s "$MANIFEST_DIR/$host.before" "$MANIFEST_DIR/$host.after" || die "$host reset changed Docker image IDs or /srv/dai/hf-cache; see $MANIFEST_DIR"
  [[ "$host" == "$GENESIS_NODE" ]] && genesis_reset=true
done
for host in "${reset_nodes[@]}"; do
  ml_host="$(node_ml_host "$host" || true)"
  [[ -n "$ml_host" ]] || continue
  step "Reset ML host $ml_host for $host"
  if ssh_ready "$ml_host"; then
    preservation_manifest "$ml_host" before
    ssh "$ml_host" "sudo env GDC_RESET_MANAGED_ALIASES=$(printf '%q' "$managed_aliases_serialized") bash -s" \
      <"$ROOT/scripts/reset-remote-host.sh"
    preservation_manifest "$ml_host" after
    cmp -s "$MANIFEST_DIR/$ml_host.before" "$MANIFEST_DIR/$ml_host.after" || die "$ml_host reset changed Docker image IDs or /srv/dai/hf-cache; see $MANIFEST_DIR"
  else
    echo "SKIP  $ml_host is unreachable"
  fi
done
[[ "$genesis_reset" == true ]] || die "$GENESIS_NODE was not reset; preserving local rehearsal state"
# Once the Genesis host has been reset, the previous local ceremony can no
# longer be resumed safely.  Remove it before public-observability work: a
# transient DNS, TLS or browser failure must not leave an obsolete Genesis
# marker that prevents the next clean Genesis from starting.  Keep the
# lifecycle lock until this process exits: deleting its pathname while held
# would let a concurrent reset create a new lock and race this publication.
find "$STATE" -mindepth 1 -maxdepth 1 ! -name .lifecycle.lock -exec rm -rf -- {} +
rm -rf "$GDC_HOME/accounts" "$GDC_HOME/genesis" "$GDC_HOME/mnemonics"
step 'Refresh public site contract for reset state'
# The chain REST process may retain its former participant list until it is
# replaced by Genesis.  Re-render the current site contract before taking the
# reset screenshot; app.js independently filters that stale chain list through
# the participant endpoints, so the map cannot show stopped validators.
# Public Caddy, the static status site, and anonymous Grafana do not require
# an OPS login credential, so refresh them after local Genesis secrets have
# been removed. Do this before the evidence invariant: a failed diagnostic
# check must never strand the public site offline.
GDC_PUBLIC_EDGE_VERIFY=false "$ROOT/scripts/phase-ops.sh" edge
GDC_EXPECT_RESET_STATE=true GDC_SITE_KEEP_CADDY=true CHROME_BIN="$CHROME_BIN" "$ROOT/scripts/phase-ops.sh" site
snapshot_run_evidence "$MANIFEST_DIR/runs.after.sha256"
cmp -s "$MANIFEST_DIR/runs.before.sha256" "$MANIFEST_DIR/runs.after.sha256" \
  || die "reset changed prior lifecycle evidence; public observability was restored; see $MANIFEST_DIR"
step 'Verify public observability remains reachable after chain reset'
observability_deadline=$((SECONDS + ${GDC_RESET_PUBLIC_OBSERVABILITY_WAIT_SECONDS:-120}))
site_ready=false
grafana_ready=false
while (( SECONDS < observability_deadline )); do
  if curl -fsS "https://$SITE_HOST/" | grep -q 'EXTERNAL TEST LAB'; then
    site_ready=true
  fi
  if curl -fsS "https://$GRAFANA_HOST/api/health" | jq -e '.database == "ok"' >/dev/null; then
    grafana_ready=true
  fi
  [[ "$site_ready" == true && "$grafana_ready" == true ]] && break
  sleep 5
done
[[ "$site_ready" == true ]] || die 'public status site is unavailable after reset'
[[ "$grafana_ready" == true ]] || die 'public Grafana is unavailable after reset'
GDC_EXPECT_RESET_STATE=true CHROME_BIN="$CHROME_BIN" node "$ROOT/scripts/capture-homepage-viewport.mjs" \
  "https://$SITE_HOST/" 1440 900 "$MANIFEST_DIR/public-reset-state.png" 0
cat >"$MANIFEST_DIR/verdict.md" <<EOF
# DevNet reset preservation: PASS

- Public site: https://$SITE_HOST/
- Public Grafana: https://$GRAFANA_HOST/
- Browser evidence: public-reset-state.png
- Preservation manifests: exact before/after comparison passed for every contacted host
- Prior run evidence: preserved under $GDC_HOME/runs for cross-reset audit
- Pre-reset chain ID: $pre_reset_chain_id
- Pre-reset Genesis SHA-256: $pre_reset_genesis_sha256
EOF
printf '\nRehearsal state removed. Host packages, Docker, Docker images/cache, drivers, firewall and Fail2ban were preserved.\n'
printf 'PASS preservation manifests: %s\n' "$MANIFEST_DIR"
