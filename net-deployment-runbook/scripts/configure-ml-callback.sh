#!/usr/bin/env bash
# Runs as root on the Network Node. Never prints deployment environment values.
set -Eeuo pipefail
callback_ip="${1:?}"; worker_ip="${2:?}"; firewall="${3:?}"
[[ "$callback_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && "$worker_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || exit 2
mapfile -t ids < <(docker ps --filter label=com.docker.compose.service=api --format '{{.ID}}')
[[ "${#ids[@]}" == 1 ]] || { echo 'Expected one running DAPI; no configuration changed' >&2; exit 1; }
api="${ids[0]}"
deploy="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$api")"
[[ "$deploy" == /srv/dai/deploy || "$deploy" =~ ^/srv/dai/deploy/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || exit 1
[[ -d "$deploy" && ! -L "$deploy" && -f "$deploy/.env" && ! -L "$deploy/.env" ]] || exit 1
files="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$api")"
compose=(docker compose --project-directory "$deploy" --env-file "$deploy/.env")
IFS=, read -ra configs <<<"$files"
for file in "${configs[@]}"; do
  [[ "$file" == "$deploy/"* && "${file#"$deploy/"}" =~ ^[A-Za-z0-9._-]+\.yaml$ && -f "$file" && ! -L "$file" ]] || exit 1
  compose+=(-f "$file")
done
[[ "${#configs[@]}" -gt 0 && -f /etc/gonka/host.env && ! -L /etc/gonka/host.env ]] || exit 1
grep -Fq 'DAPI_API__POC_CALLBACK_URL' "$deploy/compose.yaml"
grep -Fq 'ML_CALLBACK_BIND' "$deploy/compose.yaml"
exec 9>"$deploy/.ml-callback.lock"
flock -n 9 || { echo 'Another callback configuration is running' >&2; exit 1; }
peers=/etc/gonka/ml-callback-peers
[[ ! -L "$peers" && ( ! -e "$peers" || -f "$peers" ) ]] || exit 1
install -d -m 0750 /etc/gonka
touch "$peers"
chmod 0600 "$peers"
grep -Fxq "$worker_ip/32" "$peers" || printf '%s/32\n' "$worker_ip" >>"$peers"
# Install the managed firewall with persistent, additive peer support before
# publishing the listener. Existing JOIN peer and unrelated rules are retained.
install -m 0755 "$firewall" /usr/local/sbin/gonka-firewall
/usr/local/sbin/gonka-firewall
desired="DAPI_API__POC_CALLBACK_URL=http://$callback_ip:9100"
current="$(docker inspect --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "DAPI_API__POC_CALLBACK_URL"}}{{println .}}{{end}}{{end}}' "$api")"
binding="$(docker inspect --format '{{range (index .HostConfig.PortBindings "9100/tcp")}}{{println .HostIp}}{{end}}' "$api")"
if grep -Fxq "$desired" "$deploy/.env" && grep -Fxq 'ML_CALLBACK_BIND=0.0.0.0' "$deploy/.env" && [[ "$current" == "$desired" && "$binding" == 0.0.0.0 ]]; then
  echo 'READY callback configuration already active'
  exit 0
fi
backup="$(mktemp -d "$deploy/.ml-callback-backup.XXXXXXXX")"
cp -p "$deploy/.env" "$backup/env"
rewrite_tmp=''
rollback() {
  rc=$?
  [[ -z "$rewrite_tmp" ]] || rm -f -- "$rewrite_tmp"
  if ((rc != 0)); then
    cp -p "$backup/env" "$deploy/.env"
    "${compose[@]}" up -d --no-deps --pull never api >/dev/null 2>&1 || true
    printf 'Callback apply failed; restored environment; retained backup: %s\n' "$backup" >&2
  fi
  exit "$rc"
}
trap rollback EXIT
rewrite_tmp="$(mktemp "$deploy/.callback-env.XXXXXXXX")"
cp -p "$deploy/.env" "$rewrite_tmp"
awk -v desired="$desired" '
  !/^DAPI_API__POC_CALLBACK_URL=/ && !/^ML_CALLBACK_BIND=/ { print }
  END { print desired; print "ML_CALLBACK_BIND=0.0.0.0" }
' "$deploy/.env" >"$rewrite_tmp"
mv -f -- "$rewrite_tmp" "$deploy/.env"
rewrite_tmp=''
"${compose[@]}" up -d --no-deps --pull never api >/dev/null
for ((attempt=0; attempt<30; attempt++)); do
  if curl -fsS --connect-timeout 2 --max-time 3 http://127.0.0.1:9100/versions >/dev/null; then
    new_api="$("${compose[@]}" ps -q api)"
    [[ -n "$new_api" && "$new_api" != *$'\n'* ]] || exit 1
    actual="$(docker inspect --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "DAPI_API__POC_CALLBACK_URL"}}{{println .}}{{end}}{{end}}' "$new_api")"
    [[ "$actual" == "$desired" ]] || { echo 'DAPI callback readback mismatch' >&2; exit 1; }
    echo 'READY callback listener; only API was recreated'
    exit 0
  fi
  sleep 2
done
echo 'Callback listener did not become ready' >&2
exit 1
