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
else
  printf '%s\n' '{"head":{"repo":{"full_name":"paranjko/external-test-lab"},"sha":"0123456789012345678901234567890123456789"},"state":"open","draft":false}'
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

run_case first '[[{"filename":"net-deployment-runbook/04-ops/site/app.js"}],[{"filename":"docs/README.md"}]]'
run_case last '[[{"filename":"docs/README.md"}],[{"filename":"net-deployment-runbook/04-ops/site/app.js"}]]'
printf 'PASS preview context aggregates every paginated file page\n'
