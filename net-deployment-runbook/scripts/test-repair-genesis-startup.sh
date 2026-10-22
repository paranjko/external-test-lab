#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fixture="$tmp/srv/dai"
deploy="$fixture/deploy"
mkdir -p "$deploy/bootstrap-runtime/node/bin" "$deploy/bootstrap-runtime/api/bin" \
  "$fixture/shared" "$fixture/inference/config" "$fixture/inference/data" \
  "$fixture/dapi/cosmovisor/genesis/bin" "$fixture/identity/p2p" \
  "$fixture/signer/tmkms" "$tmp/bin" "$tmp/srv/dai-archives"
printf 'pinned Core bytes\n' >"$deploy/bootstrap-runtime/node/bin/inferenced"
printf 'pinned DAPI bytes\n' >"$deploy/bootstrap-runtime/api/bin/decentralized-api"
printf 'API archive carries Core sidecar\n' >"$deploy/bootstrap-runtime/api/bin/inferenced"
printf 'DAPI runtime sidecar gcc\n' >"$deploy/bootstrap-runtime/api/bin/libgcc_s.so.1"
printf 'DAPI runtime sidecar wasm\n' >"$deploy/bootstrap-runtime/api/bin/libwasmvm_muslc.x86_64.a"
core_sha="$(sha256sum "$deploy/bootstrap-runtime/node/bin/inferenced" | awk '{print $1}')"
dapi_sha="$(sha256sum "$deploy/bootstrap-runtime/api/bin/decentralized-api" | awk '{print $1}')"
core_commit=1111111111111111111111111111111111111111
dapi_commit=2222222222222222222222222222222222222222
core_image=registry/core@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
dapi_image=registry/api@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
for role in node api; do
  (cd "$deploy/bootstrap-runtime/$role/bin" && sha256sum * >"../SHA256SUMS")
  printf 'package archive receipt %s\n' "$role" >"$deploy/bootstrap-runtime/$role/archive.sha256"
done
cp "$ROOT/02-node/bootstrap-runtime.sh" "$deploy/bootstrap-runtime.sh"
cat >"$deploy/genesis-software.json" <<EOF
{"schema_version":1,"kind":"gdc-genesis-software-fragment","source":{"release_profile":"v2026.10.06"},"spec":{"deployment":{"software":{"components":{"node":{"version":"0.2.16-post1","commit":"$core_commit","image":"$core_image"},"api":{"version":"0.2.16-post1","commit":"$dapi_commit","image":"$dapi_image"}}}}},"binary_sha256":{"inferenced":"$core_sha","decentralized_api":"$dapi_sha"}}
EOF
fragment_sha="$(sha256sum "$deploy/genesis-software.json" | awk '{print $1}')"
jq -n --arg fragment "$fragment_sha" --arg cv 0.2.16-post1 --arg cc "$core_commit" \
  --arg dv 0.2.16-post1 --arg dc "$dapi_commit" --arg cb "$core_sha" --arg db "$dapi_sha" \
  --arg ci "$core_image" --arg di "$dapi_image" \
  '{schema_version:1,kind:"gdc-genesis-runtime-install",fragment_sha256:$fragment,
    core:{version:$cv,commit:$cc,image:$ci,binary_sha256:$cb},dapi:{version:$dv,commit:$dc,image:$di,binary_sha256:$db}}' \
  >"$deploy/.gdc-genesis-software"
printf '{"chain_id":"fixture-genesis"}\n' >"$fixture/shared/genesis.json"
genesis_sha="$(sha256sum "$fixture/shared/genesis.json" | awk '{print $1}')"
printf '{"p2p":"stable"}\n' >"$fixture/inference/config/node_key.json"
cp "$fixture/inference/config/node_key.json" "$fixture/identity/p2p/node_key.json"
printf '{"validator":"preserve"}\n' >"$fixture/inference/config/priv_validator_key.json"
printf '{"height":"0","round":0,"step":0}\n' >"$fixture/inference/data/priv_validator_state.json"
printf 'database-preserve-me\n' >"$fixture/inference/data/application.db"
printf '{"chain_id":"fixture-genesis"}\n' >"$fixture/inference/config/genesis.json"
printf 'signer-preserve-me\n' >"$fixture/signer/tmkms/tmkms.toml"
mkdir -p "$fixture/inference/cosmovisor/genesis/bin"
printf 'known obsolete Core bytes\n' >"$fixture/inference/cosmovisor/genesis/bin/inferenced"
old_core_sha="$(sha256sum "$fixture/inference/cosmovisor/genesis/bin/inferenced" | awk '{print $1}')"
printf 'old receipt\n' >"$fixture/inference/cosmovisor/genesis/archive.sha256"
ln -s genesis "$fixture/inference/cosmovisor/current"
cp "$deploy/bootstrap-runtime/api/bin/decentralized-api" "$fixture/dapi/cosmovisor/genesis/bin/decentralized-api"
printf 'old unbound receipt\n' >"$fixture/dapi/cosmovisor/genesis/archive.sha256"
ln -s genesis "$fixture/dapi/cosmovisor/current"
cat >"$deploy/.env" <<'EOF'
GDC_PROFILE_KIND=release
NODE_NAME=node0
IS_GENESIS=true
GDC_BOOTSTRAP_SOFTWARE=true
INFERENCED_IMAGE=registry/core@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
DAPI_IMAGE=registry/api@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
DATA_DIR=/srv/dai
IDENTITY_DIR=/srv/dai/identity
SIGNER_DIR=/srv/dai/signer
GENESIS_FILE=/srv/dai/shared/genesis.json
NODE_CONFIG_FILE=/srv/dai/node-config.json
DAPI_EXPECTED_VERSION=
DAPI_EXPECTED_COMMIT=
GDC_JOIN_STATESYNC_ENABLE=true
SYNC_WITH_SNAPSHOTS=true
OTHER=preserve-me
EOF
sed -i "s|/srv/dai|$fixture|g" "$deploy/.env"
cp "$ROOT/02-node/compose.yaml" "$deploy/compose.yaml"
compose_sha="$(sha256sum "$ROOT/02-node/compose.yaml" | awk '{print $1}')"
filter_b64="$(base64 <"$ROOT/02-node/bootstrap-compose.jq" | tr -d '\n')"
# Exercise the exact required-variable restoration and transformation using
# the real Docker Compose parser, before the lifecycle fixture mocks Docker.
bash "$ROOT/02-node/render-bootstrap-compose.sh" "$deploy/compose.yaml" "$deploy/.env" \
  >"$tmp/compose-rendered-by-real-docker.json"
jq -e '.services.api.environment.ACCOUNT_PUBKEY == "${ACCOUNT_PUBKEY:?ACCOUNT_PUBKEY is required}" and
  .services.node.environment.GDC_BOOTSTRAP_SOFTWARE == "true" and
  any(.services.node.volumes[]; .target == "/gdc-bootstrap-runtime" and .read_only == true)' \
  "$tmp/compose-rendered-by-real-docker.json" >/dev/null
cp "$tmp/compose-rendered-by-real-docker.json" "$deploy/compose.yaml"
jq -n \
  --arg core "$core_image" --arg api "$dapi_image" \
  --arg node "$fixture/inference" --arg dapi "$fixture/dapi" \
  --arg identity "$fixture/identity" --arg genesis "$fixture/shared/genesis.json" \
  '{services:{node:{image:$core,environment:{CONFIG_statesync__enable:"false",SYNC_WITH_SNAPSHOTS:"false"},volumes:[{type:"bind",source:$node,target:"/root/.inference"},{type:"bind",source:$identity,target:"/gdc-identity"},{type:"bind",source:$genesis,target:"/root/genesis.json"}]},api:{image:$api,environment:{GDC_JOIN_DAPI_EXPECTED_VERSION:"",GDC_JOIN_DAPI_EXPECTED_COMMIT:""},volumes:[{type:"bind",source:$node,target:"/root/.inference"},{type:"bind",source:$identity,target:"/gdc-identity"},{type:"bind",source:$dapi,target:"/root/.dapi"}]},proxy:{image:"proxy",environment:{},depends_on:{},logging:{},ports:[]}},networks:{default:{}},volumes:{}}' \
  >"$tmp/base-compose.json"
cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
args="$*"
printf '%s\n' "$args" >>"$TEST_DOCKER_LOG"
if [[ "$args" == *' config --no-interpolate '* ]]; then
  cat "$TEST_BASE_JSON"
elif [[ "$args" == *' config --format json' ]]; then
  file=''
  for ((i=1; i<=$#; i++)); do arg="${!i}"; if [[ "$arg" == -f ]]; then n=$((i+1)); file="${!n}"; fi; done
  env_file=''
  for ((i=1; i<=$#; i++)); do arg="${!i}"; if [[ "$arg" == --env-file ]]; then n=$((i+1)); env_file="${!n}"; fi; done
  value() { awk -F= -v k="$1" '$1==k {print substr($0,index($0,"=")+1); exit}' "$env_file"; }
  jq --arg dv "$(value DAPI_EXPECTED_VERSION)" --arg dc "$(value DAPI_EXPECTED_COMMIT)" \
    --arg ci "$(value INFERENCED_IMAGE)" --arg di "$(value DAPI_IMAGE)" \
    --arg data "$(value DATA_DIR)" --arg identity "$(value IDENTITY_DIR)" --arg genesis "$(value GENESIS_FILE)" '
    .services.node.image=$ci | .services.api.image=$di |
    .services.node.environment.GDC_BOOTSTRAP_SOFTWARE="true" |
    .services.api.environment.GDC_BOOTSTRAP_SOFTWARE="true" |
    .services.node.environment.CONFIG_statesync__enable="false" |
    .services.node.environment.SYNC_WITH_SNAPSHOTS="false" |
    .services.api.environment.GDC_JOIN_DAPI_EXPECTED_VERSION=$dv |
    .services.api.environment.GDC_JOIN_DAPI_EXPECTED_COMMIT=$dc |
    .services.node.volumes |= map(if .target == "/root/.inference" then .source=($data+"/inference")
      elif .target == "/gdc-identity" then .source=$identity
      elif .target == "/root/genesis.json" then .source=$genesis else . end) |
    .services.api.volumes |= map(if .target == "/root/.inference" then .source=($data+"/inference")
      elif .target == "/gdc-identity" then .source=$identity
      elif .target == "/root/.dapi" then .source=($data+"/dapi") else . end)
  ' "$file"
elif [[ "$args" == *' stop node api' || "$args" == *' ps --status running -q node api' ]]; then
  exit 0
elif [[ "$args" == *' up -d --no-deps --force-recreate node api' ]]; then
  exit 0
else
  echo "unexpected docker invocation: $args" >&2; exit 97
fi
EOF
chmod +x "$tmp/bin/docker"
export TEST_DOCKER_LOG="$tmp/docker.log" TEST_BASE_JSON="$tmp/base-compose.json"
old_validator_sha="$(sha256sum "$fixture/inference/config/priv_validator_key.json" | awk '{print $1}')"
old_db_sha="$(sha256sum "$fixture/inference/data/application.db" | awk '{print $1}')"
PATH="$tmp/bin:$PATH" bash "$ROOT/scripts/repair-genesis-startup-remote.sh" \
  "$fixture" "$genesis_sha" "$fragment_sha" node0 "$tmp/srv/dai-archives" "$compose_sha" "$filter_b64" "$old_core_sha"
[[ "$(sha256sum "$fixture/inference/cosmovisor/current/bin/inferenced" | awk '{print $1}')" == "$core_sha" ]]
[[ "$(sha256sum "$fixture/dapi/cosmovisor/current/bin/decentralized-api" | awk '{print $1}')" == "$dapi_sha" ]]
for entry in inferenced libgcc_s.so.1 libwasmvm_muslc.x86_64.a; do
  cmp -s "$deploy/bootstrap-runtime/api/bin/$entry" "$fixture/dapi/cosmovisor/current/bin/$entry"
done
cmp -s "$deploy/bootstrap-runtime/api/archive.sha256" "$fixture/dapi/cosmovisor/genesis/archive.sha256"
[[ "$(sha256sum "$fixture/inference/config/priv_validator_key.json" | awk '{print $1}')" == "$old_validator_sha" ]]
[[ "$(sha256sum "$fixture/inference/data/application.db" | awk '{print $1}')" == "$old_db_sha" ]]
grep -Fq '"target": "/gdc-bootstrap-runtime"' "$deploy/compose.yaml"
[[ -n "$(find "$tmp/srv/dai-archives" -path '*/node-cosmovisor/genesis/bin/inferenced' -type f -print -quit)" ]]
repair_receipt="$(find "$tmp/srv/dai-archives" -name repair-receipt.json -type f -print -quit)"
jq -e --arg before "$old_core_sha" --arg genesis "$genesis_sha" \
  '.node_cosmovisor_genesis_before_sha256 == $before and .approved_genesis_sha256 == $genesis' \
  "$repair_receipt" >/dev/null
grep -Fxq 'OTHER=preserve-me' "$deploy/.env"
grep -Fq 'up -d --no-deps --force-recreate node api' "$TEST_DOCKER_LOG"

# Simulate an interrupted attempt after Compose was transformed and the Core
# runtime was replaced: resume against the rendered Compose without requiring
# the original base-template digest again.
PATH="$tmp/bin:$PATH" bash "$ROOT/scripts/repair-genesis-startup-remote.sh" \
  "$fixture" "$genesis_sha" "$fragment_sha" node0 "$tmp/srv/dai-archives" "$compose_sha" "$filter_b64" "$old_core_sha"

cp "$deploy/.env" "$tmp/env.after-success"
if PATH="$tmp/bin:$PATH" bash "$ROOT/scripts/repair-genesis-startup-remote.sh" \
  "$fixture" "$(printf '%064d' 1)" "$fragment_sha" node0 "$tmp/srv/dai-archives" "$compose_sha" "$filter_b64" "$old_core_sha" >"$tmp/mismatch.out" 2>&1; then
  echo 'startup repair accepted an unapproved existing Genesis' >&2; exit 1
fi
cmp -s "$deploy/.env" "$tmp/env.after-success"

cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
expected="-T node0 sudo bash -s -- /srv/dai $EXPECTED_GENESIS_SHA256 $FRAGMENT_SHA256 node0 /srv/dai-archives $COMPOSE_SHA256 $FILTER_B64"
[[ "$*" == "$expected" ]] || { echo "unexpected SSH invocation: $*" >&2; exit 97; }
cat >"$TEST_SSH_PAYLOAD"
EOF
chmod +x "$tmp/bin/ssh"
export EXPECTED_GENESIS_SHA256="$genesis_sha" FRAGMENT_SHA256="$fragment_sha" \
  COMPOSE_SHA256="$compose_sha" FILTER_B64="$filter_b64" TEST_SSH_PAYLOAD="$tmp/ssh-payload.sh"
PATH="$tmp/bin:$PATH" bash "$ROOT/scripts/repair-genesis-startup.sh" node0 "$genesis_sha" "$deploy/genesis-software.json"
cmp -s "$ROOT/scripts/repair-genesis-startup-remote.sh" "$TEST_SSH_PAYLOAD"
printf 'PASS scoped Genesis runtime repair fixture\n'
