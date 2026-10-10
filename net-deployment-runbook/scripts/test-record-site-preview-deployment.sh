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
if [[ "$*" == *'--input -'* ]]; then
  cat >/dev/null
fi
if [[ "$*" == *'/deployments'* && "$*" == *'--method POST'* ]]; then
  printf '%s\n' '{"id":123}'
elif [[ "$*" == *'/comments?per_page=100'* ]]; then
  if [[ "${PREVIEW_COMMENT_FAILURE:-}" == read ]]; then
    echo 'Resource not accessible by integration (HTTP 403)' >&2; exit 1
  fi
  if [[ -n "${PREVIEW_COMMENTS:-}" ]]; then
    printf '%s\n' "$PREVIEW_COMMENTS"
  else
    printf '%s\n' '[[{"id":456,"body":"<!-- gdc-preview:172 -->"}]]'
  fi
elif [[ "$*" == *'/comments'* && "$*" == *'--input -'* ]]; then
  if [[ "${PREVIEW_COMMENT_FAILURE:-}" == write ]]; then
    echo 'Resource not accessible by integration (HTTP 403)' >&2; exit 1
  fi
else
  echo "unexpected GitHub operation: $*" >&2; exit 97
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
for failure in read write; do
  if PREVIEW_GH_LOG="$tmp/$failure.log" PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY=paranjko/external-test-lab GITHUB_RUN_ID=9 \
    GITHUB_TOKEN=fixture PREVIEW_NUMBER=172 PREVIEW_REVISION=0123456789012345678901234567890123456789 \
    PREVIEW_COMMENT_FAILURE="$failure" PREVIEW_COMMENTS='[[]]' \
    "$root/scripts/record-site-preview-deployment.sh" >"$tmp/$failure.out" 2>&1; then
    echo "comment $failure failure was hidden" >&2; exit 1
  fi
  grep -Fq 'PASS recorded verified deployment' "$tmp/$failure.out"
  grep -Fq 'ERROR preview is deployed but' "$tmp/$failure.out"
done
printf 'PASS preview deployment record updates the stable comment and isolated URL\n'
