#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
containers=()
cleanup() {
  for container in "${containers[@]}"; do docker rm -f "$container" >/dev/null 2>&1 || true; done
  rm -rf -- "$tmp"
}
trap cleanup EXIT
image="${CADDY_TEST_IMAGE:-caddy:2.10.2-alpine@sha256:4c6e91c6ed0e2fa03efd5b44747b625fec79bc9cd06ac5235a779726618e530d}"
python_image="${PYTHON_TEST_IMAGE:-python:3.13-alpine}"
mkdir -p "$tmp/config" "$tmp/store"
cat >"$tmp/config/Caddyfile" <<'CADDY'
{
  admin 127.0.0.1:2019
  auto_https off
}
http://{$PUBLIC_HOST} {
  route {
    handle /serving {
      respond "retained" 200
    }
    handle {
      respond 404
    }
  }
}
CADDY
# The stand-in log store records the path it was asked for and answers like Loki.
cat >"$tmp/store/store.py" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
class Store(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        open("/store/requests", "a").write(self.path + "\n")
        self.send_response(204)
        self.end_headers()
    def log_message(self, *args):
        pass
HTTPServer(("127.0.0.1", 3100), Store).serve_forever()
PY
chmod 0777 "$tmp/store"
host=fixture-ops
name="gdc-log-intake-$$"
containers+=("$name" "$name-store")
docker run -d --name "$name" --label com.docker.compose.service=caddy \
  -e "PUBLIC_HOST=$host" -v "$tmp/config:/config:ro" "$image" \
  caddy run --config /config/Caddyfile --adapter caddyfile >/dev/null
docker run -d --name "$name-store" --network "container:$name" -v "$tmp/store:/store" "$python_image" \
  python3 /store/store.py >/dev/null
url="http://$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name"):80"
for _ in {1..30}; do
  if curl -fsS -H "Host: $host" "$url/serving" >/dev/null 2>&1; then break; fi
  sleep 1
done
curl -fsS -H "Host: $host" "$url/serving" >/dev/null
code() { curl -s -o /dev/null -w '%{http_code}' -H "Host: $host" "$@"; }
wait_code() {
  local want="$1" got=''
  shift
  for _ in {1..10}; do
    got="$(code "$@")"
    [[ "$got" != "$want" ]] || return 0
    sleep 1
  done
  echo "expected HTTP $want, got $got" >&2
  return 1
}

token_file="$tmp/token"
printf 'FixtureToken0123456789abcdefABCDEF\n' >"$token_file"
auth=(-H 'Authorization: Bearer FixtureToken0123456789abcdefABCDEF')
push=(-X POST -H 'Content-Type: application/json' --data '{"streams":[]}')

# A source outside the inventory is refused even with the token.
bash "$ROOT/04-ops/render-log-intake.sh" "$token_file" 192.0.2.4/32 >"$tmp/intake.caddy"
bash "$ROOT/04-ops/install-gateway-observation.sh" "$host" "$tmp/intake.caddy" 'log intake'
wait_code 403 "${push[@]}" "${auth[@]}" "$url/ops-logs/push"
[[ "$(curl -fsS -H "Host: $host" "$url/serving")" == retained ]]

# An allowed source needs the token, and reaches the store at the Loki push path.
bash "$ROOT/04-ops/render-log-intake.sh" "$token_file" 0.0.0.0/0 >"$tmp/intake.caddy"
bash "$ROOT/04-ops/install-gateway-observation.sh" "$host" "$tmp/intake.caddy" 'log intake'
wait_code 403 "${push[@]}" -H 'Authorization: Bearer wrong' "$url/ops-logs/push"
wait_code 403 "${push[@]}" "$url/ops-logs/push"
wait_code 204 "${push[@]}" "${auth[@]}" "$url/ops-logs/push"
[[ "$(tail -1 "$tmp/store/requests")" == /loki/api/v1/push ]]
[[ "$(code "${auth[@]}" "$url/ops-logs/push")" == 403 ]]
printf 'PASS intake refuses foreign sources and missing tokens and forwards to the Loki push path\n'

# The gateway observation block and the intake block live side by side.
bash "$ROOT/04-ops/render-gateway-observation.sh" '[{"id":"A_V6","node":"a","port":18146}]' a 192.0.2.4/32 >"$tmp/observation.caddy"
bash "$ROOT/04-ops/install-gateway-observation.sh" "$host" "$tmp/observation.caddy"
grep -Fxq '  # BEGIN GDC log intake' "$tmp/config/Caddyfile"
grep -Fxq '  # BEGIN GDC gateway observation' "$tmp/config/Caddyfile"
[[ "$(grep -c '# BEGIN GDC' "$tmp/config/Caddyfile")" == 2 ]]
sha="$(sha256sum "$tmp/config/Caddyfile")"
bash "$ROOT/04-ops/install-gateway-observation.sh" "$host" "$tmp/intake.caddy" 'log intake'
[[ "$sha" == "$(sha256sum "$tmp/config/Caddyfile")" ]]
wait_code 204 "${push[@]}" "${auth[@]}" "$url/ops-logs/push"
wait_code 403 "$url/ops-gateways/A_V6/metrics"
if bash "$ROOT/04-ops/install-gateway-observation.sh" "$host" "$tmp/intake.caddy" 'Log; intake' >/dev/null 2>&1; then
  echo 'an unsafe block name was accepted' >&2
  exit 1
fi
printf 'PASS named blocks coexist, reinstall is idempotent and unsafe block names are refused\n'
