#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$ROOT/.data/preview-publisher-tests"
mkdir -p "$tmp_root"
tmp="$(mktemp -d "$tmp_root/run.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/release"

for command in ssh rsync; do
  cat >"$tmp/bin/$command" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >>"$ISOLATED_PREVIEW_PUBLISH_LOG"
if [[ "$(basename "$0")" == ssh && "$*" == *'docker image load'* ]]; then
  cat >/dev/null
fi
SH
  chmod +x "$tmp/bin/$command"
done
cat >"$tmp/bin/docker" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >>"$ISOLATED_PREVIEW_PUBLISH_LOG"
case "$*" in
  *'image inspect'*'gdc.preview.source-revision'*) printf '%s\n' "${ISOLATED_PREVIEW_TEST_REVISION:?}" ;;
  *'image inspect'*'gdc.preview.managed'*) printf 'true\n' ;;
  *'image inspect'*) printf 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' ;;
  *'image save'*) printf 'fixture image archive\n' ;;
esac
SH
chmod +x "$tmp/bin/docker"

revision=0123456789012345678901234567890123456789
printf '<!doctype html>preview\n' >"$tmp/release/index.html"
printf '%s\n' '{"schema_version":1,"head_revision":"'"$revision"'","mode":"static","frontend_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","backend_digest":null}' >"$tmp/release/preview-composition.json"
printf 'private\n' >"$tmp/key"
printf 'edge.example ssh-ed25519 AAAAfixture\n' >"$tmp/known_hosts"
printf '%s\n' 'DEPLOY_HOST=edge.example' 'DEPLOY_USER=preview' "DEPLOY_PRIVATE_KEY_FILE=$tmp/key" "DEPLOY_KNOWN_HOSTS_FILE=$tmp/known_hosts" 'PREVIEW_PROMETHEUS_ORIGIN=http://monitoring.example:9099' >"$tmp/preview.env"
chmod 0600 "$tmp/key" "$tmp/known_hosts" "$tmp/preview.env"

export PATH="$tmp/bin:$PATH" ISOLATED_PREVIEW_PUBLISH_LOG="$tmp/commands" ISOLATED_PREVIEW_TEST_REVISION="$revision"
GDC_SITE_PREVIEW_ENV_FILE="$tmp/preview.env" "$ROOT/scripts/isolated-preview-publish.sh" publish "$tmp/release" 172 "$revision"
grep -Fq 'preview@edge.example' "$tmp/commands"
grep -Fq '/srv/preview/publisher/' "$tmp/commands"
grep -Fq '/srv/preview/staging/172/' "$tmp/commands"
grep -Eq "configure-observer.*monitoring\.example:9099" "$tmp/commands"
if grep -Fq '/srv/dai' "$tmp/commands"; then
  echo 'isolated publisher must not use the production site directory' >&2
  exit 1
fi

: >"$tmp/commands"
printf '%s\n' 'DEPLOY_USER=preview' "DEPLOY_PRIVATE_KEY_FILE=$tmp/key" "DEPLOY_KNOWN_HOSTS_FILE=$tmp/known_hosts" 'PREVIEW_PROMETHEUS_ORIGIN=http://monitoring.example:9099' >"$tmp/default-host.env"
chmod 0600 "$tmp/default-host.env"
GDC_SITE_PREVIEW_ENV_FILE="$tmp/default-host.env" "$ROOT/scripts/isolated-preview-publish.sh" publish "$tmp/release" 172 "$revision"
grep -Fq 'preview@gdc-node4' "$tmp/commands"

mkdir -p "$tmp/backend-release"
printf '<!doctype html>backend\n' >"$tmp/backend-release/index.html"
printf '%s\n' '{"schema_version":1,"head_revision":"'"$revision"'","mode":"backend","frontend_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","backend_digest":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}' >"$tmp/backend-release/preview-composition.json"
printf '%s\n' '{"schema_version":1,"source_revision":"'"$revision"'","source_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","rendered_caddy_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","backend_caddy_sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","image_id":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' >"$tmp/backend-release/backend-build.json"
: >"$tmp/commands"
GDC_SITE_PREVIEW_ENV_FILE="$tmp/preview.env" "$ROOT/scripts/isolated-preview-publish.sh" publish "$tmp/backend-release" 173 "$revision" gdc-preview-backend:fixture
grep -Fq 'docker image save sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$tmp/commands"
grep -Fq 'docker image load' "$tmp/commands"
grep -Fq "deploy '173' '$revision'" "$tmp/commands"
reserve_line="$(grep -n "test ! -e '/srv/preview/staging/173/" "$tmp/commands" | head -1 | cut -d: -f1)"
image_line="$(grep -n 'docker image save' "$tmp/commands" | head -1 | cut -d: -f1)"
[[ -n "$reserve_line" && -n "$image_line" && "$reserve_line" -lt "$image_line" ]] \
  || { echo 'publisher transferred backend image before reserving the remote artifact' >&2; exit 1; }

printf '%s\n' 'DEPLOY_HOST=edge.example' 'DEPLOY_USER=preview' "DEPLOY_PRIVATE_KEY_FILE=$tmp/key" "DEPLOY_KNOWN_HOSTS_FILE=$tmp/known_hosts" 'PREVIEW_PROMETHEUS_ORIGIN=http://monitoring.example:9099' 'UNSAFE=$(touch should-not-run)' >"$tmp/unsafe.env"
chmod 0600 "$tmp/unsafe.env"
if GDC_SITE_PREVIEW_ENV_FILE="$tmp/unsafe.env" "$ROOT/scripts/isolated-preview-publish.sh" publish "$tmp/release" 172 "$revision"; then
  echo 'publisher accepted an unallowlisted environment key' >&2
  exit 1
fi
[[ ! -e should-not-run ]] || { echo 'publisher executed environment data' >&2; exit 1; }

printf 'PASS isolated publisher uses the preview account and rejects executable environment data\n'
