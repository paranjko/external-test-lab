#!/usr/bin/env bash
set -Eeuo pipefail

number="${PREVIEW_NUMBER:-}"
revision="${PREVIEW_REVISION:-}"
[[ "$number" =~ ^[1-9][0-9]*$ && "$revision" =~ ^[0-9a-f]{40}$ ]] || {
  echo 'preview deployment identity is invalid' >&2
  exit 2
}
[[ -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]] || {
  echo 'GitHub repository and run ID are required' >&2
  exit 2
}
export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
[[ -n "$GH_TOKEN" ]] || { echo 'GitHub token is required' >&2; exit 2; }
environment='gonka-dev-site-preview'
preview_origin="${PREVIEW_ORIGIN:-https://preview.gonka-dev.net}"
[[ "$preview_origin" =~ ^https://[A-Za-z0-9.-]+$ ]] || {
  echo 'preview origin is invalid' >&2
  exit 2
}
environment_url="$preview_origin/$number/"
deployment_payload="$(jq -cn \
  --arg ref "$revision" --arg environment "$environment" \
  '{ref:$ref, environment:$environment, auto_merge:false, required_contexts:[], transient_environment:true, production_environment:false, description:"Verified PR preview publication"}')"
deployment="$(gh api --method POST "repos/$GITHUB_REPOSITORY/deployments" --input - <<<"$deployment_payload")"
deployment_id="$(jq -r '.id' <<<"$deployment")"
[[ "$deployment_id" =~ ^[0-9]+$ ]] || { echo 'deployment creation failed' >&2; exit 1; }
status_payload="$(jq -cn \
  --arg environment "$environment" --arg environment_url "$environment_url" \
  --arg log_url "${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" \
  '{state:"success", description:"Preview verified", environment:$environment, environment_url:$environment_url, log_url:$log_url}')"
gh api --method POST "repos/$GITHUB_REPOSITORY/deployments/$deployment_id/statuses" --input - <<<"$status_payload" >/dev/null

# Keep one durable discovery comment per preview. The marker is intentionally
# not user-facing and lets a later verified deployment update the same comment.
marker="<!-- gdc-preview:$number -->"
comment_body="$marker

Preview updated: $environment_url"
comments="$(gh api --paginate --slurp "repos/$GITHUB_REPOSITORY/issues/$number/comments?per_page=100")"
comment_id="$(jq -r --arg marker "$marker" '[.[][] | select(.body | contains($marker))] | last | .id // empty' <<<"$comments")"
if [[ "$comment_id" =~ ^[0-9]+$ ]]; then
  jq -n --arg body "$comment_body" '{body:$body}' | \
    gh api --method PATCH "repos/$GITHUB_REPOSITORY/issues/comments/$comment_id" --input - >/dev/null
else
  jq -n --arg body "$comment_body" '{body:$body}' | \
    gh api --method POST "repos/$GITHUB_REPOSITORY/issues/$number/comments" --input - >/dev/null
fi
printf 'PASS recorded preview deployment pr=%s url=%s\n' "$number" "$environment_url"
