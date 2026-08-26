#!/usr/bin/env bash
set -Eeuo pipefail

repository="${1:-}"
tag="${2:-}"
expected_sha="${3:-}"
[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || { echo 'invalid GitHub repository' >&2; exit 2; }
[[ -n "$tag" ]] || { echo 'candidate release tag is required' >&2; exit 2; }
[[ "$expected_sha" =~ ^[0-9a-f]{40}$ ]] \
  || { echo 'candidate release target must be a full commit SHA' >&2; exit 2; }

encoded_tag="$(jq -rn --arg value "$tag" '$value | @uri')"
object="$(gh api "/repos/$repository/git/ref/tags/$encoded_tag")"
object_type="$(jq -er '.object.type' <<<"$object")"
object_sha="$(jq -er '.object.sha' <<<"$object")"
for ((depth = 0; depth < 8; depth++)); do
  [[ "$object_type" == tag ]] || break
  object="$(gh api "/repos/$repository/git/tags/$object_sha")"
  object_type="$(jq -er '.object.type' <<<"$object")"
  object_sha="$(jq -er '.object.sha' <<<"$object")"
done
[[ "$object_type" == commit ]] \
  || { echo "candidate release tag does not peel to a commit: $tag" >&2; exit 1; }
[[ "$object_sha" == "$expected_sha" ]] \
  || {
    printf 'candidate release target mismatch tag=%s expected=%s actual=%s\n' \
      "$tag" "$expected_sha" "$object_sha" >&2
    exit 1
  }
printf 'PASS candidate release target is bound to %s\n' "$expected_sha"
