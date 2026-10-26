#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

command -v stat >/dev/null || { echo 'stat is required' >&2; exit 2; }
command -v chown >/dev/null || { echo 'chown is required' >&2; exit 2; }
[[ "$EUID" -eq 0 ]] || { echo 'this isolated ownership test requires root' >&2; exit 2; }

test_layout() {
local dest=$1
shift
local -a layout_args=("$@")
[[ ! -e "$dest" && ! -L "$dest" ]] || {
  echo 'refusing to test against an existing edge installation; use a disposable runner/container' >&2
  exit 2
}
env_file="$tmp/edge.env"
cat >"$env_file" <<'EOF'
GATEWAY_PUBLIC_HOST=gateway.example
PUBLIC_GRAFANA_PROMETHEUS_URL=http://127.0.0.1:9099
EOF

SUDO_USER=root \
  "$ROOT/04-ops/edge-node/install-edge.sh" "$env_file" "${layout_args[@]}" >/dev/null
[[ ! -e "$dest/site" ]] || { echo 'installer unexpectedly created a site tree' >&2; exit 1; }

site_owner="$(id -u nobody):$(id -g nobody)"
mkdir -p "$dest/site/preview/116"
printf 'published site\n' >"$dest/site/index.html"
printf 'published preview\n' >"$dest/site/preview/116/index.html"
printf 'local marker\n' >"$dest/untouched-by-site-publisher"
chown -R "$site_owner" "$dest/site" "$dest/untouched-by-site-publisher"
mkdir -p "$dest/bootstrap/current"
printf 'published bootstrap\n' >"$dest/bootstrap/current/bootstrap.json"
chown -R "$site_owner" "$dest/bootstrap"
printf 'root-owned legacy artifact\n' >"$dest/bootstrap/current/legacy.json"

check_bootstrap_owners() {
  [[ "$(stat -c '%u:%g' "$dest/bootstrap")" == "$site_owner" ]] || { echo 'bootstrap owner changed' >&2; exit 1; }
  [[ "$(stat -Lc '%u:%g' "$dest/bootstrap/current")" == "$site_owner" ]] || { echo 'current target owner changed' >&2; exit 1; }
  [[ "$(stat -c '%u:%g' "$dest/bootstrap/current/bootstrap.json")" == "$site_owner" ]] || { echo 'bootstrap artifact owner changed' >&2; exit 1; }
  [[ "$(stat -c '%u:%g' "$dest/bootstrap/current/legacy.json")" == 0:0 ]] || { echo 'legacy artifact owner changed' >&2; exit 1; }
  grep -Fxq 'published bootstrap' "$dest/bootstrap/current/bootstrap.json"
  grep -Fxq 'root-owned legacy artifact' "$dest/bootstrap/current/legacy.json"
}

run_install() {
  SUDO_USER=root \
    "$ROOT/04-ops/edge-node/install-edge.sh" "$env_file" "${layout_args[@]}" >/dev/null
}

run_install
check_bootstrap_owners
[[ "$(stat -c '%u:%g' "$dest/site")" == "$site_owner" ]] || { echo 'site owner changed on apply' >&2; exit 1; }
[[ "$(stat -c '%u:%g' "$dest/site/preview/116/index.html")" == "$site_owner" ]] || { echo 'preview owner changed on apply' >&2; exit 1; }
[[ "$(stat -c '%u:%g' "$dest/untouched-by-site-publisher")" == 0:0 ]] || { echo 'non-site owner was not reconciled' >&2; exit 1; }
grep -Fxq 'published preview' "$dest/site/preview/116/index.html"

# A running public Grafana keeps these two directories bind-mounted; a
# repeated apply must refresh their contents without replacing them.
dashboards_inode="$(stat -c '%i' "$dest/public-grafana/dashboards")"
provisioning_inode="$(stat -c '%i' "$dest/public-grafana/provisioning")"
printf '{"uid":"stale"}\n' >"$dest/public-grafana/dashboards/stale.json"
printf 'stale\n' >"$dest/public-grafana/dashboards/gdc-inference.json"

# Exercise a subsequent apply after the publisher has migrated current.
python3 - "$dest/bootstrap" "$site_owner" <<'PY'
import os, pathlib, sys
root = pathlib.Path(sys.argv[1])
uid, gid = map(int, sys.argv[2].split(':'))
(root / 'releases').mkdir()
os.chown(root / 'releases', uid, gid)
(root / 'current').rename(root / 'releases/fixture')
(root / 'current').symlink_to('releases/fixture')
os.chown(root / 'current', uid, gid, follow_symlinks=False)
PY
run_install
check_bootstrap_owners
[[ -L "$dest/bootstrap/current" ]] || { echo 'current symlink was replaced' >&2; exit 1; }
[[ "$(stat -c '%u:%g' "$dest/bootstrap/current")" == "$site_owner" ]] || { echo 'current symlink owner changed' >&2; exit 1; }
[[ "$(stat -c '%u:%g' "$dest/bootstrap/releases")" == "$site_owner" ]] || { echo 'releases owner changed' >&2; exit 1; }
[[ "$(stat -c '%i' "$dest/public-grafana/dashboards")" == "$dashboards_inode" ]] || { echo 'dashboards directory was replaced on repeated apply' >&2; exit 1; }
[[ "$(stat -c '%i' "$dest/public-grafana/provisioning")" == "$provisioning_inode" ]] || { echo 'provisioning directory was replaced on repeated apply' >&2; exit 1; }
[[ ! -e "$dest/public-grafana/dashboards/stale.json" ]] || { echo 'a removed dashboard survived repeated apply' >&2; exit 1; }
cmp -s "$ROOT/04-ops/edge-node/public-grafana/dashboards/gdc-inference.json" "$dest/public-grafana/dashboards/gdc-inference.json" \
  || { echo 'a changed dashboard was not refreshed on repeated apply' >&2; exit 1; }
grep -Fq 'url: http://127.0.0.1:9099' "$dest/public-grafana/provisioning/datasources/prometheus.yml" \
  || { echo 'datasource URL was not rendered on repeated apply' >&2; exit 1; }
[[ "$(stat -c '%u:%g' "$dest/site")" == "$site_owner" ]] || { echo 'site owner changed on repeated apply' >&2; exit 1; }
[[ "$(stat -c '%u:%g' "$dest/site/preview/116/index.html")" == "$site_owner" ]] || { echo 'preview owner changed on repeated apply' >&2; exit 1; }
[[ "$(stat -c '%u:%g' "$dest/untouched-by-site-publisher")" == 0:0 ]] || { echo 'non-site owner regressed on repeated apply' >&2; exit 1; }

printf 'PASS edge install preserves existing site and preview owners across repeated applies\n'
printf 'PASS edge install refreshes public Grafana files inside the bind-mounted directories\n'
printf 'PASS edge install preserves legacy and managed bootstrap ownership layout=%s\n' "$dest"

# Monitoring must not rewrite or re-own independently managed gateway routes.
for file in Caddyfile .env compose.yaml gateway-route.env gateway-admission.env; do
  printf 'retained-%s\n' "$file" >"$dest/$file"
  chown "$site_owner" "$dest/$file"
  chmod 0600 "$dest/$file"
done
before="$(sha256sum "$dest"/{Caddyfile,.env,compose.yaml,gateway-route.env,gateway-admission.env})"
printf 'stale\n' >"$dest/public-grafana/dashboards/gdc-inference.json"
SUDO_USER=root "$ROOT/04-ops/edge-node/install-edge.sh" "$env_file" "${layout_args[@]}" --monitoring-only
[[ "$(sha256sum "$dest"/{Caddyfile,.env,compose.yaml,gateway-route.env,gateway-admission.env})" == "$before" ]]
for file in Caddyfile .env compose.yaml gateway-route.env gateway-admission.env; do
  [[ "$(stat -c '%u:%g' "$dest/$file")" == "$site_owner" ]]
  [[ "$(stat -c '%a' "$dest/$file")" == 600 ]]
done
cmp -s "$ROOT/04-ops/edge-node/public-grafana/dashboards/gdc-inference.json" "$dest/public-grafana/dashboards/gdc-inference.json"
[[ "$(stat -c '%i' "$dest/public-grafana/dashboards")" == "$dashboards_inode" ]]
printf 'PASS monitoring-only preserves edge routes, environment, owners and modes layout=%s\n' "$dest"
}

test_layout /srv/dai/edge
test_layout /srv/dai/deploy/edge --node-name fixture-node

# OPS uses one fixed root across flat and legacy Host layouts. Exercise a
# real fresh install followed by repeated refresh, isolated from host systemd.
[[ ! -e /srv/dai/ops ]] || { echo 'use a disposable OPS fixture' >&2; exit 2; }
mkdir -p "$tmp/bin" "$tmp/render" /etc/systemd/system
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$SYSTEMCTL_LOG"\n' >"$tmp/bin/systemctl"
chmod +x "$tmp/bin/systemctl"
export PATH="$tmp/bin:$PATH" SYSTEMCTL_LOG="$tmp/systemctl.log"
printf 'GRAFANA_ADMIN_PASSWORD=fixture-only\n' >"$tmp/render/.env"
printf 'global: {}\nscrape_configs: []\n' >"$tmp/render/prometheus.yml"
printf 'fixture routes\n' >"$tmp/render/Caddyfile"
mkdir -p "$tmp/render/prometheus/targets/static/host"
printf '[]\n' >"$tmp/render/prometheus/targets/static/host/fixture.json"
mkdir -p "$tmp/render/chain-poller"
printf 'nodes: {}\n' >"$tmp/render/chain-poller/config.yml"
# Operators commonly stage configuration with umask 077. Public discovery
# must become readable to the unprivileged Prometheus process on installation.
chmod 0700 "$tmp/render/prometheus/targets/static" "$tmp/render/prometheus/targets/static/host"
chmod 0600 "$tmp/render/prometheus/targets/static/host/fixture.json"
check_public_discovery() {
  python3 - <<'PY'
import json
import os
# Compose bind-mounts this directory, not its private host-side ancestors.
os.chdir('/srv/dai/ops/prometheus/targets')
os.setgroups([])
os.setgid(65534)
os.setuid(65534)
with open('static/host/fixture.json') as source:
    assert json.load(source) == []
PY
}
for layout in flat legacy; do
  host_root=/srv/dai/deploy
  [[ "$layout" == flat ]] || host_root=/srv/dai/deploy/fixture
  mkdir -p "$host_root"
  printf 'retained host\n' >"$host_root/monitoring-test-marker"
  SUDO_USER=root bash "$ROOT/04-ops/install-ops.sh" --component monitoring --render-dir "$tmp/render"
  check_public_discovery
  for file in .env compose.yaml Caddyfile gateway.env; do
    printf 'custom retained %s\n' "$file" >"/srv/dai/ops/$file"
    chmod 0600 "/srv/dai/ops/$file"
    chown "$site_owner" "/srv/dai/ops/$file"
  done
  printf '[]\n' >/srv/dai/ops/prometheus/targets/join/retained.json
  before="$(sha256sum /srv/dai/ops/{.env,compose.yaml,Caddyfile,gateway.env})"
  calls="$(wc -l <"$SYSTEMCTL_LOG")"
  for repetition in 1 2; do
    printf 'global: {}\nscrape_configs: []\n# revision %s\n' "$repetition" >"$tmp/render/prometheus.yml"
    SUDO_USER=root bash "$ROOT/04-ops/install-ops.sh" --component monitoring --render-dir "$tmp/render"
    check_public_discovery
    [[ "$(sha256sum /srv/dai/ops/{.env,compose.yaml,Caddyfile,gateway.env})" == "$before" ]]
    [[ "$(wc -l <"$SYSTEMCTL_LOG")" == "$calls" ]]
    for file in .env compose.yaml Caddyfile gateway.env; do
      [[ "$(stat -c '%a' "/srv/dai/ops/$file")" == 600 ]]
      [[ "$(stat -c '%u:%g' "/srv/dai/ops/$file")" == "$site_owner" ]]
    done
    cmp "$tmp/render/prometheus.yml" /srv/dai/ops/prometheus/prometheus.yml
    cmp "$tmp/render/chain-poller/config.yml" /srv/dai/ops/chain-poller/config.yml
    test -s /srv/dai/ops/compose.chain-poller.yaml
    test -s /srv/dai/ops/compose.loki.yaml
    cmp "$ROOT/04-ops/loki/config.yaml" /srv/dai/ops/loki/config.yaml
    test -s /srv/dai/ops/prometheus/targets/join/retained.json
    grep -Fxq 'retained host' "$host_root/monitoring-test-marker"
  done
  mv /srv/dai/ops "$tmp/retained-ops-$layout"
  printf 'PASS OPS fresh install and repeated monitoring refresh preserve shared state layout=%s\n' "$layout"
done
