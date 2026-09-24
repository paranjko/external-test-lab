#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
phase="$ROOT/scripts/phase-preview.sh"
chores="$ROOT/../ops/chore"

bash -n "$phase" "$chores/user-preview.sh" "$chores/preview-admin.sh" "$chores/install-preview-admin.sh" "$chores/install-rootless-prerequisites.sh"

# A topology SSH alias is infrastructure inventory, not an authorization to
# use its legacy root transport. Preview setup must enter through ops, which
# supplies the scoped sudo boundary for the preview account lifecycle.
grep -Fq 'provision_user="${PREVIEW_PROVISION_USER:-ops}"' "$phase"
grep -Fq 'transport_target="${provision_user}@${target}"' "$phase"
grep -Fq 'ssh -T "$transport_target"' "$phase"
grep -Fq 'PREVIEW_BOOTSTRAP_USER:-root' "$phase"
grep -Fq 'install-preview-admin.sh' "$phase"
grep -Fq '/usr/local/lib/gdc-preview/preview-admin.sh verify' "$phase"
if grep -Fq 'ssh -T "$target"' "$phase"; then
  echo 'preview provisioning must not use the topology alias without the ops user' >&2
  exit 1
fi
if grep -Fq 'sudo -n bash -s' "$phase"; then
  echo 'preview provisioning must not grant ops a streamed root shell' >&2
  exit 1
fi

admin="$chores/preview-admin.sh"
installer="$chores/install-preview-admin.sh"
grep -Fq 'exec env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin' "$admin"
grep -Fq 'PREVIEW_AUTHORIZED_KEY="$key"' "$admin"
grep -Fq 'preview-admin.sh provision *' "$installer"
grep -Fq 'NOPASSWD:' "$installer"
grep -Fq 'install-rootless-prerequisites.sh' "$installer"
grep -Fq 'uidmap' "$chores/install-rootless-prerequisites.sh"
grep -Fq 'docker-ce-rootless-extras' "$chores/install-rootless-prerequisites.sh"
grep -Fq 'dbus-user-session' "$chores/install-rootless-prerequisites.sh"
grep -Fq 'slirp4netns' "$chores/install-rootless-prerequisites.sh"
grep -Fq 'fuse-overlayfs' "$chores/install-rootless-prerequisites.sh"
grep -Fq '"$ROOTLESS_PREREQUISITES_HELPER"' "$chores/user-preview.sh"
grep -Fq 'rootless prerequisite remains unavailable after installation' "$chores/install-rootless-prerequisites.sh"
grep -Fq 'systemctl start "user@$uid.service"' "$chores/user-preview.sh"
grep -Fq 'preview user systemd manager did not expose its bus' "$chores/user-preview.sh"
grep -Fq 'name=rootless' "$chores/user-preview.sh"
if grep -Fq '{{.Rootless}}' "$chores/user-preview.sh"; then
  echo 'preview verification must not depend on Docker info Rootless, which Docker 29 no longer exposes' >&2
  exit 1
fi
grep -Fq "printf '%s\\n' \"\$key\" >>\"\$destination\"" "$chores/user-preview.sh"
if grep -Fq "printf '%s\\n' \"\$key\" >\"\$destination\"" "$chores/user-preview.sh"; then
  echo 'preview provisioning must append an explicitly supplied deployment key without replacing another key' >&2
  exit 1
fi

printf 'PASS preview provisioning uses an explicit ops transport and fixed root helper\n'
