#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
builder="$root/scripts/prepare-isolated-preview-ci-artifact.sh"
verifier="$root/scripts/verify-isolated-preview-ci-artifact.sh"
workflow="$root/../.github/workflows/site-preview-publish.yml"
build_workflow="$root/../.github/workflows/site-preview-build.yml"

for file in "$builder" "$verifier"; do
  [[ -x "$file" ]] || { echo "missing executable CI artifact helper: $file" >&2; exit 1; }
  bash -n "$file"
done
grep -Fq 'prepare-isolated-preview-ci.sh' "$builder"
grep -Fq 'SKIP no source-bound preview artifact was produced' "$builder"
grep -Fq 'verify-site-preview-artifact.sh' "$verifier"
grep -Fq 'docker image load -i' "$verifier"
grep -Fq 'download-artifact@v8.0.1' "$workflow"
grep -Fq 'verify-isolated-preview-ci-artifact' "$workflow"
grep -Fq 'prepare-isolated-preview-ci-artifact' "$build_workflow"
grep -Fq 'fetch-depth: 0' "$build_workflow"
if grep -Eq 'path: source|ref: \$\{\{ needs\.publish-context\.outputs\.head_sha \}\}' "$workflow"; then
  echo 'trusted publication workflow must not checkout untrusted PR source' >&2
  exit 1
fi
printf 'PASS CI transfers a verified artifact without a privileged PR checkout\n'

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/runbook/scripts" "$tmp/bin"
cp "$builder" "$root/scripts/verify-site-preview-artifact.sh" "$root/scripts/site-static-digest.sh" "$tmp/runbook/scripts/"
cat >"$tmp/runbook/scripts/prepare-isolated-preview-ci.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
mkdir -p "$PREVIEW_RELEASE_DIR"
cp -a "$TEST_PREPARED_ARTIFACT/." "$PREVIEW_RELEASE_DIR/"
SH
cat >"$tmp/bin/docker" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$TEST_DOCKER_LOG"
case "$*" in
  'image save '*) printf 'different archive bytes from another docker save\n' >"${*: -1}" ;;
  'image load '*) ;;
  *gdc.preview.source-revision*) printf '%s\n' "$PREVIEW_REVISION" ;;
  *gdc.preview.managed*) printf 'true\n' ;;
  'image inspect '*) printf 'sha256:%064d\n' 1 ;;
  *) exit 90 ;;
esac
SH
chmod +x "$tmp/runbook/scripts/prepare-isolated-preview-ci.sh" "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH" TEST_DOCKER_LOG="$tmp/docker.log"
export PREVIEW_REVISION=1111111111111111111111111111111111111111
export PREVIEW_BACKEND_IMAGE=gdc-preview:test
base=2222222222222222222222222222222222222222
digest="$(printf '%064d' 1)"
mkdir -p "$tmp/empty"
TEST_PREPARED_ARTIFACT="$tmp/empty" PREVIEW_RELEASE_DIR="$tmp/no-preview" \
  "$tmp/runbook/scripts/prepare-isolated-preview-ci-artifact.sh" >"$tmp/no-preview.log"
grep -Fq 'SKIP no source-bound preview artifact was produced' "$tmp/no-preview.log"
[[ ! -e "$TEST_DOCKER_LOG" ]]
for mode in static endpoint combined; do
  fixture="$tmp/fixture-$mode"
  mkdir -p "$fixture" "$tmp/backend"
  printf '<script src="config.js"></script><script src="preview-status-adapter.js"></script>\n' >"$fixture/index.html"
  printf 'window.app = true;\n' >"$fixture/app.js"
  printf 'window.config = {};\n' >"$fixture/config.js"
  printf 'window.adapter = true;\n' >"$fixture/preview-status-adapter.js"
  config="$(sha256sum "$fixture/config.js" | awk '{print $1}')"
  adapter="$(sha256sum "$fixture/preview-status-adapter.js" | awk '{print $1}')"
  jq -n --arg head "$PREVIEW_REVISION" --arg base "$base" --arg mode "$mode" \
    '{schema_version:1,base_revision:$base,head_revision:$head,mode:$mode,static_revision:$head,endpoint_revision:$head}' >"$fixture/preview-composition.json"
  jq -n --arg head "$PREVIEW_REVISION" --arg config "$config" --arg adapter "$adapter" --arg digest "$digest" \
    '{schema_version:1,source_revision:$head,preview_number:193,config_sha256:$config,status_adapter_sha256:$adapter,renderer_config_sha256:$digest}' >"$fixture/preview-runtime-config.json"
  jq -n --arg head "$PREVIEW_REVISION" --arg digest "$digest" \
    '{schema_version:1,source_revision:$head,source_archive_sha256:$digest,builder_image_id:("sha256:"+$digest)}' >"$fixture/frontend-build.json"
  if [[ "$mode" != static ]]; then
    printf 'original sealed archive\n' >"$fixture/backend-image.tar"
    sha256sum "$fixture/backend-image.tar" | awk '{print $1}' >"$fixture/backend-image.tar.sha256"
    jq -n --arg head "$PREVIEW_REVISION" --arg digest "$digest" \
      '{schema_version:1,source_revision:$head,preview_number:193,source_digest:$digest,rendered_caddy_sha256:$digest,backend_caddy_sha256:$digest,image_id:("sha256:"+$digest)}' >"$tmp/backend/backend-build.json"
  fi
  "$root/scripts/render-site-build-info.sh" "$fixture" "$PREVIEW_REVISION"
  "$root/scripts/prepare-isolated-preview-composition.sh" "$fixture" "$PREVIEW_REVISION" "$tmp/backend"
  export TEST_PREPARED_ARTIFACT="$fixture" PREVIEW_RELEASE_DIR="$tmp/release-$mode"
  "$tmp/runbook/scripts/prepare-isolated-preview-ci-artifact.sh"
  site_release_dir="$PREVIEW_RELEASE_DIR" preview_number=193 preview_base_revision="$base" \
    preview_revision="$PREVIEW_REVISION" preview_backend_image="$PREVIEW_BACKEND_IMAGE" "$verifier"
  for original in "$fixture"/*; do
    cmp "$original" "$PREVIEW_RELEASE_DIR/${original##*/}"
  done
done
if grep -q '^image save ' "$TEST_DOCKER_LOG"; then
  echo 'CI wrapper repackaged a sealed backend archive' >&2
  exit 1
fi
printf 'tampered archive\n' >>"$PREVIEW_RELEASE_DIR/backend-image.tar"
if site_release_dir="$PREVIEW_RELEASE_DIR" preview_number=193 preview_base_revision="$base" \
  preview_revision="$PREVIEW_REVISION" preview_backend_image="$PREVIEW_BACKEND_IMAGE" "$verifier" >"$tmp/tampered.log" 2>&1; then
  echo 'trusted verifier accepted a modified backend archive' >&2
  exit 1
fi
grep -Fq 'preview backend image archive digest is invalid' "$tmp/tampered.log"
printf 'PASS CI preserves sealed archives in static, backend and combined previews and rejects tampering\n'
