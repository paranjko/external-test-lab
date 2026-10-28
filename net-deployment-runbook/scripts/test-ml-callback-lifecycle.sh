#!/usr/bin/env bash
# Real callback Compose lifecycle in a disposable Docker-in-Docker host.
set -Eeuo pipefail
[[ ${GDC_ML_CALLBACK_DIND:-} == true && $EUID == 0 && ! -e /srv/dai ]] || {
  echo 'Run only through test-ml-callback-lifecycle in a fresh disposable container' >&2
  exit 1
}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
dockerd-entrypoint.sh dockerd >/tmp/ml-callback-dockerd.log 2>&1 &
daemon=$!
project=''
deploy=''
cleanup() {
  if [[ -n "$project" && -n "$deploy" ]]; then
    docker compose --project-directory "$deploy" -f "$deploy/compose.yaml" down --remove-orphans >/dev/null 2>&1 || true
  fi
  kill "$daemon" 2>/dev/null || true
}
trap cleanup EXIT
deadline=$((SECONDS+60))
until docker info >/dev/null 2>&1; do
  ((SECONDS < deadline)) || { cat /tmp/ml-callback-dockerd.log >&2; exit 1; }
  sleep 2
done

image='busybox@sha256:222ad6d973c0d198014546a65cd02c5fdedcc172123c5b4c2bf0af636550bd94'
docker pull "$image"
mkdir -p /etc/gonka /fixture/bin
printf '%s\n' 'ROLE=network-gpu' 'SSH_PORT=22' 'MONITORING_CIDR=192.0.2.9/32' 'ML_CALLBACK_CIDR=192.0.2.8/32' > /etc/gonka/host.env
: > /etc/gonka/ml-callback-peers
cat > /fixture/bin/ip <<'SH'
#!/usr/bin/env bash
printf 'default via 192.0.2.1 dev eth0\n'
SH
for utility in iptables ip6tables; do
  cat > "/fixture/bin/$utility" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> /fixture/firewall-commands
case " $* " in *' -C '*) exit 1;; esac
SH
done
chmod 0755 /fixture/bin/*

check_api_state() {
  local api="$1" callback="$2" host_ip="$3"
  docker inspect "$api" --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "DAPI_API__POC_CALLBACK_URL"}}{{println .}}{{end}}{{end}}' \
    | grep -Fxq "DAPI_API__POC_CALLBACK_URL=$callback"
  docker inspect "$api" --format '{{json .HostConfig.PortBindings}}' | jq -e --arg host "$host_ip" '
    .["9100/tcp"][0].HostIp == $host and
    .["9000/tcp"][0].HostIp == "127.0.0.1" and .["9000/tcp"][0].HostPort == "9000" and
    .["9200/tcp"][0].HostIp == "127.0.0.1" and .["9200/tcp"][0].HostPort == "9200" and
    .["9400/tcp"][0].HostIp == "127.0.0.1" and .["9400/tcp"][0].HostPort == "9400"
  ' >/dev/null
}

container_fingerprint() {
  docker inspect "$1" --format '{{.Id}} {{.State.StartedAt}} {{.State.Pid}}'
}

write_compose() {
  local format="$1" project_name="$2"
  if [[ "$format" == json ]]; then
    jq -n --arg image "$image" --arg name "$project_name" '
      {name:$name,services:{node:{image:$image,command:["sleep","3600"],stop_grace_period:"1s"},
        tmkms:{image:$image,command:["sleep","3600"],stop_grace_period:"1s"},
        api:{image:$image,command:["sh","-c","mkdir -p /www; printf fixture-version\\n > /www/versions; exec httpd -f -p 0.0.0.0:9100 -h /www"],
          environment:{DAPI_API__POC_CALLBACK_URL:"http://api:9100",KEYRING_PASSWORD:"fixture-only"},
          ports:[
            {mode:"ingress",host_ip:"127.0.0.1",target:9000,published:"9000",protocol:"tcp"},
            {mode:"ingress",host_ip:"127.0.0.1",target:9100,published:"9100",protocol:"tcp"},
            {mode:"ingress",host_ip:"127.0.0.1",target:9200,published:"9200",protocol:"tcp"},
            {mode:"ingress",host_ip:"127.0.0.1",target:9400,published:"9400",protocol:"tcp"}],
          stop_grace_period:"1s"}},"x-fixture":{"preserve":"unchanged"}}'
  else
    cat > "$deploy/compose.yaml" <<EOF
name: $project_name
services:
  node:
    image: $image
    command: ["sleep", "3600"]
    stop_grace_period: 1s
  tmkms:
    image: $image
    command: ["sleep", "3600"]
    stop_grace_period: 1s
  api:
    image: $image
    command: ["sh", "-c", "mkdir -p /www; printf fixture-version\\n > /www/versions; exec httpd -f -p 0.0.0.0:9100 -h /www"]
    environment:
      DAPI_API__POC_CALLBACK_URL: "\${DAPI_API__POC_CALLBACK_URL:-http://api:9100}"
      KEYRING_PASSWORD: fixture-only
    ports:
      - "127.0.0.1:9000:9000/tcp"
      - "\${ML_CALLBACK_BIND:-127.0.0.1}:9100:9100/tcp"
      - "127.0.0.1:9200:9200/tcp"
      - "127.0.0.1:9400:9400/tcp"
    stop_grace_period: 1s
EOF
  fi
}

run_case() {
  local layout="$1" format="$2" mode="$3" api_before node_before signer_before api_after node_after signer_after node_fingerprint_before signer_fingerprint_before
  project="gdc-callback-${layout}-${mode}"
  deploy=/srv/dai/deploy
  [[ "$layout" != legacy ]] || deploy="$deploy/old-project"
  rm -rf -- "$deploy"
  mkdir -p "$deploy"
  printf '%s\n' 'KEYRING_PASSWORD=fixture-only' 'DAPI_API__POC_CALLBACK_URL=http://api:9100' 'ML_CALLBACK_BIND=127.0.0.1' > "$deploy/.env"
  if [[ "$format" == json ]]; then
    write_compose json "$project" > "$deploy/compose.yaml"
  else
    write_compose yaml "$project"
  fi
  local -a dc=(docker compose --project-directory "$deploy" --env-file "$deploy/.env" -f "$deploy/compose.yaml")
  "${dc[@]}" up -d
  api_before="$("${dc[@]}" ps -q api)"
  node_before="$("${dc[@]}" ps -q node)"
  signer_before="$("${dc[@]}" ps -q tmkms)"
  node_fingerprint_before="$(container_fingerprint "$node_before")"
  signer_fingerprint_before="$(container_fingerprint "$signer_before")"
  [[ -n "$api_before" && -n "$node_before" && -n "$signer_before" ]]
  curl -fsS --retry 20 --retry-connrefused --retry-delay 1 http://127.0.0.1:9100/versions >/dev/null
  check_api_state "$api_before" http://api:9100 127.0.0.1
  cp -p "$deploy/.env" /fixture/original.env
  cp -p "$deploy/compose.yaml" /fixture/original-compose.yaml

  if [[ "$mode" == success ]]; then
    PATH="/fixture/bin:$PATH" bash "$ROOT/scripts/configure-ml-callback.sh" 192.0.2.1 192.0.2.2 "$ROOT/00-host-prep/gonka-firewall.sh"
    api_after="$("${dc[@]}" ps -q api)"
    node_after="$("${dc[@]}" ps -q node)"
    signer_after="$("${dc[@]}" ps -q tmkms)"
    [[ "$api_after" != "$api_before" ]] || { echo 'API did not recreate after callback change' >&2; exit 1; }
    [[ "$node_after" == "$node_before" && "$signer_after" == "$signer_before" ]] || { echo 'Core or signer identity changed' >&2; exit 1; }
    [[ "$(container_fingerprint "$node_after")" == "$node_fingerprint_before" &&
       "$(container_fingerprint "$signer_after")" == "$signer_fingerprint_before" ]] || { echo 'Core or signer process restarted' >&2; exit 1; }
    check_api_state "$api_after" http://192.0.2.1:9100 0.0.0.0
    curl -fsS http://127.0.0.1:9100/versions >/dev/null
    cp -p "$deploy/compose.yaml" /fixture/applied-compose.yaml
    PATH="/fixture/bin:$PATH" bash "$ROOT/scripts/configure-ml-callback.sh" 192.0.2.1 192.0.2.2 "$ROOT/00-host-prep/gonka-firewall.sh"
    [[ $("${dc[@]}" ps -q api) == "$api_after" ]] || { echo 'idempotent callback apply recreated API' >&2; exit 1; }
    cmp -s "$deploy/compose.yaml" /fixture/applied-compose.yaml || { echo 'idempotent callback apply rewrote Compose file' >&2; exit 1; }
    if [[ "$format" == json ]]; then
      jq -e '
        .services.api.environment.DAPI_API__POC_CALLBACK_URL == "http://192.0.2.1:9100" and
        .services.api.environment.KEYRING_PASSWORD == "fixture-only" and
        ([.services.api.ports[] | select(.target == 9000 or .target == 9200 or .target == 9400) | .host_ip == "127.0.0.1"] | all) and
        .["x-fixture"].preserve == "unchanged"
      ' "$deploy/compose.yaml" >/dev/null
    fi
  else
    local apply_fail=/fixture/configure-fail.sh
    cp "$ROOT/scripts/configure-ml-callback.sh" "$apply_fail"
    sed -i 's/attempt<30/attempt<1/; s/sleep 2/sleep 0/' "$apply_fail"
    cat > /fixture/bin/curl <<'SH'
#!/usr/bin/env bash
exit 22
SH
    chmod 0755 /fixture/bin/curl
    set +e
    PATH="/fixture/bin:$PATH" bash "$apply_fail" 192.0.2.1 192.0.2.2 "$ROOT/00-host-prep/gonka-firewall.sh" >/fixture/rollback.out 2>/fixture/rollback.err
    local rc=$?
    set -e
    ((rc != 0)) || { echo 'readiness failure unexpectedly succeeded' >&2; exit 1; }
    cmp -s "$deploy/.env" /fixture/original.env || { echo 'rollback did not restore .env' >&2; exit 1; }
    cmp -s "$deploy/compose.yaml" /fixture/original-compose.yaml || { echo 'rollback did not restore Compose file' >&2; exit 1; }
    grep -Fq 'restored environment and Compose file' /fixture/rollback.err
    api_after="$("${dc[@]}" ps -q api)"
    node_after="$("${dc[@]}" ps -q node)"
    signer_after="$("${dc[@]}" ps -q tmkms)"
    [[ "$node_after" == "$node_before" && "$signer_after" == "$signer_before" ]] || { echo 'Core or signer identity changed during rollback' >&2; exit 1; }
    [[ "$(container_fingerprint "$node_after")" == "$node_fingerprint_before" &&
       "$(container_fingerprint "$signer_after")" == "$signer_fingerprint_before" ]] || { echo 'Core or signer process restarted during rollback' >&2; exit 1; }
    check_api_state "$api_after" http://api:9100 127.0.0.1
    curl -fsS http://127.0.0.1:9100/versions >/dev/null
  fi
  "${dc[@]}" down >/dev/null
  project=''
  deploy=''
  printf 'PASS real Compose callback lifecycle layout=%s format=%s mode=%s; Core, signer and non-callback ports preserved\n' "$layout" "$format" "$mode"
}

run_case flat yaml success
run_case flat json success
run_case legacy json success
run_case flat yaml rollback
run_case flat json rollback
run_case legacy json rollback
