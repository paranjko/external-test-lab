#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
image="$(sed -n 's/^ *image: \${LOKI_IMAGE:-\(.*\)}$/\1/p' "$ROOT/04-ops/compose.loki.yaml")"
[[ "$image" =~ ^grafana/loki:[0-9.]+@sha256:[0-9a-f]{64}$ ]] || { echo 'the log store image is not pinned by digest' >&2; exit 1; }
config="$ROOT/04-ops/loki/config.yaml"
grep -Fq 'retention_period: 336h' "$config"
grep -Fq 'retention_enabled: true' "$config"
grep -Fq 'reporting_enabled: false' "$config"
docker run --rm -v "$config:/etc/loki/config.yaml:ro" "$image" -config.file=/etc/loki/config.yaml -verify-config >/dev/null
name="gdc-log-store-$$"
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$name" -v "$config:/etc/loki/config.yaml:ro" "$image" -config.file=/etc/loki/config.yaml >/dev/null
url="http://$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name"):3100"
for _ in {1..60}; do
  if [[ "$(curl -s -m 2 "$url/ready" || true)" == ready ]]; then break; fi
  sleep 2
done
[[ "$(curl -s -m 2 "$url/ready")" == ready ]]
marker="store-check-$$"
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' "$url/loki/api/v1/push" \
  --data "{\"streams\":[{\"stream\":{\"host\":\"fixture\",\"component\":\"store-check\"},\"values\":[[\"$(date +%s)000000000\",\"$marker\"]]}]}")"
[[ "$code" == 204 ]]
for _ in {1..15}; do
  if curl -fsSG "$url/loki/api/v1/query_range" --data-urlencode 'query={component="store-check"}' | grep -Fq "$marker"; then
    printf 'PASS the pinned log store accepts the configuration, a push and a query\n'
    exit 0
  fi
  sleep 1
done
echo 'pushed line was not returned by the log store' >&2
exit 1
