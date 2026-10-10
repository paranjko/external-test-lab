#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# -eq 3 ]] || { echo 'usage: publish-bootstrap-release.sh RELEASE HOST USER' >&2; exit 2; }
release=$1 host=$2 user=$3
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${BOOTSTRAP_PUBLISH_ROOT:-/srv/dai/edge/bootstrap}"
origin="${BOOTSTRAP_PUBLIC_ORIGIN:-https://gonka-dev.net}"
[[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ && "$user" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || exit 2
[[ "$root" =~ ^(/[A-Za-z0-9_-][A-Za-z0-9._-]*){3,}$ ]] || { echo 'unsafe bootstrap publication root' >&2; exit 2; }
for command in python3 ssh rsync; do
  command -v "$command" >/dev/null || { echo "required publication command missing: $command" >&2; exit 2; }
done
generation="$(python3 "$script_dir/bootstrap-release.py" check "$release")"
ssh_options=(-T -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes)
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
if [[ -n "${DEPLOY_PRIVATE_KEY_FILE:-}" || -n "${DEPLOY_KNOWN_HOSTS_FILE:-}" ]]; then
  [[ -r "${DEPLOY_PRIVATE_KEY_FILE:-}" && -r "${DEPLOY_KNOWN_HOSTS_FILE:-}" ]] || exit 2
  ssh_options+=(-o IdentitiesOnly=yes -i "$DEPLOY_PRIVATE_KEY_FILE" -o "UserKnownHostsFile=$DEPLOY_KNOWN_HOSTS_FILE")
else
  [[ -n "${DEPLOY_PRIVATE_KEY:-}" && -n "${DEPLOY_KNOWN_HOSTS:-}" ]] || {
    echo 'set the publisher private key and pinned known_hosts' >&2; exit 2;
  }
  printf '%s\n' "$DEPLOY_PRIVATE_KEY" >"$temporary/key"
  printf '%s\n' "$DEPLOY_KNOWN_HOSTS" >"$temporary/known_hosts"
  chmod 0600 "$temporary/key" "$temporary/known_hosts"
  ssh_options+=(-o IdentitiesOnly=yes -i "$temporary/key" -o "UserKnownHostsFile=$temporary/known_hosts")
fi
remote="$user@$host"
transport="$(printf '%q ' ssh "${ssh_options[@]}")"
# root, remote and generation have been constrained before remote interpolation.
# shellcheck disable=SC2029
upload="$(ssh "${ssh_options[@]}" "$remote" "test -w '$root' && mktemp -d '$root/.upload-XXXXXXXXXXXX'")"
[[ "$upload" == "$root/"* && "${upload#"$root/"}" =~ ^\.upload-[A-Za-z0-9]{12}$ ]] || {
  echo 'unexpected remote staging path' >&2; exit 1;
}
rsync -rltp --chmod=D755,F644 -e "$transport" "$release/" "$remote:$upload/"
# shellcheck disable=SC2029
activation="$(ssh "${ssh_options[@]}" "$remote" "python3 - activate '$root' '$upload' '$generation'" <"$script_dir/bootstrap-release.py")"
printf '%s\n' "$activation"
if ! python3 "$script_dir/bootstrap-release.py" verify "$release" "$origin"; then
  if [[ "$activation" == 'PASS activated '* ]]; then
    # shellcheck disable=SC2029
    ssh "${ssh_options[@]}" "$remote" "python3 - rollback '$root' '$generation'" <"$script_dir/bootstrap-release.py" || {
      echo 'rollback failed; inspect retained release and receipt before retrying' >&2;
    }
  fi
  exit 1
fi
