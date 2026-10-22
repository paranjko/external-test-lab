#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fixture="$tmp/srv/dai"
mkdir -p "$fixture/deploy" "$fixture/shared" "$fixture/inference/config" \
  "$fixture/inference/data" "$fixture/identity" "$fixture/dapi" \
  "$fixture/signer/tmkms/state" "$tmp/bin" "$tmp/srv/dai-archives"
printf 'COMPOSE_PROJECT_NAME=node0\nNODE_NAME=node0\nIS_GENESIS=true\n' >"$fixture/deploy/.env"
cat >"$fixture/deploy/compose.yaml" <<EOF
services:
  node:
    image: fixture/node
    volumes:
      - type: bind
        source: $fixture/inference
        target: /root/.inference
      - type: bind
        source: $fixture/identity
        target: /gdc-identity
      - type: bind
        source: $fixture/shared/genesis.json
        target: /root/genesis.json
  api:
    image: fixture/api
    volumes:
      - type: bind
        source: $fixture/inference
        target: /root/.inference
      - type: bind
        source: $fixture/dapi
        target: /root/.dapi
  tmkms:
    profiles: [signer]
    image: fixture/tmkms
    volumes:
      - type: bind
        source: $fixture/signer/tmkms
        target: /root/.tmkms
EOF
printf 'state_file = "/root/.tmkms/state/priv_validator_state.json"\n' >"$fixture/signer/tmkms/tmkms.toml"
printf '{"height":"0","round":0,"step":0}\n' >"$fixture/inference/data/priv_validator_state.json"
printf 'untouched app database\n' >"$fixture/inference/data/application.db"
printf 'untouched validator key\n' >"$fixture/inference/config/priv_validator_key.json"
jq -n '{chain_id:"fixture-1",genesis_time:"2026-10-20T10:00:00Z",consensus_params:{block:{max_bytes:"22020096"}},
  app_state:{inference:{model_list:[{id:"m1",proposed_by:"0xold",params:{ctx:4096}},{id:"m2",proposed_by:"0xold",params:{ctx:8192}}],params:{stake_denom:"ngonka"}},
    auth:{accounts:[]},bank:{balances:[]}}}' >"$tmp/old.json"
jq '.app_state.inference.model_list |= map(.proposed_by = "genesis")' "$tmp/old.json" >"$tmp/new.json"
cp "$tmp/old.json" "$fixture/shared/genesis.json"
cp "$tmp/old.json" "$fixture/inference/config/genesis.json"
old_sha="$(sha256sum "$tmp/old.json" | awk '{print $1}')"
new_sha="$(sha256sum "$tmp/new.json" | awk '{print $1}')"

cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
args="$*"
printf '%s\n' "$args" >>"$TEST_COMPOSE_LOG"
case "$args" in
  *' config --format json')
    jq -n --arg root "$TEST_ROOT_DIR" '{services:{
      node:{volumes:[{type:"bind",source:($root+"/inference"),target:"/root/.inference"},{type:"bind",source:($root+"/identity"),target:"/gdc-identity"},{type:"bind",source:($root+"/shared/genesis.json"),target:"/root/genesis.json"}]},
      api:{volumes:[{type:"bind",source:($root+"/inference"),target:"/root/.inference"},{type:"bind",source:($root+"/dapi"),target:"/root/.dapi"}]},
      tmkms:{volumes:[{type:"bind",source:($root+"/signer/tmkms"),target:"/root/.tmkms"}]}}}'
    ;;
  *' ps --status running -q node api tmkms')
    [[ "${TEST_RUNNING:-}" != true ]] || printf 'running-container-id\n'
    ;;
  *' logs --no-color --tail=500 node')
    if [[ "${TEST_BAD_LOGS:-}" == true ]]; then
      printf 'ABCI Replay Blocks appHeight=4 module=consensus stateHeight=4 storeHeight=4\nInitGenesis panic ProposedBy\n'
    else
      printf '\033[31mABCI Replay Blocks appHeight=0 module=consensus stateHeight=0 storeHeight=0\033[0m\nInitGenesis panic: ProposedBy\n'
    fi
    ;;
  *) echo "unexpected Docker command: $args" >&2; exit 97 ;;
esac
EOF
chmod +x "$tmp/bin/docker"
cat >"$tmp/bin/mv" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${TEST_FAIL_NODE_MOVE:-}" == true && ! -e "$TEST_MV_FAILED_ONCE" ]]; then
  count=0
  [[ ! -f "$TEST_MV_COUNT" ]] || count="$(<"$TEST_MV_COUNT")"
  count=$((count + 1))
  printf '%s\n' "$count" >"$TEST_MV_COUNT"
  if [[ "$count" == 2 ]]; then
    : >"$TEST_MV_FAILED_ONCE"
    exit 42
  fi
fi
exec /usr/bin/mv "$@"
EOF
chmod +x "$tmp/bin/mv"
cat >"$tmp/bin/cp" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${TEST_FAIL_STATE_COPY:-}" == true && "$#" == 4 \
  && "$3" == *"/data.before/priv_validator_state.json" \
  && ! -e "$TEST_CP_FAILED_ONCE" ]]; then
  : >"$TEST_CP_FAILED_ONCE"
  exit 43
fi
exec /usr/bin/cp "$@"
EOF
chmod +x "$tmp/bin/cp"
# Exercise the actual Compose CLI/profile behavior against the isolated YAML;
# the helper's state and lifecycle calls remain daemon-free mocks below.
docker compose --env-file "$fixture/deploy/.env" --profile '*' \
  -f "$fixture/deploy/compose.yaml" config --format json >"$tmp/actual-compose.json"
jq -e --arg root "$fixture" '
  any(.services.tmkms.volumes[]; .target == "/root/.tmkms" and .source == ($root+"/signer/tmkms"))
  and any(.services.node.volumes[]; .target == "/root/genesis.json" and .source == ($root+"/shared/genesis.json"))
' "$tmp/actual-compose.json" >/dev/null
export TEST_COMPOSE_LOG="$tmp/compose.log"
export TEST_ROOT_DIR="$fixture"
export TEST_MV_FAILED_ONCE="$tmp/mv-failed-once"
export TEST_MV_COUNT="$tmp/mv-count"
export TEST_CP_FAILED_ONCE="$tmp/cp-failed-once"
export PATH="$tmp/bin:$PATH"

run_replace() {
  bash "$ROOT/scripts/replace-unstarted-genesis.sh" \
    "$fixture" "$old_sha" "$tmp/new.json" "$new_sha" node0 "$tmp/srv/dai-archives"
}
run_refresh() {
  bash "$ROOT/scripts/replace-unstarted-genesis.sh" \
    "$fixture" "$new_sha" "$tmp/new.json" "$new_sha" node0 "$tmp/srv/dai-archives" --refresh-zero-height-db
}
before_db="$(sha256sum "$fixture/inference/data/application.db" | awk '{print $1}')"
before_key="$(sha256sum "$fixture/inference/config/priv_validator_key.json" | awk '{print $1}')"
run_replace
[[ "$(sha256sum "$fixture/shared/genesis.json" | awk '{print $1}')" == "$new_sha" ]]
[[ "$(sha256sum "$fixture/inference/config/genesis.json" | awk '{print $1}')" == "$new_sha" ]]
[[ "$(sha256sum "$fixture/inference/data/application.db" | awk '{print $1}')" == "$before_db" ]]
[[ "$(sha256sum "$fixture/inference/config/priv_validator_key.json" | awk '{print $1}')" == "$before_key" ]]
receipt="$(find "$tmp/srv/dai-archives" -name replace-receipt.json -type f -print -quit)"
jq -e --arg old "$old_sha" --arg new "$new_sha" \
  '.kind == "gdc-unstarted-genesis-replacement" and .status == "intent" and .old_genesis_sha256 == $old and .new_genesis_sha256 == $new and .changed_model_proposed_by_count == 2' \
  "$receipt" >/dev/null
jq -e --arg new "$new_sha" '.kind == "gdc-unstarted-genesis-replacement-complete" and .installed_genesis_sha256 == $new and .identity_state_preserved' \
  "$(dirname "$receipt")/completion-receipt.json" >/dev/null
[[ "$(find "$tmp/srv/dai-archives" -name '*.before.json' -type f | wc -l)" == 2 ]]
[[ "$(wc -l <"$TEST_COMPOSE_LOG")" == 3 ]]
! grep -Eq ' (stop|up|down|rm|exec) ' "$TEST_COMPOSE_LOG"

# Inject failure after the shared path has been atomically replaced but before
# the node path swap. The EXIT rollback must restore both exact old byte streams.
cp "$tmp/old.json" "$fixture/shared/genesis.json"
cp "$tmp/old.json" "$fixture/inference/config/genesis.json"
export TEST_FAIL_NODE_MOVE=true
if run_replace >"$tmp/rollback.out" 2>&1; then
  echo 'injected second-file move failure did not fail the replacement' >&2; exit 1
fi
unset TEST_FAIL_NODE_MOVE
cmp -s "$tmp/old.json" "$fixture/shared/genesis.json"
cmp -s "$tmp/old.json" "$fixture/inference/config/genesis.json"
rollback_receipt="$(find "$tmp/srv/dai-archives" -name rollback-receipt.json -type f -print -quit)"
[[ -n "$rollback_receipt" ]]
jq -e '.kind == "gdc-unstarted-genesis-replacement-rollback"' "$rollback_receipt" >/dev/null
reject_without_mutation() {
  local label="$1"; shift
  cp "$fixture/shared/genesis.json" "$tmp/$label.shared.before"
  cp "$fixture/inference/config/genesis.json" "$tmp/$label.node.before"
  if "$@"; then echo "accepted unsafe replacement case: $label" >&2; exit 1; fi
  cmp -s "$tmp/$label.shared.before" "$fixture/shared/genesis.json"
  cmp -s "$tmp/$label.node.before" "$fixture/inference/config/genesis.json"
}

# Existing Genesis hash mismatch refuses before any write.
reject_without_mutation wrong-old bash "$ROOT/scripts/replace-unstarted-genesis.sh" \
  "$fixture" "$(printf '%064d' 1)" "$tmp/new.json" "$new_sha" node0 "$tmp/srv/dai-archives"

# Functional-field change, nonzero signer state, external TMKMS state, running
# processes and logs without the zero-height InitGenesis evidence all refuse.
jq '.app_state.inference.params.stake_denom = "different"' "$tmp/new.json" >"$tmp/changed.json"
changed_sha="$(sha256sum "$tmp/changed.json" | awk '{print $1}')"
reject_without_mutation changed-json bash "$ROOT/scripts/replace-unstarted-genesis.sh" \
  "$fixture" "$old_sha" "$tmp/changed.json" "$changed_sha" node0 "$tmp/srv/dai-archives"
printf '{"height":"1","round":0,"step":0}\n' >"$fixture/inference/data/priv_validator_state.json"
reject_without_mutation nonzero-validator bash "$ROOT/scripts/replace-unstarted-genesis.sh" \
  "$fixture" "$old_sha" "$tmp/new.json" "$new_sha" node0 "$tmp/srv/dai-archives"
printf '{"height":"0","round":0,"step":0}\n' >"$fixture/inference/data/priv_validator_state.json"
printf '{"height":"2","round":0,"step":0}\n' >"$fixture/signer/tmkms/state/priv_validator_state.json"
reject_without_mutation nonzero-tmkms bash "$ROOT/scripts/replace-unstarted-genesis.sh" \
  "$fixture" "$old_sha" "$tmp/new.json" "$new_sha" node0 "$tmp/srv/dai-archives"
rm "$fixture/signer/tmkms/state/priv_validator_state.json"
export TEST_RUNNING=true
reject_without_mutation running bash "$ROOT/scripts/replace-unstarted-genesis.sh" \
  "$fixture" "$old_sha" "$tmp/new.json" "$new_sha" node0 "$tmp/srv/dai-archives"
unset TEST_RUNNING
export TEST_BAD_LOGS=true
reject_without_mutation bad-logs bash "$ROOT/scripts/replace-unstarted-genesis.sh" \
  "$fixture" "$old_sha" "$tmp/new.json" "$new_sha" node0 "$tmp/srv/dai-archives"

# The explicit DB-cache mode accepts only the exact already-corrected Genesis,
# archives the entire zero-height data directory, and reconstructs only the
# zero validator state. Inject a copy failure to verify directory rollback.
unset TEST_BAD_LOGS
cp "$tmp/new.json" "$fixture/shared/genesis.json"
cp "$tmp/new.json" "$fixture/inference/config/genesis.json"
printf '{"height":"0","round":0,"step":0}\n' >"$fixture/inference/data/priv_validator_state.json"
printf 'cached genesisDoc fixture\n' >"$fixture/inference/data/state.db"
printf 'cached app state fixture\n' >"$fixture/inference/data/application.db"
tree_hash_fixture() {
  (cd "$1" && find . -xdev -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum | sha256sum | awk '{print $1}')
}
data_before_refresh="$(tree_hash_fixture "$fixture/inference/data")"
export TEST_FAIL_STATE_COPY=true
if run_refresh >"$tmp/refresh-rollback.out" 2>&1; then
  echo 'injected data restore failure did not fail the DB refresh' >&2; exit 1
fi
unset TEST_FAIL_STATE_COPY
[[ "$(tree_hash_fixture "$fixture/inference/data")" == "$data_before_refresh" ]]
grep -RFlq 'gdc-unstarted-genesis-data-refresh-rollback' "$tmp/srv/dai-archives"

run_refresh
data_archive="$(find "$tmp/srv/dai-archives" -path '*/data.before' -type d -print -quit)"
[[ -n "$data_archive" ]]
[[ "$(tree_hash_fixture "$data_archive")" == "$data_before_refresh" ]]
[[ "$(find "$fixture/inference/data" -mindepth 1 -maxdepth 1 -type f -printf '%f\n')" == priv_validator_state.json ]]
jq -e --arg new "$new_sha" \
  '.kind == "gdc-unstarted-genesis-replacement-complete" and .mode == "--refresh-zero-height-db" and .installed_genesis_sha256 == $new and .archived_data_path == "data.before"' \
  "$(dirname "$data_archive")/completion-receipt.json" >/dev/null

# A positive-height state refuses without touching the newly prepared data or
# adding another archive, even though the installed Genesis is correct.
printf '{"height":"1","round":0,"step":0}\n' >"$fixture/inference/data/priv_validator_state.json"
positive_data_sha="$(tree_hash_fixture "$fixture/inference/data")"
archive_count_before="$(find "$tmp/srv/dai-archives" -path '*/data.before' -type d | wc -l)"
if run_refresh >"$tmp/positive-height.out" 2>&1; then
  echo 'DB refresh accepted positive validator height' >&2; exit 1
fi
[[ "$(tree_hash_fixture "$fixture/inference/data")" == "$positive_data_sha" ]]
[[ "$(find "$tmp/srv/dai-archives" -path '*/data.before' -type d | wc -l)" == "$archive_count_before" ]]

printf 'PASS unstarted Genesis replacement and zero-height DB refresh fixture\n'
