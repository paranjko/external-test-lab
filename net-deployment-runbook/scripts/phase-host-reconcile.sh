#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"

action="${1:-}"; node="${2:-}"
[[ "$action" =~ ^(plan|apply|verify)$ && "$node" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || die 'usage: host reconcile plan|apply|verify <ssh-alias>'
load_project
topology_contains_node "$node" || die "unknown Host alias: $node"
[[ "${GONKA_RELEASE:-}" == 0.2.15 ]] || die 'Host reconcile requires a selected compatible Core release profile'
[[ "${DAPI_SOURCE_REF:-}" =~ ^release/v[0-9]+\.[0-9]+\.[0-9]+-post[0-9]+$ \
  && "${DAPI_COMMIT:-}" =~ ^[0-9a-f]{40}$ \
  && "${DAPI_UPGRADE_URL:-}" =~ ^https://github\.com/[^/]+/[^/]+/releases/download/[^/]+/decentralized-api-amd64\.zip$ \
  && "${DAPI_UPGRADE_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] \
  || die 'selected release profile lacks a complete DAPI runtime contract'
dapi_version="${DAPI_SOURCE_REF##*/v}"
target_profile_hash="$(profile_hash)"
record_phase_profile "host-reconcile-$action-$node"
run="$GDC_HOME/runs/${GDC_RUN_ID:-manual}/host-reconcile-$action-$node"; mkdir -p "$run"
export EVIDENCE_PHASE_NAME="host-reconcile-$action-$node"
install_evidence_exit_trap 'Host reconcile'
chain_base="${GDC_CHAIN_PUBLIC_BASE:-https://$GENESIS_PUBLIC_HOST}"; chain_base="${chain_base%/}"
capture_canonical_genesis "$chain_base/chain-rpc/genesis" "$run/genesis.json" || die 'cannot read canonical Genesis'
genesis_sha="$(genesis_sha256 "$run/genesis.json")"; chain_id="$(jq -er .chain_id "$run/genesis.json")"
[[ "$chain_id" == "$JOIN_NETWORK_CHAIN_ID" && "$genesis_sha" == "$JOIN_NETWORK_GENESIS_SHA256" ]] \
  || die 'selected release profile does not match the active chain lineage'
write_phase_lineage "$run" "$chain_id" "$genesis_sha"
ssh_ready "$node" || die "$node is unreachable"

observe='set -Eeuo pipefail; n=$(docker ps -q --filter label=com.docker.compose.service=node | head -n1); a=$(docker ps -q --filter label=com.docker.compose.service=api | head -n1); test -n "$n" -a -n "$a"; d=$(docker inspect -f "{{ index .Config.Labels \"com.docker.compose.project.working_dir\" }}" "$n"); test "${d#/srv/dai/}" != "$d" -a -f "$d/compose.yaml" -a -f "$d/.env"; printf "compose_dir=%s\\n" "$d"; curl -fsS --connect-timeout 3 --max-time 10 http://127.0.0.1:9000/v1/versions'
ssh -T "$node" "sudo -n bash -c $(printf '%q' "$observe")" >"$run/before.txt"
jq -e --arg core "$GONKA_RELEASE" '.node_version.version == ("v" + $core)' \
  < <(tail -n1 "$run/before.txt") >/dev/null \
  || die 'Host Core runtime is not the selected profile line; no Host mutation was made'
state="$STATE/host-reconcile/$GDC_RELEASE_PROFILE/$node.env"; mkdir -p "$(dirname "$state")"
if [[ "$action" == plan ]]; then
  printf 'chain_id=%s\ngenesis_sha256=%s\nprofile=%s\nprofile_hash=%s\n' \
    "$chain_id" "$genesis_sha" "$GDC_RELEASE_PROFILE" "$target_profile_hash" >"$state"
fi
if [[ "$action" == apply ]]; then
  [[ -s "$state" ]] \
    && grep -qx "genesis_sha256=$genesis_sha" "$state" \
    && grep -qx "profile_hash=$target_profile_hash" "$state" \
    || die 'run host reconcile plan for this Host and exact release profile first'
  apply='set -Eeuo pipefail; n=$(docker ps -q --filter label=com.docker.compose.service=node | head -n1); a=$(docker ps -q --filter label=com.docker.compose.service=api | head -n1); d=$(docker inspect -f "{{ index .Config.Labels \"com.docker.compose.project.working_dir\" }}" "$n"); h=$(docker inspect -f "{{range .Mounts}}{{if eq .Destination \"/root/.dapi\"}}{{.Source}}{{end}}{{end}}" "$a"); test "${d#/srv/dai/}" != "$d" -a -f "$d/.env" -a "${h#/srv/dai/}" != "$h"; x=$(mktemp); b=$(mktemp); trap "rm -f $x $b" EXIT; curl -fsSL --connect-timeout 15 --max-time 600 "$DAPI_URL" -o "$x"; printf "%s  %s\\n" "$DAPI_SHA" "$x" | sha256sum -c -; unzip -p "$x" decentralized-api >"$b"; test -s "$b"; chmod 0755 "$b"; t="$h/cosmovisor/upgrades/$DAPI_VERSION/bin"; install -d -m 0755 "$t"; install -m 0755 "$b" "$t/decentralized-api"; z=$(sha256sum "$b" | awk "{print \$1}"); printf "DAPI_VERSION=%s\\nDAPI_COMMIT=%s\\nDAPI_ARCHIVE_SHA256=%s\\nDAPI_BINARY_SHA256=%s\\nPROFILE=%s\\nPROFILE_HASH=%s\\n" "$DAPI_VERSION" "$DAPI_COMMIT" "$DAPI_SHA" "$z" "$PROFILE" "$PROFILE_HASH" >"$h/gdc-host-reconcile-dapi-runtime.env"; ln -s "upgrades/$DAPI_VERSION" "$h/cosmovisor/.current.new"; mv -Tf "$h/cosmovisor/.current.new" "$h/cosmovisor/current"; cd "$d"; docker compose --env-file .env config --quiet; docker compose --env-file .env up -d --no-deps --force-recreate api proxy versiond'
  ssh -T "$node" "sudo -n env DAPI_URL='$DAPI_UPGRADE_URL' DAPI_SHA='$DAPI_UPGRADE_SHA256' DAPI_VERSION='$dapi_version' DAPI_COMMIT='$DAPI_COMMIT' PROFILE='$GDC_RELEASE_PROFILE' PROFILE_HASH='$target_profile_hash' bash -c $(printf '%q' "$apply")"
fi
ssh -T "$node" "sudo -n bash -c $(printf '%q' "$observe")" >"$run/after.txt"
jq -e --arg dapi "$dapi_version" '.api_version.version == ("v" + $dapi)' \
  < <(tail -n1 "$run/after.txt") >/dev/null \
  || die 'DAPI runtime does not match the selected release profile after verification'
jq -n --arg action "$action" --arg node "$node" --arg profile "$GDC_RELEASE_PROFILE" \
  --arg profile_hash "$target_profile_hash" --arg chain_id "$chain_id" --arg genesis_sha256 "$genesis_sha" \
  '{schema_version:1,kind:"gdc-host-reconcile",action:$action,node:$node,profile:$profile,profile_hash:$profile_hash,chain_id:$chain_id,genesis_sha256:$genesis_sha256,verdict:"PASS"}' \
  >"$run/receipt.json"
printf '# Host reconcile: PASS\n\n%s %s on %s without an on-chain action.\n' \
  "$action" "$GDC_RELEASE_PROFILE" "$node" >"$run/verdict.md"
