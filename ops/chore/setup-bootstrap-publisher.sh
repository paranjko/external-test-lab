#!/usr/bin/env bash
set -Eeuo pipefail
# One-time root preparation. Does not publish a release, change SSH keys or
# extend sudo permissions. CI subsequently writes static artifacts as ops.
[[ ${EUID} -eq 0 ]] || { echo 'run as root on the public edge' >&2; exit 2; }
[[ $# -eq 1 ]] || { echo 'usage: setup-bootstrap-publisher.sh PATH_TO_BOOTSTRAP_RELEASE_PY' >&2; exit 2; }
tool="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
edge=/srv/dai/edge
root=$edge/bootstrap
getent passwd ops >/dev/null
[[ -f "$edge/Caddyfile" && ! -L "$edge/Caddyfile" && -f "$edge/compose.yaml" && ! -L "$root" ]]
[[ -d "$root" ]] || install -d -m 0755 "$root"
temporary="$(mktemp -d "$edge/.bootstrap-setup-XXXXXXXX")"
# Retain the preimage outside the published tree for manual recovery.
cp -p "$edge/Caddyfile" "$temporary/Caddyfile.before"
python3 "$tool" routes "$edge/Caddyfile" "$temporary/Caddyfile"
cd "$edge"
docker compose exec -T caddy caddy validate --config "/edge/${temporary##*/}/Caddyfile" --adapter caddyfile
if ! cmp -s "$temporary/Caddyfile" "$edge/Caddyfile"; then
  # Preserve the existing bind-mounted inode; reload is graceful, not a restart.
  if ! { cat "$temporary/Caddyfile" >"$edge/Caddyfile" && docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile; }; then
    cat "$temporary/Caddyfile.before" >"$edge/Caddyfile"
    docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
    echo "route setup failed; restored config, backup=$temporary" >&2
    exit 1
  fi
fi
# The legacy current directory also needs write access for its first move
# into releases. Never recursively change existing artifact ownership.
python3 "$tool" permissions "$root" ops
runuser -u ops -- test -w "$root"
if [[ -d "$root/current" && ! -L "$root/current" ]]; then
  runuser -u ops -- test -w "$root/current"
fi
printf 'PASS bootstrap publisher prepared; previous Caddyfile retained at %s\n' "$temporary/Caddyfile.before"
