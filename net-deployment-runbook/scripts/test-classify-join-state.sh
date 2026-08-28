#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
classifier="$ROOT/scripts/classify-join-state.sh"

result="$($classifier "$tmp/identity" "$tmp/account" "$tmp/joined" '')"
jq -e '.classification == "new"' <<<"$result" >/dev/null
printf '{}' >"$tmp/restore.tar"
result="$($classifier "$tmp/identity" "$tmp/account" "$tmp/joined" "$tmp/restore.tar")"
jq -e '.classification == "restore_empty"' <<<"$result" >/dev/null
printf '{}' >"$tmp/identity"
printf '{}' >"$tmp/account"
touch "$tmp/joined"
result="$($classifier "$tmp/identity" "$tmp/account" "$tmp/joined" '')"
jq -e '.classification == "running_matched"' <<<"$result" >/dev/null
rm "$tmp/account"
result="$($classifier "$tmp/identity" "$tmp/account" "$tmp/joined" '')"
jq -e '.classification == "partial_identity"' <<<"$result" >/dev/null

for expected in new running_matched restore_empty managed_drift partial_identity identity_conflict lineage_conflict unreachable; do
  case "$expected" in
    new) snapshot='{"reachable":true,"identity":"absent","lineage":"matched","archive":"none","managed_drift":false}' ;;
    running_matched) snapshot='{"reachable":true,"identity":"matched","lineage":"matched","archive":"none","managed_drift":false}' ;;
    restore_empty) snapshot='{"reachable":true,"identity":"absent","lineage":"matched","archive":"matching","managed_drift":false}' ;;
    managed_drift) snapshot='{"reachable":true,"identity":"matched","lineage":"matched","archive":"none","managed_drift":true}' ;;
    partial_identity) snapshot='{"reachable":true,"identity":"partial","lineage":"matched","archive":"none","managed_drift":false}' ;;
    identity_conflict) snapshot='{"reachable":true,"identity":"conflict","lineage":"matched","archive":"none","managed_drift":false}' ;;
    lineage_conflict) snapshot='{"reachable":true,"identity":"matched","lineage":"conflict","archive":"none","managed_drift":false}' ;;
    unreachable) snapshot='{"reachable":false,"identity":"matched","lineage":"matched","archive":"none","managed_drift":false}' ;;
  esac
  printf '%s\n' "$snapshot" >"$tmp/$expected.json"
  result="$($classifier --snapshot "$tmp/$expected.json")"
  jq -e --arg expected "$expected" '.classification == $expected' <<<"$result" >/dev/null
done
printf 'PASS JOIN local pre-mutation classification contract\n'
