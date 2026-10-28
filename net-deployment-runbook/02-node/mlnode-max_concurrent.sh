#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 2 && -n $1 && $2 =~ ^[1-9][0-9]{0,8}$ ]] || {
  echo 'Usage: mlnode-max_concurrent.sh MLNODE_ID MAX_CONCURRENT' >&2; exit 2;
}
MLNODE_ID=$1
max_concurrent=$2
deploy=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
config="$deploy/node-config.json"
[[ -f $config && ! -L $config && -w $config ]] || {
  echo "Expected writable regular file: $config" >&2; exit 1;
}
umask 077
exec 9>"$deploy/.node-config.lock"
flock -n 9 || { echo 'Another configuration update is running' >&2; exit 1; }
backup_root=${GDC_MLNODE_BACKUP_DIR:-/srv/backup}
mkdir -p "$backup_root"
backup_dir=$(mktemp -d "$backup_root/mlnode-concurrency.XXXXXX")
echo "apply for node.id=$MLNODE_ID"
echo "backup: $backup_dir"
trap 'rc=$?; if ((rc)); then echo "Update incomplete, inspect API and $backup_dir before retrying" >&2; fi' EXIT
cp "$config" "$backup_dir/node-config-before.json"
jq -e --arg id "$MLNODE_ID" --argjson limit "$max_concurrent" '
  if type != "array" or ([.[] | select(.id == $id)] | length) != 1
  then error("Expected exactly one bootstrap MLNode")
  else map(if .id == $id then .max_concurrent = $limit else . end) end
' "$config" > "$backup_dir/node-config-after.json"

curl -fsS --connect-timeout 5 --max-time 20 http://127.0.0.1:9200/admin/v1/nodes |
jq -e --arg id "$MLNODE_ID" '
  [.[] | select(.node.id == $id) | .node]
  | if length == 1 then .[0] else error("Expected exactly one MLNode") end
  | del(.node_num, .registration_seq)
' > "$backup_dir/before.json"
jq --argjson limit "$max_concurrent" '.max_concurrent = $limit' \
  "$backup_dir/before.json" > "$backup_dir/after.json"
curl -fsS --connect-timeout 5 --max-time 20 -X POST http://127.0.0.1:9200/admin/v1/nodes \
  -H 'Content-Type: application/json' --data-binary @"$backup_dir/after.json" \
  > "$backup_dir/response.json"
curl -fsS --connect-timeout 5 --max-time 20 http://127.0.0.1:9200/admin/v1/nodes \
  > "$backup_dir/readback.json"
jq -e --arg id "$MLNODE_ID" --slurpfile requested "$backup_dir/after.json" '
  [.[] | select(.node.id == $id) | .node | del(.node_num, .registration_seq)]
  | length == 1 and .[0] == $requested[0]
' "$backup_dir/readback.json" >/dev/null
cmp -s "$config" "$backup_dir/node-config-before.json" || {
  echo 'Bootstrap file changed concurrently, API may already be updated' >&2; exit 1;
}
# Keep the inode used by the running DAPI bind mount
cat "$backup_dir/node-config-after.json" > "$config"
cmp -s "$config" "$backup_dir/node-config-after.json"
jq -r '.[] | [.node.id, .node.host, (.node.max_concurrent | tostring)] | @tsv' "$backup_dir/readback.json"
echo 'VERIFIED API and node-config.json, no restart'
