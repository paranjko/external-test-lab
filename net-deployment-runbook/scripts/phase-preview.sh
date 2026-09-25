#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"
load_project

action="${1:-}"
key_file="${2:-}"
[[ "$action" =~ ^(bootstrap|provision|verify)$ ]] || die 'expected preview bootstrap, provision or verify'

repository_root="$(cd "$ROOT/.." && pwd)"
preview_script="$repository_root/ops/chore/user-preview.sh"
preview_installer="$repository_root/ops/chore/install-preview-admin.sh"
[[ -x "$preview_script" ]] || die 'preview provisioner is missing from this runbook revision'
[[ -x "$preview_installer" ]] || die 'preview administrator installer is missing from this runbook revision'
target="$PUBLIC_EDGE_NODE"
topology_contains_node "$target" || die "configured public edge is not a known Host: $target"
# The GDC topology alias may still be configured for a legacy root transport.
# Preview provisioning is deliberately an `ops` responsibility: the remote
# script requires its narrowly scoped sudo permission and must never make a
# direct root transport an unnoticed preview control plane.
provision_user="${PREVIEW_PROVISION_USER:-ops}"
[[ "$provision_user" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || die 'PREVIEW_PROVISION_USER is invalid'
transport_target="${provision_user}@${target}"

if [[ "$action" == bootstrap ]]; then
  [[ -z "$key_file" ]] || die 'preview bootstrap does not accept a public key'
  # This is the sole root transport. It installs a root-owned helper and a
  # narrow sudo policy; normal provision/verify traffic then uses ops only.
  bootstrap_user="${PREVIEW_BOOTSTRAP_USER:-root}"
  [[ "$bootstrap_user" == root ]] || die 'PREVIEW_BOOTSTRAP_USER must be root'
  step "Install preview administrator boundary on $target"
  tar -C "$(dirname "$preview_installer")" -cf - \
    "$(basename "$preview_installer")" user-preview.sh preview-admin.sh install-rootless-prerequisites.sh |
    ssh -T "${bootstrap_user}@${target}" 'set -Eeuo pipefail
      staging="$(mktemp -d /var/tmp/gdc-preview-bootstrap.XXXXXX)"
      trap "rm -rf -- \"$staging\"" EXIT
      tar -xf - -C "$staging"
      "$staging/install-preview-admin.sh" bootstrap'
  printf 'READY preview administrator boundary installed on %s; run preview provision next\n' "$target"
  exit 0
fi

if [[ "$action" == verify ]]; then
  step "Verify isolated preview runtime on $target"
  ssh -T "$transport_target" 'sudo -n /usr/local/lib/gdc-preview/preview-admin.sh verify'
  printf 'READY preview runtime verified on %s\n' "$target"
  exit 0
fi

[[ -r "$key_file" && ! -L "$key_file" ]] || die 'preview public key is unavailable or a symbolic link'
preview_key="$(<"$key_file")"
[[ "$preview_key" != *$'\n'* && "$preview_key" != *$'\r'* ]] || die 'preview public key must contain one line'
[[ "$preview_key" =~ ^(ssh-ed25519|sk-ssh-ed25519@openssh\.com|ecdsa-sha2-nistp(256|384|521)|ssh-rsa)[[:space:]][A-Za-z0-9+/=]+([[:space:]].*)?$ ]] || die 'preview public key is not an accepted SSH public key'

step "Provision isolated preview runtime on $target"
encoded_key="$(printf '%s' "$preview_key" | base64 -w 0)"
ssh -T "$transport_target" "sudo -n /usr/local/lib/gdc-preview/preview-admin.sh provision '$encoded_key'"
ssh -T "$transport_target" 'sudo -n /usr/local/lib/gdc-preview/preview-admin.sh verify'
printf 'READY preview runtime provisioned and verified on %s\n' "$target"
