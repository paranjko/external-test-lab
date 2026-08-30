#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -ne 3 ]]; then
  echo 'usage: prepare-devshard-governance-state.sh CURRENT_PARAMS.json REQUESTED_VERSIONS.json GATEWAY_CREATOR' >&2
  exit 2
fi

current_params="$1"
requested_versions="$2"
creator="$3"

[[ "$creator" =~ ^gonka1[0-9a-z]+$ ]] || {
  echo 'gateway creator address is invalid' >&2
  exit 2
}

jq -e '
  type == "array"
  and all(.[];
    type == "object"
    and (keys | sort) == ["binary", "name", "sha256"]
    and (.name | type == "string" and test("^v[1-9][0-9]*$"))
    and (.binary | type == "string" and test("^https://"))
    and (.sha256 | type == "string" and test("^[0-9a-f]{64}$")))
  and ([.[].name] | unique | length) == length
' "$requested_versions" >/dev/null || {
  echo "requested DevShard protocol tuples are invalid: $requested_versions" >&2
  exit 2
}

jq -e '
  (.params // .).devshard_escrow_params as $params
  | ($params.allowed_creator_addresses | type) == "array"
  and all($params.allowed_creator_addresses[];
    type == "string" and test("^gonka1[0-9a-z]+$"))
  and (($params.allowed_creator_addresses | unique | length)
    == ($params.allowed_creator_addresses | length))
  and ($params.approved_versions | type) == "array"
  and all($params.approved_versions[];
    type == "object"
    and (.name | type == "string" and test("^v[1-9][0-9]*$"))
    and (.binary | type == "string" and test("^https://"))
    and (.sha256 | type == "string" and test("^[0-9a-f]{64}$")))
  and (($params.approved_versions | map(.name) | unique | length)
    == ($params.approved_versions | length))
' "$current_params" >/dev/null || {
  echo "current DevShard governance state is malformed: $current_params" >&2
  exit 2
}

if ! jq -e --slurpfile requested "$requested_versions" '
  (.params // .).devshard_escrow_params.approved_versions as $current
  | all($current[]; . as $live
      | any($requested[0][];
          .name == $live.name
          and .binary == $live.binary
          and .sha256 == $live.sha256))
' "$current_params" >/dev/null; then
  echo 'requested governance transition would rebind or omit an approved DevShard protocol tuple' >&2
  exit 1
fi

jq -c --slurpfile requested "$requested_versions" --arg creator "$creator" '
  (.params // .).devshard_escrow_params.allowed_creator_addresses as $current_creators
  | {
      approved_versions: $requested[0],
      allowed_creator_addresses:
        (if ($current_creators | length) == 0
         then []
         else ($current_creators + [$creator] | unique)
         end)
    }
' "$current_params"
