#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$root/.data/isolated-preview-ci-tests"
mkdir -p "$tmp_root"
tmp="$(mktemp -d "$tmp_root/run.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
revision=0123456789012345678901234567890123456789

printf '%s\n' 'private key' >"$tmp/key"
printf '%s\n' 'preview.example ssh-ed25519 AAAAfixture' >"$tmp/known-hosts"
DEPLOY_HOST=preview.example DEPLOY_USER=preview DEPLOY_PRIVATE_KEY="$(cat "$tmp/key")" \
  DEPLOY_KNOWN_HOSTS="$(cat "$tmp/known-hosts")" PREVIEW_PROMETHEUS_ORIGIN=http://monitoring.example:9099 \
  PREVIEW_DEPLOY_ENV_FILE="$tmp/config/config.env" "$root/scripts/write-isolated-preview-deploy-env.sh"
[[ "$(stat -c '%a' "$tmp/config/config.env")" == 600 ]]
grep -Fxq 'DEPLOY_USER=preview' "$tmp/config/config.env"
grep -Fxq 'PREVIEW_PROMETHEUS_ORIGIN=http://monitoring.example:9099' "$tmp/config/config.env"

mkdir -p "$tmp/release" "$tmp/bin" "$tmp/scripts"
printf '%s\n' '{"mode":"static"}' >"$tmp/release/preview-composition.json"
cat >"$tmp/scripts/isolated-preview-publish.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$ISOLATED_PREVIEW_CI_CALL"
SH
chmod +x "$tmp/scripts/isolated-preview-publish.sh"
cp "$root/scripts/publish-isolated-preview-ci.sh" "$tmp/bin/publish-isolated-preview-ci.sh"
chmod +x "$tmp/bin/publish-isolated-preview-ci.sh"
site_release_dir="$tmp/release" preview_number=172 preview_revision="$revision" preview_backend_image=ignored \
  ISOLATED_PREVIEW_CI_CALL="$tmp/static-call" "$tmp/bin/publish-isolated-preview-ci.sh"
grep -Fxq "publish $tmp/release 172 $revision " "$tmp/static-call"

printf '%s\n' '{"mode":"combined"}' >"$tmp/release/preview-composition.json"
site_release_dir="$tmp/release" preview_number=172 preview_revision="$revision" preview_backend_image=gdc-preview:fixture \
  ISOLATED_PREVIEW_CI_CALL="$tmp/combined-call" "$tmp/bin/publish-isolated-preview-ci.sh"
grep -Fxq "publish $tmp/release 172 $revision gdc-preview:fixture" "$tmp/combined-call"

printf 'PASS isolated CI configuration and composition-aware publisher selection\n'
