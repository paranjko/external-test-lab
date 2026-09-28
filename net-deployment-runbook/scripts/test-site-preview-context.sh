#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$*" == *'/files?per_page=100'* ]]; then
  printf '%s\n' "$PREVIEW_FILE_PAGES"
elif [[ "$*" == *'/comments?per_page=100'* ]]; then
  printf '%s\n' "${PREVIEW_COMMENT_PAGES:-[[]]}"
else
  if [[ -n "${PREVIEW_PR_PAYLOAD:-}" ]]; then
    printf '%s\n' "$PREVIEW_PR_PAYLOAD"
  else
    printf '%s\n' '{"head":{"repo":{"full_name":"paranjko/external-test-lab"},"sha":"0123456789012345678901234567890123456789"},"base":{"sha":"9999999999999999999999999999999999999999"},"state":"open","draft":false}'
  fi
fi
SH
chmod +x "$tmp/bin/gh"
event="$tmp/event.json"
output="$tmp/output"
printf '%s\n' '{"workflow_run":{"pull_requests":[{"number":81}],"head_sha":"0123456789012345678901234567890123456789"}}' >"$event"

run_case() {
  local name="$1"
  local pages="$2"
  : >"$output"
  PREVIEW_FILE_PAGES="$pages" PATH="$tmp/bin:$PATH" GH_TOKEN=fixture \
    GITHUB_EVENT_PATH="$event" GITHUB_OUTPUT="$output" \
    GITHUB_REPOSITORY=paranjko/external-test-lab \
    "$root/scripts/site-preview-context.sh" publish
  grep -Fxq 'publish=true' "$output" || {
    echo "site change on $name page was not eligible" >&2
    exit 1
  }
}

run_no_preview_case() {
  : >"$output"
  PREVIEW_FILE_PAGES='[[{"filename":"docs/README.md"}]]' PATH="$tmp/bin:$PATH" GH_TOKEN=fixture \
    GITHUB_EVENT_PATH="$event" GITHUB_OUTPUT="$output" \
    GITHUB_REPOSITORY=paranjko/external-test-lab \
    "$root/scripts/site-preview-context.sh" publish
  grep -Fxq 'publish=false' "$output" || {
    echo 'non-preview change unexpectedly requested publication' >&2
    exit 1
  }
}

run_case first '[[{"filename":"net-deployment-runbook/04-ops/site/app.js"}],[{"filename":"docs/README.md"}]]'
run_case last '[[{"filename":"docs/README.md"}],[{"filename":"net-deployment-runbook/04-ops/site/app.js"}]]'
run_case platform '[[{"filename":"ops/preview/previewctl.sh"}]]'
run_case workflow '[[{"filename":".github/workflows/site-preview-publish.yml"}]]'
run_no_preview_case
grep -Fxq 'base_sha=9999999999999999999999999999999999999999' "$output" || {
  echo 'preview context did not bind the PR base revision' >&2
  exit 1
}

run_cleanup_case() {
  local name="$1"
  local event_payload="$2"
  local pr_payload="$3"
  local pages="$4"
  local comments="$5"
  local expected="$6"
  : >"$output"
  printf '%s\n' "$event_payload" >"$event"
  PREVIEW_FILE_PAGES="$pages" PREVIEW_COMMENT_PAGES="$comments" PREVIEW_PR_PAYLOAD="$pr_payload" PATH="$tmp/bin:$PATH" GH_TOKEN=fixture \
    GITHUB_EVENT_PATH="$event" GITHUB_OUTPUT="$output" \
    GITHUB_REPOSITORY=paranjko/external-test-lab \
    "$root/scripts/site-preview-context.sh" cleanup
  grep -Fxq "remove=$expected" "$output" || {
    echo "cleanup context returned the wrong result for $name" >&2
    exit 1
  }
}

# Closing a PR with no preview-relevant changes must not invoke the credentialed
# cleanup job. This is the regression that previously made ordinary PRs fail.
run_cleanup_case no-preview '{"action":"closed","pull_request":{"number":81}}' \
  '{"head":{"repo":{"full_name":"paranjko/external-test-lab"},"sha":"0123456789012345678901234567890123456789"},"base":{"sha":"9999999999999999999999999999999999999999"},"state":"closed","draft":false}' \
  '[[{"filename":"docs/README.md"}]]' '[[]]' false
run_cleanup_case preview-unpublished '{"action":"closed","pull_request":{"number":81}}' \
  '{"head":{"repo":{"full_name":"paranjko/external-test-lab"},"sha":"0123456789012345678901234567890123456789"},"base":{"sha":"9999999999999999999999999999999999999999"},"state":"closed","draft":false}' \
  '[[{"filename":"net-deployment-runbook/04-ops/site/index.html"}]]' '[[]]' false
run_cleanup_case preview-closed '{"action":"closed","pull_request":{"number":81}}' \
  '{"head":{"repo":{"full_name":"paranjko/external-test-lab"},"sha":"0123456789012345678901234567890123456789"},"base":{"sha":"9999999999999999999999999999999999999999"},"state":"closed","draft":false}' \
  '[[{"filename":"net-deployment-runbook/04-ops/site/index.html"}]]' '[[{"body":"<!-- gdc-preview:81 -->"}]]' true
run_cleanup_case preview-draft '{"action":"converted_to_draft","pull_request":{"number":81}}' \
  '{"head":{"repo":{"full_name":"paranjko/external-test-lab"},"sha":"0123456789012345678901234567890123456789"},"base":{"sha":"9999999999999999999999999999999999999999"},"state":"open","draft":true}' \
  '[[{"filename":"net-deployment-runbook/04-ops/site/index.html"}]]' '[[{"body":"<!-- gdc-preview:81 -->"}]]' true
printf 'PASS preview context aggregates every relevant paginated file page and binds source revisions\n'
