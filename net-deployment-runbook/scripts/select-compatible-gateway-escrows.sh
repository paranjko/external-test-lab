#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 1 && "$1" =~ ^v[1-9][0-9]*$ ]] || {
  echo 'usage: select-compatible-gateway-escrows.sh PROTOCOL' >&2
  exit 2
}

expected="$1"

jq -r --arg expected "$expected" '
  def normalize_version:
    if type != "string" then null
    elif test("^v[1-9][0-9]*$") then .
    elif test("^[1-9][0-9]*$") then "v" + .
    else null
    end;
  .devshards[]?
  | select(.active == true)
  | select((.runtime.phase // .phase // "") == "active")
  | select((.runtime.requests_blocked // .requests_blocked // false) == false)
  | ([
      .runtime.session_version?,
      .runtime.protocol_version?,
      .session_version?,
      .protocol_version?
    ] | map(select(. != null and . != ""))) as $reported
  | ($reported | map(normalize_version)) as $normalized
  | select(($reported | length) > 0)
  | select(all($normalized[]; . != null))
  | select(($normalized | unique) == [$expected])
  | (.id | tostring)
  | select(test("^[1-9][0-9]*$"))
'
