#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 4 ]] || {
  echo 'usage: find-devshard-governance-prestate.sh RUNS_ROOT PROPOSAL_ID PROPOSAL.json PARAMS_SHA256' >&2
  exit 2
}

runs_root="$1"
proposal_id="$2"
proposal_file="$3"
expected_sha256="$4"
[[ -d "$runs_root" ]] || { echo "governance runs root is missing: $runs_root" >&2; exit 2; }
[[ "$proposal_id" =~ ^[1-9][0-9]*$ ]] || { echo 'governance proposal ID is invalid' >&2; exit 2; }
[[ -s "$proposal_file" ]] || { echo "governance proposal is missing: $proposal_file" >&2; exit 2; }
[[ "$expected_sha256" =~ ^[0-9a-f]{64}$ ]] || {
  echo 'governance pre-state SHA-256 is invalid' >&2
  exit 2
}

expected_proposal_fingerprint="$(jq -cS '(.proposal // .) | {metadata,messages}' "$proposal_file")"
while IFS= read -r candidate; do
  candidate_run="$(dirname "$candidate")"
  [[ -s "$candidate_run/proposal-id.txt" && -s "$candidate_run/proposal.json" ]] || continue
  [[ "$(<"$candidate_run/proposal-id.txt")" == "$proposal_id" ]] || continue
  candidate_proposal_fingerprint="$(jq -cS '{metadata,messages}' "$candidate_run/proposal.json" 2>/dev/null || true)"
  [[ "$candidate_proposal_fingerprint" == "$expected_proposal_fingerprint" ]] || continue
  candidate_sha256="$(jq -cS '(.params // .)' "$candidate" 2>/dev/null | sha256sum | awk '{print $1}')"
  if [[ "$candidate_sha256" == "$expected_sha256" ]]; then
    printf '%s\n' "$candidate"
    exit 0
  fi
done < <(find "$runs_root" -mindepth 2 -maxdepth 2 \
  -path '*-governance-devshard*/params-before.json' -type f -print | LC_ALL=C sort)

echo "trusted DevShard governance pre-state was not found for proposal=$proposal_id sha256=$expected_sha256" >&2
exit 1
