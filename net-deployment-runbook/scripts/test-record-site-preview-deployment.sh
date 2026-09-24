#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$root/.data/record-preview-deployment-tests"
mkdir -p "$tmp_root"
tmp="$(mktemp -d "$tmp_root/run.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$PREVIEW_GH_LOG"
if [[ "$*" == *'/deployments'* && "$*" == *'--method POST'* ]]; then
  printf '%s\n' '{"id":123}'
elif [[ "$*" == *'/comments?per_page=100'* ]]; then
  printf '%s\n' '[[{"id":456,"body":"<!-- gdc-preview:172 -->\nold"}]]'
fi
SH
chmod +x "$tmp/bin/gh"

PREVIEW_GH_LOG="$tmp/gh.log" PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY=paranjko/external-test-lab GITHUB_RUN_ID=9 \
  GITHUB_TOKEN=fixture PREVIEW_NUMBER=172 PREVIEW_REVISION=0123456789012345678901234567890123456789 \
  PREVIEW_ORIGIN=https://preview.gonka-dev.net "$root/scripts/record-site-preview-deployment.sh"
grep -Fq 'issues/comments/456' "$tmp/gh.log"
if grep -Fq 'issues/172/comments --input' "$tmp/gh.log"; then
  echo 'stable preview comment was duplicated' >&2
  exit 1
fi
printf 'PASS preview deployment record updates the stable comment and isolated URL\n'
