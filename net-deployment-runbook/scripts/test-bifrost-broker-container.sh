#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; tmp="$(mktemp -d)"; volume="gdc-bifrost-broker-test-$$"; image="gdc-bifrost-broker-test:local"
cid=''; management_pid=''
project="gdc-bifrost-broker-test-$$"
cleanup() { [[ -z "$cid" ]] || docker rm -f "$cid" >/dev/null 2>&1 || true; docker compose -p "$project" -f "$tmp/compose.yaml" down -v --remove-orphans >/dev/null 2>&1 || true; [[ -z "$management_pid" ]] || kill "$management_pid" >/dev/null 2>&1 || true; docker volume rm -f "$volume" >/dev/null 2>&1 || true; rm -rf "$tmp"; }; trap cleanup EXIT
printf 'BIFROST_GONKA_PROVIDER=gonka-s\nBIFROST_GONKA_MODEL=test\nBIFROST_GONKA_KEY_ID=id\n' >"$tmp/broker-binding.env"; chmod 0444 "$tmp/broker-binding.env"
docker build -q -t "$image" -f "$ROOT/04-ops/Dockerfile.bifrost-broker" "$ROOT/04-ops" >/dev/null
docker volume create "$volume" >/dev/null
docker run --rm --user 0:0 -v "$volume:/var/lib/bifrost-broker" --entrypoint sh "$image" -c 'install -d -o 65532 -g 65532 -m 0700 /var/lib/bifrost-broker'
docker run --rm --user 65532:65532 -v "$volume:/var/lib/bifrost-broker" -v "$tmp/broker-binding.env:/run/bifrost/broker-binding.env:ro" --entrypoint sh "$image" -c 'test -r /run/bifrost/broker-binding.env && touch /var/lib/bifrost-broker/keys.sqlite3'
docker run --rm --user 65532:65532 -v "$volume:/var/lib/bifrost-broker" --entrypoint sh "$image" -c 'test -f /var/lib/bifrost-broker/keys.sqlite3 && test -w /var/lib/bifrost-broker/keys.sqlite3'

# The running entrypoint must also own the SQLite write, not merely be able to
# touch its directory. A loopback fake keeps the management credential private.
printf '0' >"$tmp/upstream-count"
read -r management_port broker_port < <(python3 -c 'import socket; sockets=[socket.socket(),socket.socket()]; [s.bind(("127.0.0.1",0)) for s in sockets]; print(*[s.getsockname()[1] for s in sockets])')
python3 "$ROOT/scripts/bifrost-fake-management.py" "$tmp/upstream-count" "$management_port" >/dev/null 2>&1 & management_pid=$!
env_file="$tmp/broker.env"
printf 'BIFROST_MANAGEMENT_URL=http://127.0.0.1:%s\nBIFROST_ADMIN_USERNAME=admin\nBIFROST_ADMIN_PASSWORD=Valid!Password1\nBIFROST_BROKER_TOKEN=xxxxxxxxxxxxxxxxxxxxxxxx\nBIFROST_EDGE_TOKEN=eeeeeeeeeeeeeeeeeeeeeeee\nBIFROST_BROKER_ENCRYPTION_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\nBIFROST_BROKER_BINDING_FILE=/run/bifrost/broker-binding.env\nBIFROST_BROKER_DB=/var/lib/bifrost-broker/keys.sqlite3\nBIFROST_BROKER_HOST=127.0.0.1\nBIFROST_BROKER_PORT=%s\n' "$management_port" "$broker_port" >"$env_file"
cid="$(docker run -d --network host --env-file "$env_file" -v "$volume:/var/lib/bifrost-broker" -v "$tmp/broker-binding.env:/run/bifrost/broker-binding.env:ro" "$image")"
ready=false
for _ in $(seq 1 20); do
  if docker inspect -f '{{.State.Running}}' "$cid" | grep -Fxq true \
    && curl -sS --connect-timeout 1 "http://127.0.0.1:$broker_port/nope" >/dev/null 2>&1; then ready=true; break; fi
  sleep 1
done
[[ "$ready" == true ]] || { docker logs "$cid" >&2; exit 1; }
key_one="$(curl -fsS -X POST "http://127.0.0.1:$broker_port/v1/keys" -H 'Authorization: Bearer xxxxxxxxxxxxxxxxxxxxxxxx' -H 'Content-Type: application/json' -d '{"telegram_id":7,"update_id":1}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])')"
docker rm -f "$cid" >/dev/null
cid="$(docker run -d --network host --env-file "$env_file" -v "$volume:/var/lib/bifrost-broker" -v "$tmp/broker-binding.env:/run/bifrost/broker-binding.env:ro" "$image")"
sleep 1
key_two="$(curl -fsS -X POST "http://127.0.0.1:$broker_port/v1/keys" -H 'Authorization: Bearer xxxxxxxxxxxxxxxxxxxxxxxx' -H 'Content-Type: application/json' -d '{"telegram_id":7,"update_id":1}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])')"
[[ "$key_one" == "$key_two" && "$key_one" == sk-gdc-* && "$(<"$tmp/upstream-count")" == 1 ]]
docker rm -f "$cid" >/dev/null
printf 'PASS broker entrypoint issues and persists SQLite state across recreate\n'

# This second lifecycle uses Compose, mirroring the production broker/init
# relationship and project-scoped volume rather than a parallel docker-run
# contract. The fake management API remains an owned loopback fixture.
cat >"$tmp/compose.yaml" <<EOF
services:
  init:
    image: $image
    user: "0:0"
    entrypoint: ["sh", "-c", "install -d -o 65532 -g 65532 -m 0700 /var/lib/bifrost-broker"]
    volumes: ["broker-data:/var/lib/bifrost-broker"]
  broker:
    image: $image
    network_mode: host
    env_file: [$env_file]
    volumes:
      - broker-data:/var/lib/bifrost-broker
      - $tmp/broker-binding.env:/run/bifrost/broker-binding.env:ro
    depends_on:
      init: {condition: service_completed_successfully}
volumes: {broker-data: {}}
EOF
docker compose -p "$project" -f "$tmp/compose.yaml" up -d --wait
compose_key_one="$(curl -fsS -X POST "http://127.0.0.1:$broker_port/v1/keys" -H 'Authorization: Bearer xxxxxxxxxxxxxxxxxxxxxxxx' -H 'Content-Type: application/json' -d '{"telegram_id":8,"update_id":2}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])')"
docker compose -p "$project" -f "$tmp/compose.yaml" up -d --force-recreate broker
compose_ready=false
for _ in $(seq 1 20); do
  if docker compose -p "$project" -f "$tmp/compose.yaml" ps --status running -q broker | grep -Eq '.' \
    && curl -sS --connect-timeout 1 "http://127.0.0.1:$broker_port/nope" >/dev/null 2>&1; then compose_ready=true; break; fi
  sleep 1
done
[[ "$compose_ready" == true ]] || { docker compose -p "$project" -f "$tmp/compose.yaml" logs broker >&2; exit 1; }
compose_key_two="$(curl -fsS -X POST "http://127.0.0.1:$broker_port/v1/keys" -H 'Authorization: Bearer xxxxxxxxxxxxxxxxxxxxxxxx' -H 'Content-Type: application/json' -d '{"telegram_id":8,"update_id":2}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])')"
[[ "$compose_key_one" == "$compose_key_two" && "$(<"$tmp/upstream-count")" == 2 ]]
printf 'PASS Compose broker/init lifecycle preserves idempotent SQLite state\n'
