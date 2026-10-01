#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${DOCKER_LOG:?}"
exit 0
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit "${CURL_EXIT:-0}"
EOF
cat >"$tmp/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$tmp/bin/docker" "$tmp/bin/curl" "$tmp/bin/sleep"
source "$ROOT/04-ops/edge-node/reconcile-proxy-ingress.sh"
for layout in flat legacy; do
  root="$tmp/$layout/deploy"
  deploy="$root"
  [[ "$layout" == flat ]] || deploy="$root/gdc-node0"
  mkdir -p "$deploy"
  printf 'PROXY_BIND_ADDRESS=127.0.0.1\n' >"$deploy/.env"
  : >"$deploy/compose.yaml"
  PATH="$tmp/bin:$PATH" DOCKER_LOG="$tmp/$layout/docker.log" GDC_DEPLOY_ROOT="$root" reconcile_proxy_ingress gdc-node0 0.0.0.0
done
root="$tmp/unhealthy/deploy"
mkdir -p "$root"
printf 'PROXY_BIND_ADDRESS=127.0.0.1\n' >"$root/.env"
: >"$root/compose.yaml"
if PATH="$tmp/bin:$PATH" DOCKER_LOG="$tmp/unhealthy/docker.log" CURL_EXIT=1 GDC_DEPLOY_ROOT="$root" reconcile_proxy_ingress gdc-node0 0.0.0.0; then
  echo 'expected unhealthy proxy ingress reconciliation to fail' >&2
  exit 1
fi
[[ "$(wc -l <"$tmp/unhealthy/docker.log")" == 3 ]]
[[ -z "$(find "$root" -maxdepth 1 -name '.env.before-proxy-ingress.*' -print -quit)" ]]
printf 'PASS proxy ingress reconciles supported layouts and restores an unhealthy update\n'
