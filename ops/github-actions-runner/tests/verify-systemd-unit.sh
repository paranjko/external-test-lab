#!/usr/bin/env bash
set -Eeuo pipefail
root="$(mktemp -d)"
trap 'rm -rf -- "$root"' EXIT
install -d "$root/etc/systemd/system" "$root/usr/lib/systemd/system" "$root/srv/actions-runner/external-test-lab"
for unit in sysinit.target network-online.target multi-user.target; do
  printf '[Unit]\n' >"$root/usr/lib/systemd/system/$unit"
done
install -m 0644 "$(cd -- "$(dirname -- "$0")/.." && pwd -P)/github-actions-runner-external-test-lab.service" \
  "$root/etc/systemd/system/github-actions-runner-external-test-lab.service"
printf '#!/bin/sh\nexit 0\n' >"$root/srv/actions-runner/external-test-lab/run.sh"
chmod 0755 "$root/srv/actions-runner/external-test-lab/run.sh"
systemd-analyze verify --root="$root" github-actions-runner-external-test-lab.service
printf 'systemd unit fixture: PASS\n'
