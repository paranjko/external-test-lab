#!/usr/bin/env bash
set -Eeuo pipefail

mode="${1:-}"
[[ "$mode" == publish || "$mode" == cleanup ]] || {
  echo 'usage: site-preview-context.sh publish|cleanup' >&2
  exit 2
}
[[ -r "${GITHUB_EVENT_PATH:-}" && -n "${GITHUB_OUTPUT:-}" && -n "${GITHUB_REPOSITORY:-}" ]] || {
  echo 'GitHub event, output and repository are required' >&2
  exit 2
}
export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
[[ -n "$GH_TOKEN" ]] || { echo 'GitHub token is required' >&2; exit 2; }

if [[ "$mode" == publish ]]; then
  number="$(jq -r '.workflow_run.pull_requests[0].number // empty' "$GITHUB_EVENT_PATH")"
  run_sha="$(jq -r '.workflow_run.head_sha // empty' "$GITHUB_EVENT_PATH")"
else
  number="$(jq -r '.pull_request.number // empty' "$GITHUB_EVENT_PATH")"
fi
[[ "$number" =~ ^[1-9][0-9]*$ ]] || { echo 'PR number is invalid' >&2; exit 2; }
pr="$(gh api "repos/$GITHUB_REPOSITORY/pulls/$number")"
head_repo="$(jq -r '.head.repo.full_name // empty' <<<"$pr")"
head_sha="$(jq -r '.head.sha // empty' <<<"$pr")"
base_sha="$(jq -r '.base.sha // empty' <<<"$pr")"
[[ "$head_sha" =~ ^[0-9a-f]{40}$ && "$base_sha" =~ ^[0-9a-f]{40}$ ]] || {
  echo 'PR head or base revision is invalid' >&2
  exit 2
}
same_repository=false
[[ "$head_repo" == "$GITHUB_REPOSITORY" ]] && same_repository=true
state="$(jq -r '.state // empty' <<<"$pr")"
draft="$(jq -r '.draft // false' <<<"$pr")"
if [[ "$mode" == cleanup ]]; then
  # Comments and the current diff are not a deployment inventory. Publication
  # may succeed before its comment fails, or a later revision may remove the
  # preview-relevant changes. The controller safely handles absent previews.
  # Read current state rather than trusting an old close/draft event.
  remove=false
  [[ "$same_repository" == true && ( "$state" == closed || ( "$state" == open && "$draft" == true ) ) ]] && remove=true
  printf 'remove=%s\nnumber=%s\nhead_sha=%s\n' "$remove" "$number" "$head_sha" >>"$GITHUB_OUTPUT"
  exit 0
fi
files="$(gh api --paginate --slurp "repos/$GITHUB_REPOSITORY/pulls/$number/files?per_page=100")"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
jq -r '.[][] | .filename' <<<"$files" | LC_ALL=C sort -u >"$tmp/changed-files.txt"
"$(dirname "$0")/plan-site-preview.py" \
  --files "$tmp/changed-files.txt" \
  --base "$base_sha" \
  --head "$head_sha" \
  --output "$tmp/preview-composition.json" \
  --repository-root "$(cd "$(dirname "$0")/.." && pwd)" \
  --endpoint-input "$(cd "$(dirname "$0")/.." && pwd)/04-ops/edge-node/PublicCaddyfile" \
  --endpoint-input "$(cd "$(dirname "$0")/.." && pwd)/04-ops/render-ops.sh"
preview_mode="$(jq -r '.mode // empty' "$tmp/preview-composition.json")"
[[ "$preview_mode" =~ ^(none|static|endpoint|combined)$ ]] || { echo 'preview mode is invalid' >&2; exit 2; }
has_preview=false
[[ "$preview_mode" != none ]] && has_preview=true

publish=false
[[ "$state" == open && "$draft" == false && "$same_repository" == true && "$has_preview" == true && "$head_sha" == "$run_sha" ]] && publish=true
printf 'publish=%s\nnumber=%s\nhead_sha=%s\nbase_sha=%s\n' "$publish" "$number" "$head_sha" "$base_sha" >>"$GITHUB_OUTPUT"
