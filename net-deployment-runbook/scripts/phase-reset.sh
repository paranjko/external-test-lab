#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
# Reset needs both public-observability hosts and the deployment inventory for
# the pre-reset chain snapshot.  Loading only .env leaves NODE0_PUBLIC_HOST
# unset under `set -u` before any host has been touched.
load_project
load_public_observability_hosts
STATE="$ROOT/state"
[[ "${1:-}" == --yes ]] || die 'reset destroys the rehearsal; run ./gdc.sh reset --yes'
CHROME_BIN="${CHROME_BIN:-google-chrome}"
command -v "$CHROME_BIN" >/dev/null || die 'reset requires google-chrome for public reset-state evidence; install it or set CHROME_BIN before destructive work'
MANIFEST_DIR="$ROOT/artifacts/reset-manifests/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$MANIFEST_DIR"

snapshot_run_evidence() {
  local output="$1"
  local -a find_args=(artifacts/runs -type f)
  if [[ -n "${GDC_RUN_ID:-}" ]]; then
    find_args+=( ! -path "artifacts/runs/$GDC_RUN_ID/*" )
  fi
  (
    cd "$ROOT"
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
snapshot_run_evidence "$MANIFEST_DIR/artifacts-runs.before.sha256"

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
      find /srv/dai/gonka-devnet-bot -maxdepth 2 -type f \( -name gateway-key-pool.json -o -name "*.db" \) -printf "telegram/%P %s %m\n" | LC_ALL=C sort
      sha256sum /srv/dai/gonka-devnet-bot/gateway-key-pool.json 2>/dev/null || true
    fi' >"$MANIFEST_DIR/$host.$phase"
}

genesis_reset=false
for host in "${GDC_NODES[@]}"; do
  if host_is_skipped "$host"; then
    echo "SKIP  $host is excluded by GDC_SKIP_HOSTS"
    continue
  fi
  step "Reset $host"
  if ! ssh_ready "$host"; then
    echo "SKIP  $host is unreachable"
    continue
  fi
  preservation_manifest "$host" before
  ssh "$host" 'sudo bash -s' <"$ROOT/scripts/reset-remote-host.sh"
  preservation_manifest "$host" after
  cmp -s "$MANIFEST_DIR/$host.before" "$MANIFEST_DIR/$host.after" || die "$host reset changed Docker image IDs or /srv/dai/hf-cache; see $MANIFEST_DIR"
  [[ "$host" == "$GENESIS_NODE" ]] && genesis_reset=true
done
for host in "${GDC_NODES[@]}"; do
  ml_host="$(node_ml_host "$host" || true)"
  [[ -n "$ml_host" ]] || continue
  step "Reset ML host $ml_host for $host"
  if ssh_ready "$ml_host"; then
    preservation_manifest "$ml_host" before
    ssh "$ml_host" 'sudo bash -s' <"$ROOT/scripts/reset-remote-host.sh"
    preservation_manifest "$ml_host" after
    cmp -s "$MANIFEST_DIR/$ml_host.before" "$MANIFEST_DIR/$ml_host.after" || die "$ml_host reset changed Docker image IDs or /srv/dai/hf-cache; see $MANIFEST_DIR"
  else
    echo "SKIP  $ml_host is unreachable"
  fi
done
[[ "$genesis_reset" == true ]] || die "$GENESIS_NODE was not reset; preserving local rehearsal state"
rm -rf "$STATE" "$ROOT/artifacts/accounts" "$ROOT/artifacts/genesis"
snapshot_run_evidence "$MANIFEST_DIR/artifacts-runs.after.sha256"
cmp -s "$MANIFEST_DIR/artifacts-runs.before.sha256" "$MANIFEST_DIR/artifacts-runs.after.sha256" \
  || die "reset changed prior lifecycle evidence; see $MANIFEST_DIR"
step 'Verify public observability remains reachable after chain reset'
curl -fsS "https://$SITE_HOST/" | grep -q 'EXTERNAL TEST LAB' \
  || die 'public status site is unavailable after reset'
curl -fsS "https://$GRAFANA_HOST/api/health" | jq -e '.database == "ok"' >/dev/null \
  || die 'public Grafana is unavailable after reset'
GDC_EXPECT_RESET_STATE=true CHROME_BIN="$CHROME_BIN" node "$ROOT/scripts/capture-homepage-viewport.mjs" \
  "https://$SITE_HOST/" 1440 900 "$MANIFEST_DIR/public-reset-state.png" 0
cat >"$MANIFEST_DIR/verdict.md" <<EOF
# DevNet reset preservation: PASS

- Public site: https://$SITE_HOST/
- Public Grafana: https://$GRAFANA_HOST/
- Browser evidence: public-reset-state.png
- Preservation manifests: exact before/after comparison passed for every contacted host
- Prior run evidence: preserved under artifacts/runs for cross-reset audit
- Pre-reset chain ID: $pre_reset_chain_id
- Pre-reset Genesis SHA-256: $pre_reset_genesis_sha256
EOF
printf '\nRehearsal state removed. Host packages, Docker, Docker images/cache, drivers, firewall and Fail2ban were preserved.\n'
printf 'PASS preservation manifests: %s\n' "$MANIFEST_DIR"
