#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
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
