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
  action="$(jq -r '.action // empty' "$GITHUB_EVENT_PATH")"
fi
[[ "$number" =~ ^[1-9][0-9]*$ ]] || { echo 'PR number is invalid' >&2; exit 2; }
pr="$(gh api "repos/$GITHUB_REPOSITORY/pulls/$number")"
files="$(gh api --paginate --slurp "repos/$GITHUB_REPOSITORY/pulls/$number/files?per_page=100")"
head_repo="$(jq -r '.head.repo.full_name // empty' <<<"$pr")"
head_sha="$(jq -r '.head.sha // empty' <<<"$pr")"
same_repository=false
[[ "$head_repo" == "$GITHUB_REPOSITORY" ]] && same_repository=true
has_site_change=false
jq -e 'any(.[][]; .filename | startswith("net-deployment-runbook/04-ops/site/"))' <<<"$files" >/dev/null && has_site_change=true

if [[ "$mode" == publish ]]; then
  state="$(jq -r '.state // empty' <<<"$pr")"
  draft="$(jq -r '.draft // false' <<<"$pr")"
  publish=false
  [[ "$state" == open && "$draft" == false && "$same_repository" == true && "$has_site_change" == true && "$head_sha" == "$run_sha" ]] && publish=true
  printf 'publish=%s\nnumber=%s\nhead_sha=%s\n' "$publish" "$number" "$head_sha" >>"$GITHUB_OUTPUT"
else
  draft="$(jq -r '.draft // false' <<<"$pr")"
  remove=false
  [[ "$same_repository" == true && ( "$action" == closed || "$draft" == true || "$has_site_change" == false ) ]] && remove=true
  printf 'remove=%s\nnumber=%s\n' "$remove" "$number" >>"$GITHUB_OUTPUT"
fi
