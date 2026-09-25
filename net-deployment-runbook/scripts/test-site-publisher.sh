#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="${TMPDIR:-$ROOT/../.data/preview-tmp}"
mkdir -p "$tmp_root"
tmp="$(mktemp -d "$tmp_root/gdc-site-publisher.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/release"

for command in ssh rsync; do
  cat >"$tmp/bin/$command" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SITE_RELEASE_TEST_LOG"
SH
  chmod +x "$tmp/bin/$command"
done

export PATH="$tmp/bin:$PATH"
export SITE_RELEASE_TEST_LOG="$tmp/commands"

make -C "$ROOT" publish-site-release \
  site_release_dir="$tmp/release" deploy_host=edge.example deploy_user=deployer
grep -Fq '/srv/dai/edge/site' "$SITE_RELEASE_TEST_LOG"
grep -Fq -- '--exclude preview/' "$SITE_RELEASE_TEST_LOG"

: >"$SITE_RELEASE_TEST_LOG"
make -C "$ROOT" publish-site-release \
  site_release_dir="$tmp/release" site_publish_prefix=preview/1 \
  deploy_host=edge.example deploy_user=deployer
grep -Fq '/srv/dai/edge/site/preview/1' "$SITE_RELEASE_TEST_LOG"

revision=0123456789012345678901234567890123456789
printf '<script src="/config.js"></script>\n' >"$tmp/release/index.html"
printf 'console.log("preview");\n' >"$tmp/release/app.js"
printf '%s\n' '{"mode":"combined","runtime_dependencies":{"config":"/config.js","status_base":"/preview/<PR>/status"}}' >"$tmp/release/preview-composition.json"
digest="$(bash "$ROOT/scripts/site-static-digest.sh" "$tmp/release")"
printf 'window.GDC_SITE_BUILD = {"revision":"%s","artifactDigest":"%s"};\n' "$revision" "$digest" >"$tmp/release/site-build.js"
: >"$SITE_RELEASE_TEST_LOG"
make -C "$ROOT" publish-site-preview \
  site_release_dir="$tmp/release" site_publish_prefix=preview/1 \
  deploy_host=edge.example deploy_user=deployer
grep -Fq 'https://gonka-dev.net/preview/1/status/participants' "$SITE_RELEASE_TEST_LOG"
grep -Fq '/srv/dai/edge/site/preview/.generations/1/.staging-0123456789012345678901234567890123456789' "$SITE_RELEASE_TEST_LOG"
grep -Fq 'bash -s -- publish 1 0123456789012345678901234567890123456789' "$SITE_RELEASE_TEST_LOG"
grep -Fq 'body=$(curl --fail --silent --show-error' "$SITE_RELEASE_TEST_LOG"
if grep -Fq '| test -s' "$ROOT/scripts/site-release.sh"; then
  echo 'preview endpoint readiness must not close the curl pipe early' >&2
  exit 1
fi
if grep -Fq 'publish-preview-endpoints' "$SITE_RELEASE_TEST_LOG" || grep -Fq 'publish-preview-static' "$SITE_RELEASE_TEST_LOG"; then
  echo 'preview publication unexpectedly used a split deployment action' >&2
  exit 1
fi

printf '%s\n' 'DEPLOY_HOST=edge.example' 'DEPLOY_USER=deployer' "DEPLOY_PRIVATE_KEY_FILE=$tmp/key" "DEPLOY_KNOWN_HOSTS_FILE=$tmp/known_hosts" >"$tmp/preview.env"
printf '%s\n' 'private-key' >"$tmp/key"
printf '%s\n' 'edge.example ssh-ed25519 AAAAfixture' >"$tmp/known_hosts"
chmod 0600 "$tmp/key" "$tmp/known_hosts" "$tmp/preview.env"
: >"$SITE_RELEASE_TEST_LOG"
GDC_SITE_PREVIEW_ENV_FILE="$tmp/preview.env" "$ROOT/scripts/site-release.sh" \
  publish-preview "$tmp/release" preview/1 '' ''
grep -Fq 'deployer@edge.example' "$SITE_RELEASE_TEST_LOG"

: >"$SITE_RELEASE_TEST_LOG"
make -C "$ROOT" rollback-site-preview site_publish_prefix=preview/1 \
  deploy_host=edge.example deploy_user=deployer
grep -Fq 'bash -s -- rollback 1' "$SITE_RELEASE_TEST_LOG"

: >"$SITE_RELEASE_TEST_LOG"
make -C "$ROOT" remove-site-release site_publish_prefix=preview/83 \
  deploy_host=edge.example deploy_user=deployer
grep -Fxq -- '-o BatchMode=yes deployer@edge.example rm -rf -- /srv/dai/edge/site/preview/83' "$SITE_RELEASE_TEST_LOG"

if make -C "$ROOT" remove-site-release site_publish_prefix=preview/0 \
  deploy_host=edge.example deploy_user=deployer; then
  echo 'invalid preview number unexpectedly removed a directory' >&2
  exit 1
fi
if make -C "$ROOT" publish-site-release site_release_dir="$tmp/release" \
  site_publish_prefix=/tmp/escape deploy_host=edge.example deploy_user=deployer; then
  echo 'arbitrary publication path unexpectedly succeeded' >&2
  exit 1
fi
if make -C "$ROOT" publish-site-release site_release_dir="$tmp/release" \
  site_publish_prefix=preview/10/../../escape deploy_host=edge.example deploy_user=deployer; then
  echo 'preview path traversal unexpectedly succeeded' >&2
  exit 1
fi
if make -C "$ROOT" publish-site-release site_release_dir="$tmp/release" \
  site_publish_prefix=preview/12foo deploy_host=edge.example deploy_user=deployer; then
  echo 'preview suffix unexpectedly succeeded' >&2
  exit 1
fi

printf 'PASS publisher confines publication and removal to validated site paths\n'
