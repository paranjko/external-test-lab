#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
load_env "${GDC_ENV:-$ROOT/.env}"
load_public_observability_hosts
STATE="$ROOT/state"
[[ "${1:-}" == --yes ]] || die 'reset destroys the rehearsal; run ./gdc.sh reset --yes'
CHROME_BIN="${CHROME_BIN:-google-chrome}"
command -v "$CHROME_BIN" >/dev/null || die 'reset requires google-chrome for public reset-state evidence; install it or set CHROME_BIN before destructive work'
MANIFEST_DIR="$ROOT/artifacts/reset-manifests/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$MANIFEST_DIR"

preservation_manifest() {
  local host="$1" phase="$2"
  ssh "$host" 'set -Eeuo pipefail
    docker image ls --no-trunc --format "{{.ID}} {{.Repository}}:{{.Tag}}" | LC_ALL=C sort
    printf "%s\\n" "-- hf-cache --"
    if [[ -d /srv/dai/hf-cache ]]; then
      find /srv/dai/hf-cache -type f -printf "%P %s %T@\n" | LC_ALL=C sort
    fi
    printf "%s\n" "-- preserved-secondary-state --"
    if [[ -d /srv/dai/gmeter ]]; then
      find /srv/dai/gmeter -maxdepth 2 -type f -printf "gmeter/%P %s %m\n" | LC_ALL=C sort
    fi
    if [[ -d /srv/dai/gonka-devnet-bot ]]; then
      find /srv/dai/gonka-devnet-bot -maxdepth 2 -type f \( -name gateway-key-pool.json -o -name "*.db" \) -printf "telegram/%P %s %m\n" | LC_ALL=C sort
      sha256sum /srv/dai/gonka-devnet-bot/gateway-key-pool.json 2>/dev/null || true
    fi' >"$MANIFEST_DIR/$host.$phase"
}

genesis_reset=false
for i in 0 1 2 3 4; do
  host="gdc-node$i"
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
  [[ "$host" == gdc-node0 ]] && genesis_reset=true
done
step 'Reset gdc-node4-ml'
if ssh_ready gdc-node4-ml; then
  preservation_manifest gdc-node4-ml before
  ssh gdc-node4-ml 'sudo bash -s' <"$ROOT/scripts/reset-remote-host.sh"
  preservation_manifest gdc-node4-ml after
  cmp -s "$MANIFEST_DIR/gdc-node4-ml.before" "$MANIFEST_DIR/gdc-node4-ml.after" || die "gdc-node4-ml reset changed Docker image IDs or /srv/dai/hf-cache; see $MANIFEST_DIR"
else
  echo 'SKIP  gdc-node4-ml is unreachable'
fi
[[ "$genesis_reset" == true ]] || die 'gdc-node0 was not reset; preserving local rehearsal state'
rm -rf "$STATE" "$ROOT/artifacts/accounts" "$ROOT/artifacts/genesis" "$ROOT/artifacts/runs"
step 'Verify public observability remains reachable after chain reset'
curl -fsS "https://$SITE_HOST/" | grep -q 'EXTERNAL TEST LAB' \
  || die 'public status site is unavailable after reset'
curl -fsS "https://$GRAFANA_HOST/api/health" | jq -e '.database == "ok"' >/dev/null \
  || die 'public Grafana is unavailable after reset'
GDC_EXPECT_RESET_STATE=true CHROME_BIN="$CHROME_BIN" node "$ROOT/scripts/capture-homepage-viewport.mjs" \
  "https://$SITE_HOST/" 1440 900 "$MANIFEST_DIR/public-reset-state.png" 0
printf '\nRehearsal state removed. Host packages, Docker, Docker images/cache, drivers, firewall and Fail2ban were preserved.\n'
printf 'PASS preservation manifests: %s\n' "$MANIFEST_DIR"
