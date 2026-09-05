#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

command -v stat >/dev/null || { echo 'stat is required' >&2; exit 2; }
command -v chown >/dev/null || { echo 'chown is required' >&2; exit 2; }
[[ "$EUID" -eq 0 ]] || { echo 'this isolated ownership test requires root' >&2; exit 2; }

dest=/srv/dai/edge
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
  "$ROOT/04-ops/edge-node/install-edge.sh" "$env_file" >/dev/null
[[ ! -e "$dest/site" ]] || { echo 'installer unexpectedly created a site tree' >&2; exit 1; }

site_owner="$(id -u nobody):$(id -g nobody)"
mkdir -p "$dest/site/preview/116"
printf 'published site\n' >"$dest/site/index.html"
printf 'published preview\n' >"$dest/site/preview/116/index.html"
printf 'local marker\n' >"$dest/untouched-by-site-publisher"
chown -R "$site_owner" "$dest/site" "$dest/untouched-by-site-publisher"

run_install() {
  SUDO_USER=root \
    "$ROOT/04-ops/edge-node/install-edge.sh" "$env_file" >/dev/null
}

run_install
[[ "$(stat -c '%u:%g' "$dest/site")" == "$site_owner" ]] || { echo 'site owner changed on apply' >&2; exit 1; }
[[ "$(stat -c '%u:%g' "$dest/site/preview/116/index.html")" == "$site_owner" ]] || { echo 'preview owner changed on apply' >&2; exit 1; }
[[ "$(stat -c '%u:%g' "$dest/untouched-by-site-publisher")" == 0:0 ]] || { echo 'non-site owner was not reconciled' >&2; exit 1; }
grep -Fxq 'published preview' "$dest/site/preview/116/index.html"

run_install
[[ "$(stat -c '%u:%g' "$dest/site")" == "$site_owner" ]] || { echo 'site owner changed on repeated apply' >&2; exit 1; }
[[ "$(stat -c '%u:%g' "$dest/site/preview/116/index.html")" == "$site_owner" ]] || { echo 'preview owner changed on repeated apply' >&2; exit 1; }
[[ "$(stat -c '%u:%g' "$dest/untouched-by-site-publisher")" == 0:0 ]] || { echo 'non-site owner regressed on repeated apply' >&2; exit 1; }

printf 'PASS edge install preserves existing site and preview owners across repeated applies\n'
