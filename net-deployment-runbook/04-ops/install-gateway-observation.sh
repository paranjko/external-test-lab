#!/usr/bin/env bash
set -Eeuo pipefail
# Patch only the observation block in the currently running participant edge.
# Both a single-file bind mount and a directory bind mount are supported.
host="${1:?public host required}"
fragment="${2:?rendered observation fragment required}"
[[ "$host" =~ ^[A-Za-z0-9.-]+$ && -s "$fragment" && ! -L "$fragment" ]] || exit 2
matches=()
while IFS= read -r id; do
  if docker inspect "$id" | jq -e --arg host "PUBLIC_HOST=$host" '.[0].Config.Env | index($host) != null' >/dev/null; then
    matches+=("$id")
  fi
done < <(docker ps -q --filter label=com.docker.compose.service=caddy)
[[ ${#matches[@]} == 1 ]] || { echo 'expected one running participant Caddy for public host' >&2; exit 2; }
container="${matches[0]}"
metadata="$(docker inspect "$container")"
config="$(jq -er '.[0].Config.Cmd as $cmd | ($cmd | index("--config")) as $i | if $i == null then error("missing config argument") else $cmd[$i+1] end' <<<"$metadata")"
source_path="$(jq -er --arg config "$config" '
  [.[0].Mounts[] | select(.Type == "bind")
    | . as $mount | select($config == .Destination or ($config | startswith($mount.Destination + "/")))
    | {length:(.Destination|length), path:(.Source + ($config | ltrimstr($mount.Destination)))}]
  | sort_by(.length) | last | .path // error("config has no bind mount")
' <<<"$metadata")"
[[ "$source_path" == /* && -f "$source_path" && ! -L "$source_path" ]] || exit 2
[[ "$(readlink -f "$source_path")" == "$source_path" ]] || { echo 'refusing symlinked configuration path' >&2; exit 2; }
exec 9>"${source_path}.monitoring.lock"
flock -n 9 || { echo 'another monitoring route update is active' >&2; exit 1; }
backup="$(mktemp -d "${source_path%/*}/.gdc-monitoring.XXXXXX")"
chmod 700 "$backup"
cp -p "$source_path" "$backup/Caddyfile.before"
awk -v fragment="$fragment" '
  $0 == "  # BEGIN GDC gateway observation" { skip=1; next }
  $0 == "  # END GDC gateway observation" { skip=0; next }
  skip { next }
  { print }
  $0 == "  route {" {
    count++
    print "  # BEGIN GDC gateway observation"
    while ((getline line < fragment) > 0) print line
    close(fragment)
    print "  # END GDC gateway observation"
  }
  END { if (count != 1 || skip) exit 2 }
' "$source_path" >"$backup/Caddyfile.after"
if cmp -s "$source_path" "$backup/Caddyfile.after"; then
  printf 'PASS observation routes unchanged host=%s receipt=%s\n' "$host" "$backup"
  exit 0
fi
# Do not print Caddy diagnostics: existing routes may contain credentials.
docker exec -i "$container" caddy validate --adapter caddyfile --config /dev/stdin <"$backup/Caddyfile.after" >"$backup/validate.log" 2>&1 \
  || { echo "Caddy validation failed; private receipt=$backup" >&2; exit 1; }
cmp -s "$source_path" "$backup/Caddyfile.before" || { echo 'Caddy configuration changed concurrently' >&2; exit 1; }
# Preserve the inode: a single-file bind mount would otherwise retain old bytes.
cat "$backup/Caddyfile.after" >"$source_path"
if ! docker exec -i "$container" caddy reload --adapter caddyfile --config /dev/stdin <"$source_path" >"$backup/reload.log" 2>&1; then
  cat "$backup/Caddyfile.before" >"$source_path"
  docker exec -i "$container" caddy reload --adapter caddyfile --config /dev/stdin <"$source_path" >>"$backup/reload.log" 2>&1 || true
  echo "Caddy reload failed; original configuration restored; receipt=$backup" >&2
  exit 1
fi
printf 'PASS observation routes reloaded host=%s container=%s receipt=%s\n' "$host" "$container" "$backup"
