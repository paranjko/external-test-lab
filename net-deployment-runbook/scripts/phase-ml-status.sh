#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
load_project

NODE="${1:-}"
topology_contains_node "$NODE" || die "ml status expects an alias from GDC_NODE_ALIASES, got: $NODE"
ssh_ready "$NODE" || die "$NODE is unreachable"

record="$(ssh -T "$NODE" 'sudo cat /srv/dai/deploy/gdc-ml-link.json 2>/dev/null' || true)"
jq -e --arg node "$NODE" '
  .schema_version == 2 and .validator_alias == $node
  and (.ml_hosts | type == "array" and length > 0)
  and all(.ml_hosts[]; (.ssh_alias | type) == "string" and (.endpoint | type) == "string" and (.node_id | type) == "string")
' <<<"$record" >/dev/null || die "$NODE has no managed additional ML endpoint record"

config="$(ssh -T "$NODE" 'sudo cat /srv/dai/deploy/node-config.json')"
jq -e 'type == "array" and length > 1' <<<"$config" >/dev/null \
  || die "$NODE does not retain a multi-endpoint ML configuration"
api_nodes="$(ssh -T "$NODE" 'curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:9200/admin/v1/nodes')"
jq -e 'type == "array"' <<<"$api_nodes" >/dev/null \
  || die "$NODE DAPI did not return its ML endpoint list"

while IFS=$'\t' read -r alias endpoint node_id; do
  [[ "$alias" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'ML endpoint record has an invalid SSH alias'
  ssh_ready "$alias" || die "additional ML Host $alias is unreachable"
  jq -e --arg id "$node_id" --arg host "$endpoint" \
    'any(.[]; .id == $id and .host == $host and .inference_port == 5000 and .poc_port == 5000)' \
    <<<"$config" >/dev/null || die "$NODE lacks configured ML endpoint $node_id at $endpoint"
  jq -e --arg id "$node_id" --arg host "$endpoint" \
    'any(.[]; .node.id == $id and .node.host == $host and .node.inference_port == 5000 and .node.poc_port == 5000)' \
    <<<"$api_nodes" >/dev/null || die "$NODE DAPI lacks ML endpoint $node_id at $endpoint"
  ssh -T "$alias" 'curl -fsS --connect-timeout 5 --max-time 15 http://127.0.0.1:5000/v1/models' \
    | jq -e '.data | type == "array" and length > 0' >/dev/null \
    || die "additional ML endpoint $alias does not serve models"
  printf 'PASS additional ML endpoint node_id=%s host=%s\n' "$node_id" "$alias"
done < <(jq -r '.ml_hosts[] | [.ssh_alias,.endpoint,.node_id] | @tsv' <<<"$record")
