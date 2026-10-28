#!/usr/bin/env bash
# Exercise the JOIN CLI and renderer, then API/file updates through a strict transport fixture
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
install_test=false
if [[ ${1:-} == --install ]]; then
  [[ $EUID == 0 && -f /.dockerenv && ${GDC_TEST_DISPOSABLE_ROOT:-false} == true ]]
  [[ -d /srv/dai && -z $(find /srv/dai -mindepth 1 -print -quit) ]]
  install_test=true
elif [[ $# != 0 ]]; then exit 2; fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for variable in ${!GDC_@}; do unset "$variable"; done
unset CHAIN_ID
mkdir -p "$tmp/bin" "$tmp/deploy"
export GDC_HOME="$tmp/operator" GDC_MLNODE_BACKUP_DIR="$tmp/backups"
export TEST_STATE="$tmp/live.json" TEST_POSTS="$tmp/posts" TEST_CONFIG="$tmp/deploy/node-config.json"
export TEST_BOOTSTRAP="$tmp/bootstrap.json" TEST_ARCHIVES="$tmp"
cp "$ROOT/../bootstrap/gonka-devnet-community.json" "$TEST_BOOTSTRAP"
if $install_test; then
  # Stored ZIPs with inert shell executables, no build tool or download needed
  printf '%s' 'UEsDBBQAAAAAAAAAIVzihkXDEQAAABEAAAAKAAAAaW5mZXJlbmNlZCMhL2Jpbi9zaApleGl0IDAKUEsBAhQDFAAAAAAAAAAhXOKGRcMRAAAAEQAAAAoAAAAAAAAAAAAAAIABAAAAAGluZmVyZW5jZWRQSwUGAAAAAAEAAQA4AAAAOQAAAAAA' | base64 -d > "$tmp/node.zip"
  printf '%s' 'UEsDBBQAAAAAAAAAIVzihkXDEQAAABEAAAARAAAAZGVjZW50cmFsaXplZC1hcGkjIS9iaW4vc2gKZXhpdCAwClBLAQIUAxQAAAAAAAAAIVzihkXDEQAAABEAAAARAAAAAAAAAAAAAACAAQAAAABkZWNlbnRyYWxpemVkLWFwaVBLBQYAAAAAAQABAD8AAABAAAAAAAA=' | base64 -d > "$tmp/api.zip"
  jq --arg node_sha "$(sha256sum "$tmp/node.zip" | awk '{print $1}')" \
    --arg api_sha "$(sha256sum "$tmp/api.zip" | awk '{print $1}')" '
    .software.components.node.upgrade.artifact |= (.url="https://fixture.invalid/node.zip" | .sha256=$node_sha) |
    .software.components.api.upgrade.artifact |= (.url="https://fixture.invalid/api.zip" | .sha256=$api_sha)
  ' "$TEST_BOOTSTRAP" > "$tmp/bootstrap.next"
  mv "$tmp/bootstrap.next" "$TEST_BOOTSTRAP"
fi
export PATH="$tmp/bin:$PATH"
for tool in ssh scp wget; do
  printf '#!/bin/sh\necho "Unexpected external call" >&2\nexit 97\n' > "$tmp/bin/$tool"
  chmod +x "$tmp/bin/$tool"
done
cat > "$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
url='' data='' output='' write_status=false
while (($#)); do
  case "$1" in
    http://*|https://*) url=$1; shift ;;
    --data-binary) data=$(cat "${2#@}"); shift 2 ;;
    --data) data=$2; shift 2 ;;
    -o) output=$2; shift 2 ;;
    -H|--connect-timeout|--max-time|--retry|-X) shift 2 ;;
    -w) write_status=true; shift 2 ;;
    -fsS|-fsSL|-sS) shift ;;
    *) echo "Unexpected curl argument: $1" >&2; exit 97 ;;
  esac
done
if [[ ( $url == https://fixture.invalid/node.zip || $url == https://fixture.invalid/api.zip ) && -n $output ]]; then
  cp "$TEST_ARCHIVES/${url##*/}" "$output"
elif [[ $url == http://127.0.0.1:9200/admin/v1/nodes ]]; then
  if [[ -z $data ]]; then
    jq 'map({node:(. + {node_num:1,registration_seq:2}),state:{}})' "$TEST_STATE"
  else
    printf '%s\n' "$data" >> "$TEST_POSTS"
    [[ ${TEST_FAILURE:-} != reject ]] || exit 22
    if [[ ${TEST_FAILURE:-} != ignore ]]; then
      jq --argjson node "$data" 'map(select(.id != $node.id)) + [$node]' "$TEST_STATE" > "$TEST_STATE.next"
      mv "$TEST_STATE.next" "$TEST_STATE"
    fi
    if [[ ${TEST_FAILURE:-} == drift ]]; then
      jq '. + [{id:"concurrent-writer",max_concurrent:3}]' "$TEST_CONFIG" > "$TEST_CONFIG.next"
      cat "$TEST_CONFIG.next" > "$TEST_CONFIG"
    fi
    printf '%s\n' "$data"
    if $write_status; then printf '\n200'; fi
  fi
elif [[ $url == "$(jq -r '.seeds[0].api' "$TEST_BOOTSTRAP")/chain-api/productscience/inference/inference/models_all" ]]; then
  printf '%s\n' '{"model":[{"id":"Qwen/Qwen2.5-7B-Instruct","hf_repo":"Qwen/Qwen2.5-7B-Instruct","hf_commit":"a09a35458c702b33eeacc393d103063234e8bc28"},{"id":"Qwen/Qwen3-4B-Instruct-2507","hf_repo":"Qwen/Qwen3-4B-Instruct-2507","hf_commit":"cdbee75f17c01a7cc42f958dc650907174af0554"}]}'
else
  echo "Unexpected curl URL: $url" >&2; exit 97
fi
SH
chmod +x "$tmp/bin/curl"
cp "$ROOT/02-node/mlnode-max_concurrent.sh" "$ROOT/02-node/sync-node-config.sh" "$tmp/deploy/"
runtime='qwen3-0.6b:gonka1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
for model in Qwen/Qwen3-4B-Instruct-2507 Qwen/Qwen2.5-7B-Instruct; do
  if [[ $model == Qwen/Qwen3-4B-Instruct-2507 ]]; then expected=16; sequences=1; alias_name=four; else expected=32; sequences=32; alias_name=seven; fi
  bash "$ROOT/gdc.sh" host join --preflight "--model=$model" \
    --bootstrap-file "$TEST_BOOTSTRAP" --public-host fixture.example.test "$alias_name" > "$tmp/preflight.log"
  profiles=("$GDC_HOME/$alias_name/runs/"*/join-"$alias_name"/join-profile.v1.json)
  [[ ${#profiles[@]} == 1 && -f ${profiles[0]} ]]
  profile=${profiles[0]}
  jq -e --argjson expected "$expected" '.spec.deployment.host_envelope.mlnode_max_concurrent == $expected' "$profile" >/dev/null
  for _pass in 1 2; do
    bash "$ROOT/02-node/render-node-config.sh" --node-name "$alias_name" --runtime-id "$runtime" \
      --join-profile "$profile" --output "$TEST_CONFIG" >/dev/null
    jq -e --arg model "$model" --argjson expected "$expected" --arg sequences "$sequences" '
      .[0].max_concurrent == $expected and
      (.[0].models[$model].args | .[index("--max-num-seqs") + 1]) == $sequences
    ' "$TEST_CONFIG" >/dev/null
    printf '[]\n' > "$TEST_STATE"
    bash "$tmp/deploy/sync-node-config.sh" >/dev/null
    jq -e --argjson expected "$expected" 'length == 1 and .[0].max_concurrent == $expected' "$TEST_STATE" >/dev/null
  done
  printf 'PASS fresh JOIN and replay %s max_concurrent=%s engine_sequences=%s\n' "$model" "$expected" "$sequences"
  if $install_test; then
    for layout in data.generations/fixture gdc-node9; do
      (
        source "$ROOT/scripts/profile.sh"
        load_join_profile "$profile"
        env | LC_ALL=C sort | awk '/^[A-Z_]+_IMAGE=/' > "$tmp/node.env"
      )
      cat >> "$tmp/node.env" <<EOF
GDC_PROFILE_KIND=generated_join
GDC_JOIN_PROFILE_SHA256=$(sha256sum "$profile" | awk '{print $1}')
DATA_DIR=/srv/dai/$layout
IDENTITY_DIR=/srv/dai/identity
SIGNER_DIR=/srv/dai/signer
CHAIN_ID=fixture
KEY_NAME=fixture
ACCOUNT_PUBKEY=fixture
KEYRING_PASSWORD=fixture
POSTGRES_PASSWORD=fixture
PUBLIC_HOST=fixture.example.test
PUBLIC_URL=https://fixture.example.test
SEED_NODE_RPC_URL=https://seed.example.test/chain-rpc
SEED_NODE_P2P_URL=tcp://seed.example.test:5000
RPC_SERVER_URL_1=https://seed.example.test/chain-rpc
RPC_SERVER_URL_2=https://seed2.example.test/chain-rpc
P2P_EXTERNAL_ADDRESS=tcp://fixture.example.test:5000
SEED_API_URL=https://seed.example.test
GENESIS_SEEDS=fixture
GENESIS_FILE=/srv/dai/shared/genesis.json
NODE_CONFIG_FILE=./node-config.json
EOF
      printf '{}\n' > "$tmp/genesis.json"
      for _pass in 1 2; do
        bash "$ROOT/02-node/install-node.sh" --node-name "$alias_name" --env "$tmp/node.env" \
          --node-config "$TEST_CONFIG" --genesis "$tmp/genesis.json" --join-profile "$profile" > "$tmp/install.log" 2>&1 \
          || { cat "$tmp/install.log" >&2; exit 1; }
        cmp "$TEST_CONFIG" /srv/dai/deploy/node-config.json
        [[ -x /srv/dai/deploy/mlnode-max_concurrent.sh ]]
        printf '[]\n' > "$TEST_STATE"
        bash /srv/dai/deploy/sync-node-config.sh >/dev/null
        bash /srv/dai/deploy/mlnode-max_concurrent.sh "$runtime" "$expected" >/dev/null
        jq -e --argjson expected "$expected" '.[0].max_concurrent == $expected' "$TEST_STATE" >/dev/null
      done
      rm -rf /srv/dai/deploy
      printf 'PASS installed JOIN %s layout=%s with executable update helper\n' "$model" "$layout"
    done
  fi
  # Invalid limits are refused even when the profile checksum is recomputed
  for invalid in 0 -1 1.5; do
    jq --argjson limit "$invalid" '.spec.deployment.host_envelope.mlnode_max_concurrent=$limit' "$profile" > "$tmp/bad-profile.json"
    hash=$(jq -cS .spec "$tmp/bad-profile.json" | sha256sum | awk '{print $1}')
    jq --arg hash "$hash" '.profile_id=$hash' "$tmp/bad-profile.json" > "$tmp/bad-profile-bound.json"
    if bash "$ROOT/scripts/join-profile.sh" validate "$tmp/bad-profile-bound.json" > "$tmp/error" 2>&1; then exit 1; fi
  done
done

# A selected remote record with a slash in its ID must not become a backup path
id='Qwen/model:participant--secondary'
jq --arg id "$id" '.[0].id=$id | . + [ {id:"unrelated",host:"other",max_concurrent:9} ]' "$TEST_CONFIG" > "$tmp/original.json"
cp "$tmp/original.json" "$TEST_CONFIG"
cp "$tmp/original.json" "$TEST_STATE"
inode=$(stat -c %i "$TEST_CONFIG")
for limit in 16 16 32; do
  bash "$tmp/deploy/mlnode-max_concurrent.sh" "$id" "$limit" > "$tmp/update.log"
  jq --argjson limit "$limit" '.[0].max_concurrent=$limit | sort_by(.id)' "$tmp/original.json" > "$tmp/expected.json"
  jq -S 'sort_by(.id)' "$TEST_STATE" > "$tmp/live.sorted"
  jq -S . "$tmp/expected.json" > "$tmp/expected.sorted"
  cmp "$tmp/live.sorted" "$tmp/expected.sorted"
  jq -S 'sort_by(.id)' "$TEST_CONFIG" > "$tmp/file.sorted"
  cmp "$tmp/file.sorted" "$tmp/expected.sorted"
  [[ $(stat -c %i "$TEST_CONFIG") == "$inode" ]]
done
for invalid in 0 -1 1.5 '4 | .host="injected"'; do
  if bash "$tmp/deploy/mlnode-max_concurrent.sh" "$id" "$invalid" > "$tmp/error" 2>&1; then exit 1; fi
done
before=$(wc -l < "$TEST_POSTS")
if bash "$tmp/deploy/mlnode-max_concurrent.sh" absent 4 > "$tmp/error" 2>&1; then exit 1; fi
[[ $(wc -l < "$TEST_POSTS") == "$before" ]]
for failure in reject ignore drift; do
  cp "$tmp/original.json" "$TEST_CONFIG"
  cp "$tmp/original.json" "$TEST_STATE"
  if TEST_FAILURE=$failure bash "$tmp/deploy/mlnode-max_concurrent.sh" "$id" 4 > "$tmp/error" 2>&1; then exit 1; fi
  if [[ $failure == drift ]]; then
    jq -e 'any(.[]; .id == "concurrent-writer")' "$TEST_CONFIG" >/dev/null
  else
    cmp "$TEST_CONFIG" "$tmp/original.json"
  fi
done
printf 'PASS updates, repeated update, rollback, unrelated records, slash IDs, inode preservation and failure handling\n'
