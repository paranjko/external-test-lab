#!/usr/bin/env bash
# Establish both directions before registering a remote worker. Safe to repeat
# for an already lent worker: only the parent's API may be recreated.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
parent="${1:-}"; worker="${2:-}"; endpoint="${3:-}"
[[ "$parent" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$worker" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$parent" != "$worker" ]] || exit 2
[[ "$endpoint" =~ ^[A-Za-z0-9.-]+$ ]] || exit 2
parent_host="$(ssh -G "$parent" | awk '$1 == "hostname" {print $2; exit}')"
[[ "$parent_host" =~ ^[A-Za-z0-9.-]+$ ]] || exit 2
# Resolve from the opposite host, never from the shared public website/edge.
callback_ip="$(ssh -T "$worker" "getent ahostsv4 '$parent_host' | awk 'NR == 1 {print \$1}'")"
worker_ip="$(ssh -T "$parent" "getent ahostsv4 '$endpoint' | awk 'NR == 1 {print \$1}'")"
[[ "$callback_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && "$worker_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo 'Cannot resolve callback peers to IPv4' >&2; exit 1; }
remote="$(ssh -T "$parent" 'mktemp -d /tmp/gdc-ml-callback.XXXXXXXX')"
[[ "$remote" =~ ^/tmp/gdc-ml-callback\.[A-Za-z0-9]+$ ]] || exit 1
trap 'ssh -T "$parent" "rm -f -- '\''$remote/apply.sh'\'' '\''$remote/firewall.sh'\''; rmdir -- '\''$remote'\''" >/dev/null 2>&1 || true' EXIT
scp -q "$ROOT/scripts/configure-ml-callback.sh" "$parent:$remote/apply.sh"
scp -q "$ROOT/00-host-prep/gonka-firewall.sh" "$parent:$remote/firewall.sh"
ssh -T "$parent" "sudo -n bash '$remote/apply.sh' '$callback_ip' '$worker_ip' '$remote/firewall.sh'"
# Probe inside the ML container: a successful Host curl does not prove Docker
# DNS/routing. /versions is a read-only endpoint on the actual callback listener.
ssh -T "$worker" "sudo -n bash -s -- '$callback_ip'" <<'REMOTE'
set -Eeuo pipefail
mapfile -t ids < <(docker ps --filter label=com.docker.compose.service=mlnode --format '{{.ID}}')
[[ "${#ids[@]}" == 1 ]] || { echo 'Expected one running MLNode for callback readback' >&2; exit 1; }
docker exec "${ids[0]}" curl -fsS --connect-timeout 5 --max-time 15 "http://$1:9100/versions" >/dev/null
REMOTE
printf 'READY remote ML callback verified from %s to %s\n' "$worker" "$parent"
