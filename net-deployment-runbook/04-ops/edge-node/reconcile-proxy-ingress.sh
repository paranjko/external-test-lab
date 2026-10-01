#!/usr/bin/env bash
set -Eeuo pipefail

reconcile_proxy_ingress() {
  local alias="$1" bind_address="$2" deploy_root="${GDC_DEPLOY_ROOT:-/srv/dai/deploy}" deploy previous rc healthy
  [[ "$alias" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo 'invalid node alias' >&2; return 2; }
  [[ "$bind_address" == 127.0.0.1 || "$bind_address" == 0.0.0.0 ]] || { echo 'invalid proxy bind address' >&2; return 2; }
  deploy="$deploy_root"
  if [[ ! -f "$deploy/.env" || ! -f "$deploy/compose.yaml" ]]; then
    deploy="$deploy_root/$alias"
  fi
  [[ -f "$deploy/.env" && -f "$deploy/compose.yaml" ]] || { echo 'managed Network Node deployment is absent' >&2; return 1; }
  previous="$(mktemp "$deploy/.env.before-proxy-ingress.XXXXXX")"
  cp -p "$deploy/.env" "$previous"
  rollback() {
    cp -p "$previous" "$deploy/.env" || true
    docker compose --project-directory "$deploy" --env-file "$deploy/.env" -f "$deploy/compose.yaml" up -d --no-deps --force-recreate proxy >/dev/null 2>&1 || true
  }
  if grep -q '^PROXY_BIND_ADDRESS=' "$deploy/.env"; then
    if sed -i -E "s/^PROXY_BIND_ADDRESS=.*/PROXY_BIND_ADDRESS=$bind_address/" "$deploy/.env"; then :; else
      rc=$?
      rollback
      rm -f "$previous"
      return "$rc"
    fi
  else
    if printf 'PROXY_BIND_ADDRESS=%s\n' "$bind_address" >>"$deploy/.env"; then :; else
      rc=$?
      rollback
      rm -f "$previous"
      return "$rc"
    fi
  fi
  if docker compose --project-directory "$deploy" --env-file "$deploy/.env" -f "$deploy/compose.yaml" config --quiet; then :; else
    rc=$?
    rollback
    rm -f "$previous"
    return "$rc"
  fi
  if docker compose --project-directory "$deploy" --env-file "$deploy/.env" -f "$deploy/compose.yaml" up -d --no-deps --force-recreate proxy; then :; else
    rc=$?
    rollback
    rm -f "$previous"
    return "$rc"
  fi
  healthy=false
  for _ in $(seq 1 30); do
    if curl -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:8000/health >/dev/null; then
      healthy=true
      break
    fi
    sleep 1
  done
  if [[ "$healthy" != true ]]; then
    echo 'proxy did not become locally healthy after ingress reconciliation' >&2
    rollback
    rm -f "$previous"
    return 1
  fi
  rm -f "$previous"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ $# -eq 2 ]] || { echo "Usage: $0 SSH_ALIAS PROXY_BIND_ADDRESS" >&2; exit 2; }
  reconcile_proxy_ingress "$@"
fi
