#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 3 ]] || {
  echo 'usage: generate-candidate-binary-sbom.sh COMPONENT ARCHIVE OUTPUT' >&2
  exit 2
}

component="$1"
archive="$2"
output="$3"

case "$component" in
  inferenced|inferenced-operator) member=inferenced ;;
  decentralized-api) member=decentralized-api ;;
  edge-api) member=edge-api ;;
  devshardd) member=devshardd ;;
  *)
    echo "unsupported candidate binary component: $component" >&2
    exit 2
    ;;
esac

[[ -f "$archive" && ! -L "$archive" ]] || {
  echo "candidate binary archive is not a regular file: $archive" >&2
  exit 1
}
members="$(unzip -Z1 "$archive")"
[[ "$members" == "$member" ]] || {
  echo "candidate binary archive must contain only $member, got: $members" >&2
  exit 1
}

payload="$(mktemp -d)"
trap 'rm -rf "$payload"' EXIT
unzip -q "$archive" -d "$payload"
[[ -f "$payload/$member" && -x "$payload/$member" && ! -L "$payload/$member" ]] || {
  echo "candidate binary archive member is not a regular executable: $member" >&2
  exit 1
}
payload_entries="$(find "$payload" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)"
[[ "$payload_entries" == "$member" ]] || {
  echo "candidate binary SBOM payload contains unexpected entries: $payload_entries" >&2
  exit 1
}

SYFT_CHECK_FOR_APP_UPDATE=false syft scan "file:$payload/$member" \
  --source-name "$member" --output "spdx-json=$output"
[[ -s "$output" ]] || {
  echo 'candidate binary SBOM was not generated' >&2
  exit 1
}
jq -e --arg member "$member" '
  .name == $member and
  ([.files[]?.fileName] | unique) == [$member] and
  any(.packages[]?; .name == $member and .primaryPackagePurpose == "FILE")
' "$output" >/dev/null || {
  echo "candidate binary SBOM subject does not match published member: $member" >&2
  exit 1
}
