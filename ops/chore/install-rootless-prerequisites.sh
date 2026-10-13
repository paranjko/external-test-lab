#!/usr/bin/env bash
set -Eeuo pipefail

# Node4 is Debian-family. Keep the package reconciliation in the trusted,
# root-owned provisioner so a preview runtime can be restored from a clean
# host without a manual package-install step.

die() {
  printf 'ERROR %s\n' "$*" >&2
  exit 1
}

[[ "$EUID" -eq 0 ]] || die 'run as root'

needs_rootless_packages=false
for command in newuidmap newgidmap dockerd-rootless-setuptool.sh loginctl systemctl; do
  command -v "$command" >/dev/null || needs_rootless_packages=true
done
[[ "$needs_rootless_packages" == true ]] || exit 0

[[ -r /etc/os-release ]] || die 'cannot identify the operating system for rootless Docker prerequisites'
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
  debian|ubuntu)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
      uidmap \
      docker-ce-rootless-extras \
      dbus-user-session \
      slirp4netns \
      fuse-overlayfs
    ;;
  *) die "unsupported operating system for scripted rootless Docker prerequisites: ${ID:-unknown}" ;;
esac

for command in newuidmap newgidmap dockerd-rootless-setuptool.sh loginctl systemctl; do
  command -v "$command" >/dev/null || die "rootless prerequisite remains unavailable after installation: $command"
done
