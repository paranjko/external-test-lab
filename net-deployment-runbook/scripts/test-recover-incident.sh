#!/usr/bin/env bash
set -Eeuo pipefail
RUNBOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
export GDC_HOME="$scratch/operator"
unset GDC_INTERNAL_DATA_ROOT GDC_ENV
source "$RUNBOOK/scripts/recover-incident.sh"
# These names exist only in this reproducible mock. SSH aliases deliberately
# differ from deployment names; no real operator SSH configuration is used.
source_alias=fixture.Anchor
returning_aliases=(fixture.West fixture_east)
source_node=ledger-primary
returning_node=ledger-west
SOURCE_ALIAS="$source_alias"
ssh() { echo 'unexpected SSH in local incident test' >&2; return 99; }
export -f ssh
valid_source_location "$source_node" "/srv/dai/$source_node/inference" "/srv/dai/$source_node/inference"
valid_source_location "$returning_node" "/srv/dai/data/$returning_node/inference" "/srv/dai/data/$returning_node/inference"
valid_source_location "$returning_node" "/srv/dai/data/$returning_node/inference" "/srv/dai/data/$returning_node.generations/fixture-generation/inference"
! valid_source_location "$returning_node" "/srv/dai/data/$returning_node/inference" "/srv/dai/data/$source_node.generations/fixture-generation/inference"
! valid_source_location "$returning_node" "/srv/dai/data/$returning_node/inference" /tmp/inference
! valid_source_location "$returning_node" "/srv/dai/data/$returning_node/inference" "/srv/dai/data/$returning_node.generations/../inference"
printf 'PASS legacy and promoted JOIN data locations; unrelated links rejected\n'
valid_incident_binary source /root/.inference/cosmovisor/upgrades/v0.2.15/bin/inferenced
valid_incident_binary returning /root/.inference/cosmovisor/genesis/bin/inferenced
! valid_incident_binary source /root/.inference/cosmovisor/genesis/bin/inferenced
! valid_incident_binary returning /tmp/inferenced
printf 'PASS source upgrade binary and returning JOIN binary locations\n'

(
  RUN="$scratch/api-ready"; mkdir -p "$RUN"
  ssh() {
    local calls=0
    [[ ! -f "$RUN/calls" ]] || calls="$(<"$RUN/calls")"
    calls=$((calls+1)); printf '%s\n' "$calls" >"$RUN/calls"
    (( calls>2 )) || return 22
    printf '{"epoch_group_data":{"epoch_index":"8"}}\n'
  }
  sleep() { :; }
  query_epoch >"$RUN/result.json"
  [[ "$(<"$RUN/calls")" == 3 ]]
  jq -e '.epoch_group_data.epoch_index=="8"' "$RUN/result.json" >/dev/null
)
printf 'PASS read-only chain API readiness retries transient startup failures\n'

# Native governance must repair both root and model memberships, retaining
# only the source with its actual temporary consensus key during bootstrap.
jq -n '[{epoch_group_id:"8",validation_weights:[{member_address:"anchor",weight:"54"},{member_address:"lost",weight:"54"}]},
  {epoch_group_id:"9",validation_weights:[{member_address:"anchor",weight:"200"},{member_address:"lost",weight:"100"}]}]' >"$scratch/groups.json"
bootstrap_group_messages authority anchor temporary "$scratch/groups.json" >"$scratch/group-messages.json"
jq -e 'length==3 and .[0].group_id=="8" and .[1].group_id=="9"
  and all(.[0:2][]; .member_updates[0].metadata=="temporary" and (.member_updates[0].weight|tonumber)>0 and .member_updates[1].weight=="0")
  and .[2].metadata=="changed"' "$scratch/group-messages.json" >/dev/null
jq '.[1].validation_weights=[]' "$scratch/groups.json" >"$scratch/empty-groups.json"
if bootstrap_group_messages authority anchor temporary "$scratch/empty-groups.json" >"$scratch/group-error" 2>&1; then
  echo 'native bootstrap accepted an empty source model group' >&2; exit 1
fi
printf 'PASS native root/model group repair rejects an unusable backup\n'

(
  RUN="$scratch/native-voters"; mkdir -p "$RUN"
  printf '["returning-1","returning-2","returning-3"]\n' >"$RUN/returning-voters.json"
  native_tx() {
    printf '%s %s %s\n' "${native_from:?missing fixture voter}" "${native_wait:-true}" "$*" >>"$RUN/votes.log"
  }
  vote_native_handoff 42 "$RUN"
  [[ "$(wc -l <"$RUN/votes.log")" == 8 ]]
  awk 'NR<=4 {if ($2!="false") exit 1} NR>4 {if ($2!="true") exit 1}' "$RUN/votes.log"
  for name in recovery returning-1 returning-2 returning-3; do
    [[ "$(grep -c "^$name " "$RUN/votes.log")" == 2 ]]
  done
)
printf 'PASS native handoff broadcasts every restored account vote before waiting for committed receipts\n'

# Use separate Bash processes so a surrounding test condition cannot disable
# errexit inside the production functions under test.
for outcome in PROPOSAL_STATUS_PASSED PROPOSAL_STATUS_REJECTED; do
  result=0
  bash -c '
    source "$1"
    source_api() {
      case "$1" in
        /cosmos/gov/v1/params/deposit) printf "{\"params\":{\"min_deposit\":[{\"amount\":\"1\",\"denom\":\"ngonka\"}]}}\n" ;;
        /cosmos/gov/v1/proposals/42) jq -cn --arg state "$fixture_outcome" "{proposal:{status:\$state}}" ;;
        *) exit 99 ;;
      esac
    }
    native_tx() {
      printf "{\"events\":[{\"type\":\"submit_proposal\",\"attributes\":[{\"key\":\"proposal_id\",\"value\":\"42\"}]}]}\n" >"$1.committed"
    }
    vote_native_handoff() { [[ "$1" == 42 ]]; }
    fixture_outcome="$3"
    submit_native_governance "$2" "[]"
    printf "governance continued\n"
  ' bash "$RUNBOOK/scripts/recover-incident.sh" "$scratch/governance-$outcome" "$outcome" >"$scratch/governance-output" 2>&1 || result=$?
  if [[ "$outcome" == PROPOSAL_STATUS_PASSED ]]; then
    [[ "$result" == 0 ]]
    grep -Fxq 'governance continued' "$scratch/governance-output"
  else
    [[ "$result" == 3 ]]
    ! grep -Fq 'governance continued' "$scratch/governance-output"
  fi
done
printf 'PASS passed governance returns zero; rejected governance stops the command\n'

for outcome in complete resumed incomplete silent-error explicit-error; do
  result=0
  bash -c '
    source "$1"
    RUN="$2"; mkdir -p "$RUN"
    enroll_restored_hosts() { :; }
    finish_recovery() {
      case "$fixture_outcome" in
        complete) touch "$RUN/handoff.complete" ;;
        resumed) [[ -e "$RUN/handoff.complete" ]] ;;
        incomplete) : ;;
        silent-error) return 1 ;;
        explicit-error) fail "fixture failure" ;;
      esac
    }
    fixture_outcome="$3"
    if [[ "$fixture_outcome" == resumed ]]; then touch "$RUN/handoff.complete"; fi
    incident_main handoff fixture.Anchor --hosts fixture.West,fixture_east
  ' bash "$RUNBOOK/scripts/recover-incident.sh" "$scratch/end-$outcome" "$outcome" >"$scratch/end-output" 2>&1 || result=$?
  case "$outcome" in
    complete|resumed)
      [[ "$result" == 0 && "$(tail -n 1 "$scratch/end-output")" == 'END handoff SUCCESS' ]]
      [[ "$(grep -Fc 'END handoff SUCCESS' "$scratch/end-output")" == 1 ]]
      ! grep -Fq 'FAILED' "$scratch/end-output" ;;
    *)
      [[ "$result" != 0 ]]
      if [[ "$outcome" == silent-error ]]; then [[ "$result" == 1 ]]; else [[ "$result" == 3 ]]; fi
      grep -Fq "END handoff FAILED exit=$result" "$scratch/end-output"
      ! grep -Fq 'END handoff SUCCESS' "$scratch/end-output" ;;
  esac
done
printf 'PASS explicit handoff completion marker, incomplete refusal and preserved failure codes\n'

(
  RUN="$scratch/native-completed"; mkdir -p "$RUN/native-key-removal"
  touch "$RUN/native-key-removal/complete"
  native_source_handoff
)
printf 'PASS completed native handoff returns zero without repeating transactions\n'

(
  RUN="$scratch/gas-output"; mkdir -p "$RUN"
  export CLI=fixture_native_cli password=fixture key_home=fixture rpc_url=fixture
  native_wait=false
  fixture_native_cli() {
    cat >/dev/null
    printf 'gas estimate: 821770\n' >&2
    printf 'fixture diagnostic must remain visible\n' >&2
    printf '{"code":0,"txhash":"fixture"}\n'
  }
  native_tx "$RUN/receipt.json" gov vote 42 yes 2>"$RUN/stderr"
  wait
  ! grep -Fq 'gas estimate:' "$RUN/stderr"
  grep -Fxq 'fixture diagnostic must remain visible' "$RUN/stderr"
  jq -e '.code==0 and .txhash=="fixture"' "$RUN/receipt.json" >/dev/null
)
printf 'PASS gas estimates are hidden without losing CLI diagnostics or JSON receipts\n'

(
  proof="$scratch/poc-round"; mkdir -p "$proof"
  jq -cn '{commits:[{participant_address:"anchor",count:1},{participant_address:"west",count:2}]}' >"$proof/commits"
  jq -cn '{poc_validation:[{poc_validation:[{participant_address:"anchor",validated_weight:"1"},{participant_address:"west",validated_weight:"2"}]}]}' >"$proof/validations"
  jq -cn '{epoch_group_data:{validation_weights:[{member_address:"anchor",weight:"1"},{member_address:"west",weight:"2"}]}}' >"$proof/group"
  poc_round_complete '["anchor","west"]' "$proof/commits" "$proof/validations" "$proof/group" >/dev/null
  jq '.commits[1].count="0"' "$proof/commits" >"$proof/zero"
  ! poc_round_complete '["anchor","west"]' "$proof/zero" "$proof/validations" "$proof/group" >/dev/null
  jq '.poc_validation[0].poc_validation[1].validated_weight="0"' "$proof/validations" >"$proof/zero"
  ! poc_round_complete '["anchor","west"]' "$proof/commits" "$proof/zero" "$proof/group" >/dev/null
  jq '.epoch_group_data.validation_weights|=.[0:1]' "$proof/group" >"$proof/missing"
  ! poc_round_complete '["anchor","west"]' "$proof/commits" "$proof/validations" "$proof/missing" >/dev/null
  jq '.epoch_group_data.poc_start_block_height="42"' "$proof/group" >"$proof/bound-group"
  jq '.commits |= .[0:1]' "$proof/commits" >"$proof/source-commits"
  jq -cn '{snapshot:{episode_anchor_height:"42",model_preserved_nodes:[{participants:[{participant_id:"west",node_ids:["worker"]}]}]}}' >"$proof/preserved"
  poc_round_complete '["anchor","west"]' "$proof/source-commits" "$proof/validations" "$proof/bound-group" "$proof/preserved" >/dev/null
  jq '.snapshot.episode_anchor_height="41"' "$proof/preserved" >"$proof/stale"
  ! poc_round_complete '["anchor","west"]' "$proof/source-commits" "$proof/validations" "$proof/bound-group" "$proof/stale" >/dev/null
)
printf 'PASS final PoC acceptance requires every restored participant, not only the source\n'

(
  saved="$scratch/restart-native"; role=source
  mkdir -p "$saved/inference/config" "$saved/tmkms/state" "$saved/pre-fork-home"
  printf 'original Genesis\n' >"$saved/inference/config/genesis.json"
  printf 'original signer high-water mark\n' >"$saved/tmkms/state/priv_validator_state.json"
  printf 'previous branch\n' >"$saved/pre-fork-home/chain"
  touch "$saved/backup.complete" "$saved/boot.complete" "$saved/boot.started" "$saved/orphans.complete"
  jq -n --arg hash "$(sha "$saved/inference/config/genesis.json")" '{genesis_file_sha256:$hash,container:"old"}' >"$saved/context.json"
  before="$(sha "$saved/inference/config/genesis.json")/$(sha "$saved/tmkms/state/priv_validator_state.json")"
  compose() {
    case "$*" in
      '--profile signer ps --services --status running') printf 'node\napi\n' ;;
      'ps -q node') printf '%064d\n' 7 ;;
      *) exit 99 ;;
    esac
  }
  stop_deployment() { touch "$saved/fixture-stopped"; }
  restart_native_source
  [[ -e "$saved/native-prepared" && -e "$saved/fixture-stopped" && ! -e "$saved/boot.started" && ! -e "$saved/boot.complete" ]]
  [[ "$before" == "$(sha "$saved/inference/config/genesis.json")/$(sha "$saved/tmkms/state/priv_validator_state.json")" ]]
  retained=("$saved"/previous.*/pre-fork-home/chain)
  [[ ${#retained[@]} == 1 && "$(<"${retained[0]}")" == 'previous branch' ]]
  jq -e '.container|length==64' "$saved/context.json" >/dev/null
)
printf 'PASS native retry preserves original backup, signer state and prior branch\n'

(
  dapi="$scratch/poc-cache/api"; cache="$scratch/poc-cache/retained"
  mkdir -p "$dapi/data/poc-artifacts/999999"
  printf 'future branch artifact\n' >"$dapi/data/poc-artifacts/999999/proof"
  printf 'API database with unchanged keys and config\n' >"$dapi/gonka.db"
  printf 'warm key fixture\n' >"$dapi/key.fixture"
  before="$(sha "$dapi/gonka.db")/$(sha "$dapi/key.fixture")"
  sqlite3() {
    [[ "$1" == "$dapi/gonka.db" ]] || exit 99
    printf '%s\n' "$2" >>"$scratch/poc-sql.log"
    case "$2" in
      ".backup '$cache/gonka.db'") cp -p "$1" "$cache/gonka.db" ;;
      "SELECT count(*) FROM sqlite_master WHERE type='table' AND name="*) printf '1\n' ;;
      'DELETE FROM poc_early_checkpoints;'|'DELETE FROM poc_early_capture_runs;'|'DELETE FROM poc_early_guard_state;'|'DELETE FROM seed_info;') : ;;
      *) exit 99 ;;
    esac
  }
  archive_native_poc_cache "$dapi" "$cache"
  [[ -f "$cache/poc-artifacts/999999/proof" && ! -e "$dapi/data/poc-artifacts/999999" ]]
  cmp "$dapi/gonka.db" "$cache/gonka.db"
  printf 'current proof\n' >"$dapi/data/poc-artifacts/current"
  archive_native_poc_cache "$dapi" "$cache"
  [[ -f "$dapi/data/poc-artifacts/current" ]]
  [[ "$(grep -c '^.backup ' "$scratch/poc-sql.log")" == 1 ]]
  [[ "$(grep -c '^DELETE FROM ' "$scratch/poc-sql.log")" == 8 ]]
  [[ "$before" == "$(sha "$dapi/gonka.db")/$(sha "$dapi/key.fixture")" ]]
  saved="$scratch/poc-marker"; mkdir -p "$saved"; touch "$saved/poc-cache.complete"
  compose() { echo 'completed cache reset must not stop API again' >&2; exit 99; }
  reset_native_poc_cache
)
printf 'PASS rollback PoC cache preservation, restricted table cleanup and idempotent resume (SQLite mocked)\n'

(
  saved="$scratch/poc-after-reset"; node="$returning_node"
  mkdir -p "$saved"
  compose() {
    case "$*" in
      'ps -a -q api') : ;;
      '--profile * config --format json')
        jq -cn --arg path "/srv/dai/data/$node/dapi" \
          '{services:{api:{volumes:[{type:"bind",source:$path,target:"/root/.dapi"}]}}}' ;;
      *) echo "unexpected container operation: $*" >&2; exit 99 ;;
    esac
  }
  archive_native_poc_cache() {
    [[ "$1" == "/srv/dai/data/$node/dapi" && "$2" == "$saved/poc-before-native" ]] || exit 99
    touch "$saved/cache-preserved.fixture"
  }
  reset_native_poc_cache
  [[ -f "$saved/poc-cache.complete" && -f "$saved/cache-preserved.fixture" ]]
)
printf 'PASS returning Host cache discovery after reset removes the API container (Compose mocked)\n'

(
  saved="$scratch/previous-recipe"
  generation=20260101T120000Z-42
  mkdir -p "$saved" "$saved.previous-$generation"
  printf 'retained pinned auxiliary recipe\n' >"$saved.previous-$generation/orphans.compose.json"
  restore_previous_orphan_recipe "$generation"
  cmp "$saved/orphans.compose.json" "$saved.previous-$generation/orphans.compose.json"
  printf 'current recipe must remain unchanged\n' >"$saved/orphans.compose.json"
  restore_previous_orphan_recipe "$generation"
  [[ "$(<"$saved/orphans.compose.json")" == 'current recipe must remain unchanged' ]]
  if (restore_previous_orphan_recipe ../unsafe) >"$scratch/recipe-error" 2>&1; then
    echo 'invalid recipe generation accepted' >&2; exit 1
  fi
)
printf 'PASS retained auxiliary recipe survives a new recovery generation without overwriting current work\n'

# Reproduce a previously imported node with the redirecting RPC URL. The
# production resume path must repair only config and restart, preserving data.
(
  source="$scratch/rpc-resume"
  mkdir -p "$source/config" "$source/data"
  config="$source/config/config.toml"
  hash="$(printf '%064d' 42)"
  printf '[statesync]\nenable = true\nrpc_servers = "https://source.example.test/chain-rpc,https://source.example.test/chain-rpc"\ntrust_height = 306582\ntrust_hash = "%s"\ntrust_period = "24h0m0s"\n[p2p]\npex = false\n' "$hash" >"$config"
  printf 'retained key\n' >"$source/config/priv_validator_key.json"
  printf 'retained state\n' >"$source/data/priv_validator_state.json"
  printf 'partial chain\n' >"$source/data/chain.fixture"
  before="$(sha256sum "$source/config/priv_validator_key.json" "$source/data/priv_validator_state.json" "$source/data/chain.fixture")"
  curl() {
    [[ "$*" == *'--data '* && "$*" != *'--location'* && "$*" != *' -L '* ]] || exit 99
    if [[ "${*: -1}" != https://source.example.test/chain-rpc/ ]]; then
      printf '<html>301 redirect to HTTP</html>\n'; return
    fi
    jq -cn --arg hash "${fixture_hash:-$hash}" \
      '{result:{signed_header:{header:{height:"306582"},commit:{block_id:{hash:$hash}}}}}'
  }
  if (check_statesync_rpc https://source.example.test/chain-rpc 306582 "$hash") >"$scratch/rpc-redirect.log" 2>&1; then
    echo 'redirecting JSON-RPC was accepted' >&2; exit 1
  fi
  if (fixture_hash=wrong; check_statesync_rpc https://source.example.test/chain-rpc/ 306582 "$hash") >"$scratch/rpc-hash.log" 2>&1; then
    echo 'wrong JSON-RPC trust hash was accepted' >&2; exit 1
  fi
  check_statesync_rpc https://source.example.test/chain-rpc/ 306582 "$hash"
  recovered_compose() {
    printf '%s\n' "$*" >>"$scratch/rpc-compose.log"
    case "$*" in
      'stop node') grep -Fq 'https://source.example.test/chain-rpc,' "$config" ;;
      'up -d --no-deps --pull never node') grep -Fxq 'rpc_servers = "https://source.example.test/chain-rpc/,https://source.example.test/chain-rpc/"' "$config" ;;
      *) exit 99 ;;
    esac
  }
  resume_native_sync https://source.example.test/chain-rpc/ 306582 "$hash"
  resume_native_sync https://source.example.test/chain-rpc/ 306582 "$hash"
  [[ "$(grep -c '^stop node$' "$scratch/rpc-compose.log")" == 1 ]]
  [[ "$before" == "$(sha256sum "$source/config/priv_validator_key.json" "$source/data/priv_validator_state.json" "$source/data/chain.fixture")" ]]
  grep -Fxq 'pex = false' "$config"
)
printf 'PASS JSON-RPC POST and legacy endpoint repair without resetting state or keys (mock transport)\n'
jq -cn '{height:"0",round:"0",step:0,block_id:{hash:"",part_set_header:{total:0,hash:""}}}' >"$scratch/initial.json"
validate_tmkms_state "$scratch/initial.json"
jq '.height = "1"' "$scratch/initial.json" >"$scratch/invalid.json"
if (validate_tmkms_state "$scratch/invalid.json") >"$scratch/invalid.log" 2>&1; then
  echo 'archive validator accepted an empty block at a nonzero height' >&2; exit 1
fi

# Exercise the production archive-binding path with read-only SSH replaced by
# a Genesis fixture. The archive verifier's expected identity must remain the
# canonical value even when the deployed JSON has a different byte checksum.
(
  RUN="$scratch/genesis-check"
  mkdir -p "$RUN/hosts"
  printf '%s\n' '{"chain_id":"gonka-devnet-community","initial_height":"1","app_hash":"","consensus_params":{},"app_state":{"value":1}}' >"$RUN/canonical.json"
  expected_identity="$(genesis_sha256 "$RUN/canonical.json")"
  ssh() { [[ "${*: -2:1}" == "$source_alias" ]] || exit 99; cat "$RUN/deployed.json"; }
  verify_backup_archive() {
    [[ "$1" == fixture.tar && "$2" == "$source_node" && "$3" == "$CHAIN" && "$4" == "$expected_identity" ]] \
      || fail 'archive Genesis identity mismatch'
  }
  inspect_fixture() {
    jq -cn --arg raw "$(sha "$RUN/deployed.json")" --arg source "/srv/dai/$source_node/inference" --arg node "$source_node" \
      '{node_name:$node,source:$source,genesis_file_sha256:$raw}' >"$(host_context "$source_alias")"
  }
  jq '.initial_height = 1 | .app_hash = null | .consensus = {params:.consensus_params}
      | del(.consensus_params) | .app_name = "inferenced" | .app_version = "0.2.15"' \
    "$RUN/canonical.json" >"$RUN/deployed.json"
  inspect_fixture
  [[ "$(sha "$RUN/deployed.json")" != "$expected_identity" ]]
  verify_incident_archive "$source_alias" fixture.tar
  [[ "$(jq -r .genesis_sha256 "$(host_context "$source_alias")")" == "$expected_identity" ]]
  [[ "$(jq -r .genesis_file_sha256 "$(host_context "$source_alias")")" == "$(sha "$RUN/deployed.json")" ]]
  for change in '.chain_id = "other-chain"' '.app_state.value = 2'; do
    jq "$change" "$RUN/canonical.json" >"$RUN/deployed.json"
    inspect_fixture
    if (verify_incident_archive "$source_alias" fixture.tar) >"$RUN/error" 2>&1; then
      echo 'accepted a different Genesis identity' >&2; exit 1
    fi
    grep -Fq 'archive Genesis identity mismatch' "$RUN/error"
  done
  cp "$RUN/canonical.json" "$RUN/deployed.json"
  if (verify_incident_archive "$source_alias" fixture.tar) >"$RUN/error" 2>&1; then
    echo 'accepted a Genesis file changed after inspection' >&2; exit 1
  fi
  grep -Fq 'Genesis file changed since inspection' "$RUN/error"
)
printf 'PASS incident canonical Genesis binding and raw file integrity\n'

# Unit evidence, not a live recovery rehearsal: a real committed quorum must
# replace the temporary signer, rather than a container-count assumption.
keys='["returning-a","returning-b"]'
commit='{"result":{"canonical":true,"signed_header":{"header":{"height":"306600"},"commit":{"signatures":[{"block_id_flag":2,"validator_address":"AA"},{"block_id_flag":2,"validator_address":"bb"}]}}}}'
validators='{"result":{"block_height":"306600","total":"3","validators":[{"address":"aa","pub_key":{"value":"returning-a"},"voting_power":"60"},{"address":"BB","pub_key":{"value":"returning-b"},"voting_power":"10"},{"address":"CC","pub_key":{"value":"temporary"},"voting_power":"30"}]}}'
returning_quorum "$keys" "$commit" "$validators"
! returning_quorum '["returning-b"]' "$commit" "$validators"
! returning_quorum "$keys" "$(jq '.result.signed_header.commit.signatures[0].block_id_flag = 1' <<<"$commit")" "$validators"
! returning_quorum "$keys" "$commit" "$(jq '.result.total = "4"' <<<"$validators")"
! returning_quorum "$keys" "$commit" "$(jq '.result.block_height = "306599"' <<<"$validators")"
! returning_quorum "$keys" "$commit" "$(jq '.result.validators[0].voting_power = "50"' <<<"$validators")"
printf 'PASS weighted, committed, common-height returning quorum\n'

# Closed RPC fixtures reproduce an incomplete SeenCommit, a canonical block
# with a missed vote, then a sufficient canonical quorum. No real waiting or
# transport is used; the production timeout is exercised with a mock clock.
for outcome in retry missing noncanonical wrong-height wrong-set rpc-error; do
(
  fixture_quorum_commit="$commit"; fixture_quorum_validators="$validators"
  tick=0
  status() {
    [[ "$1" == "$source_alias" ]] || return 99
    jq -cn --arg height "$((306601+tick))" '{result:{sync_info:{latest_block_height:$height}}}'
  }
  sleep() { tick=$((tick+1)); SECONDS=$((SECONDS+60)); }
  ssh() {
    local request="${*: -1}" height="$((306600+tick))"
    [[ "${*: -2:1}" == "$source_alias" ]] || return 99
    [[ "$outcome" != rpc-error ]] || return 22
    case "$request" in
      *"/commit?height=$height"*)
        jq --arg height "$height" --arg outcome "$outcome" --argjson tick "$tick" '
          .result.signed_header.header.height=$height
          | if $outcome=="noncanonical" or ($outcome=="retry" and $tick==0) then .result.canonical=false else . end
          | if $outcome=="missing" or ($outcome=="retry" and $tick==1)
            then .result.signed_header.commit.signatures[0].block_id_flag=3 else . end
          | if $outcome=="wrong-height" then .result.signed_header.header.height="306599" else . end' <<<"$fixture_quorum_commit" ;;
      *"/validators?height=$height&per_page=100"*)
        jq --arg height "$height" --arg outcome "$outcome" '
          .result.block_height=(if $outcome=="wrong-set" then "306599" else $height end)' <<<"$fixture_quorum_validators" ;;
      *) printf 'unexpected quorum RPC: %s\n' "$request" >&2; return 99 ;;
    esac
  }
  rc=0
  wait_returning_quorum "$keys" >"$scratch/quorum-$outcome.json" 2>"$scratch/quorum-$outcome.log" || rc=$?
  case "$outcome" in
    retry)
      [[ "$rc" == 0 && "$tick" == 2 ]]
      jq -e '.result.canonical==true and .result.signed_header.header.height=="306602"' "$scratch/quorum-$outcome.json" >/dev/null ;;
    rpc-error) [[ "$rc" == 22 && "$tick" == 0 && ! -s "$scratch/quorum-$outcome.json" ]] ;;
    *) [[ "$rc" == 1 && "$tick" == 3 && ! -s "$scratch/quorum-$outcome.json" ]] ;;
  esac
)
done
printf 'PASS canonical quorum retries, bounded timeout, same-height binding and RPC failure propagation\n'

# The real native handoff must not submit the key change or activate a signer
# before that wait succeeds. Resume from the prepared stage with fake keys.
for outcome in ready missing; do
  rc=0
  (
    fixture_quorum_commit="$commit"; fixture_quorum_validators="$validators"
    RUN="$scratch/quorum-gate-$outcome"
    mkdir -p "$RUN/native-key-removal" "$RUN/$source_alias-backup"
    touch "$RUN/native-key-removal/prepared"
    printf '{"participant_address":"fixture-account"}\n' >"$RUN/$source_alias-backup/manifest.json"
    printf '{"consensus_pubkey":"original-source"}\n' >"$RUN/$source_alias-backup/identity.json"
    printf '%s\n' "$keys" >"$RUN/expected-returning.json"
    valoper=fixture-operator
    saved_path() { printf '/fixture\n'; }
    prepare_returning_governance_keys() { :; }
    source_api() { printf '{"account":{"base_account":{"address":"fixture-gov"}}}\n'; }
    status() { printf '{"result":{"sync_info":{"latest_block_height":"306601"}}}\n'; }
    sleep() { SECONDS=$((SECONDS+180)); }
    ssh() {
      case "$*" in
        *transition-key.public*) printf 'temporary\n' ;;
        *'/commit?height=306600'*)
          jq --arg outcome "$outcome" 'if $outcome=="missing" then .result.signed_header.commit.signatures[0].block_id_flag=1 else . end' <<<"$fixture_quorum_commit" ;;
        *validators\?*) printf '%s\n' "$fixture_quorum_validators" ;;
        -fNT*|-S*) : ;;
        *) return 99 ;;
      esac
    }
    native_tx() {
      [[ "$*" == *'inference submit-new-participant'* ]] || exit 99
      jq -e '.result.canonical==true' "$RUN/native-key-removal/returning-quorum.json" >/dev/null || exit 99
      touch "$RUN/key-change-reached"
      exit 77
    }
    remote() { echo 'unexpected signer mutation in local test' >&2; exit 99; }
    native_source_handoff
  ) >"$scratch/quorum-gate-$outcome.log" 2>&1 || rc=$?
  if [[ "$outcome" == ready ]]; then
    [[ "$rc" == 77 && -e "$scratch/quorum-gate-$outcome/key-change-reached" ]]
  else
    [[ "$rc" == 3 && ! -e "$scratch/quorum-gate-$outcome/key-change-reached" ]]
    grep -Fq 'canonical returning quorum not confirmed' "$scratch/quorum-gate-$outcome.log"
  fi
done
printf 'PASS native key change is gated by retained canonical quorum evidence\n'

# Discover deployment identity from Docker metadata, never from the SSH alias.
(
  docker() {
    case "$1" in
      ps) printf '%064d\n' 1 ;;
      inspect)
        jq -cn --arg node "$source_node" --argjson count "${fixture_count:-1}" \
          '[range($count) | {Id:"fixture-container",State:{Running:true},Config:{Labels:{"com.docker.compose.project.working_dir":("/srv/dai/deploy/" + $node)}}}]' ;;
      *) exit 99 ;;
    esac
  }
  [[ "$(discover_deployment | jq -r .deploy)" == "/srv/dai/deploy/$source_node" ]]
  if (fixture_count=2; discover_deployment) >"$scratch/discovery-error" 2>&1; then
    echo 'ambiguous deployment discovery succeeded' >&2; exit 1
  fi
)
printf 'PASS discovered deployment name independent of operator alias\n'

# Reproduce the stopped node plus still-running orphan container locally.
(
  saved="$scratch/interrupted-backup"; source="$scratch/source"
  mkdir -p "$saved" "$source/config"
  printf '{}\n' >"$source/config/genesis.json"
  node_id="$(printf '%064d' 1)"; orphan_id="$(printf '%064d' 2)"
  unrelated_id="$(printf '%064d' 3)"
  jq -cn --arg id "$node_id" --arg hash "$(sha "$source/config/genesis.json")" \
    '{container:$id,genesis_file_sha256:$hash}' >"$saved/context.json"
  touch "$saved/backup.started"
  printf 'node\napi\nlegacy-worker\n' >"$saved/services.running"
  jq -cn --arg node "$node_id" --arg orphan "$orphan_id" --arg unrelated "$unrelated_id" \
    '[{Id:$node,State:{Running:false},Config:{Labels:{"com.docker.compose.service":"node"}}},
      {Id:$orphan,State:{Running:true},Config:{Labels:{"com.docker.compose.service":"legacy-worker"}}},
      {Id:$unrelated,State:{Running:true},Config:{Labels:{"com.docker.compose.service":"other-project"}}}]' >"$saved/docker.json"
  compose() {
    case "$*" in
      'ps -a -q') printf '%s\n' "$node_id" "$orphan_id" ;;
      '--profile * config --services') printf 'node\ntmkms\napi\n' ;;
      *) exit 99 ;;
    esac
  }
  docker() {
    local command="$1"; shift
    case "$command" in
      inspect) jq --args '[.[] | select(.Id as $id | $ARGS.positional | index($id))]' "$@" <"$saved/docker.json" ;;
      update) [[ "$*" == "--restart=no $node_id $orphan_id" ]] || exit 99 ;;
      stop)
        [[ "$*" == "--time 30 $node_id $orphan_id" ]] || exit 99
        jq --arg other "$unrelated_id" 'map(if .Id != $other then .State.Running = false else . end)' "$saved/docker.json" >"$saved/docker.next"
        mv "$saved/docker.next" "$saved/docker.json" ;;
      *) exit 99 ;;
    esac
  }
  check_backup_resume
  for member in inference tmkms deploy backup.complete boot.started reset.started; do
    touch "$saved/$member"
    if (check_backup_resume) >"$scratch/resume-error" 2>&1; then
      echo "resume accepted advanced stage: $member" >&2; exit 1
    fi
    mv "$saved/$member" "$saved/test-$member"
  done
  stop_deployment
  [[ "$(<"$saved/orphans.running")" == "$orphan_id" ]]
  jq -e --arg other "$unrelated_id" 'all(.[]; .State.Running == (.Id == $other))' "$saved/docker.json" >/dev/null
  [[ "$(<"$saved/services.running")" == $'node\napi\nlegacy-worker' ]]
  jq --arg id "$node_id" 'map(if .Id == $id then .State.Running = true else . end)' "$saved/docker.json" >"$saved/docker.next"
  mv "$saved/docker.next" "$saved/docker.json"
  if (check_backup_resume) >"$scratch/resume-error" 2>&1; then
    echo 'resume accepted a restarted source container' >&2; exit 1
  fi
)
printf 'PASS interrupted stop resume, orphan stop and unrelated-project isolation (mock only)\n'

# Resume after state sync and signer activation, with a failure partway through
# auxiliary-service recreation. Old IDs disappear, but the retained recipe must
# allow a retry without stopping the node or reading the old signer checkpoint.
(
  saved="$scratch/service-resume"; deploy="$scratch/service-deploy"
  mkdir -p "$saved" "$deploy"
  touch "$deploy/.env" "$saved/enable.started" "$saved/import.complete"
  printf 'advanced signer state\n' >"$saved/signer-state.fixture"
  before="$(sha "$saved/signer-state.fixture")"
  orphan_id="$(printf '%064d' 7)"
  printf '%s\n' "$orphan_id" >"$saved/orphans.running"
  jq -cn '{name:"fixture-services",services:{node:{image:"fixture"},tmkms:{image:"fixture"}}}' >"$deploy/compose.yaml"
  jq -cn '{services:{worker:{image:"fixture:mutable",depends_on:{node:{condition:"service_started"}},
    volumes:["./data:/data"]}},networks:{default:{name:"fixture-current-network"}}}' >"$deploy/compose.worker.yaml"
  recovered_compose() { [[ "$*" == '--profile signer ps -q node tmkms' ]] || exit 99; printf 'node-fixture\nsigner-fixture\n'; }
  docker() {
    case "$1" in
      inspect)
        if [[ "$2" == "$orphan_id" ]]; then
          [[ ! -e "$saved/replaced" ]] || exit 99
          jq -cn --arg deploy "$deploy" --arg image "sha256:$(printf '%064d' 8)" \
            '[{Image:$image,Config:{Labels:{"com.docker.compose.project":"fixture-services",
              "com.docker.compose.project.working_dir":$deploy,"com.docker.compose.service":"worker",
              "com.docker.compose.project.config_files":($deploy + "/compose.yaml," + $deploy + "/compose.worker.yaml")}}}]'
        else
          [[ "$*" == 'inspect node-fixture signer-fixture' ]] || exit 99
          jq -cn --arg listener "${fixture_listener:-tcp://0.0.0.0:26658}" \
            '[{State:{Running:true},Config:{Labels:{"com.docker.compose.service":"node"},Cmd:["start","--priv_validator_laddr",$listener]}},
              {State:{Running:true},Config:{Labels:{"com.docker.compose.service":"tmkms"}}}]'
        fi ;;
      compose)
        if [[ " $* " == *' up '* ]]; then
          [[ "${*: -5}" == 'up -d --pull never --force-recreate' ]] || exit 99
          command docker compose -f "$saved/orphans.compose.json" config --quiet
          jq -e '.services | keys == ["worker"]' "$saved/orphans.compose.json" >/dev/null
          jq -e --arg image "sha256:$(printf '%064d' 8)" '.services.worker.image == $image
            and .services.worker.depends_on == {}' "$saved/orphans.compose.json" >/dev/null
          touch "$saved/replaced"
          [[ -e "$saved/allow-retry" ]] || return 73
        else command docker "$@"; fi ;;
      *) exit 99 ;;
    esac
  }
  start_services() { start_orphans; }
  if (fixture_listener=wrong; resume_enabled_services) >"$scratch/wrong-listener.log" 2>&1; then
    echo 'resume accepted a node without the active external signer' >&2; exit 1
  fi
  if (resume_enabled_services) >"$scratch/partial-services.log" 2>&1; then
    echo 'resume ignored failed auxiliary startup' >&2; exit 1
  fi
  [[ -e "$saved/replaced" && ! -e "$saved/enable.complete" && ! -e "$saved/orphans.complete" ]]
  touch "$saved/allow-retry"
  resume_enabled_services
  resume_enabled_services
  [[ -e "$saved/enable.complete" && -e "$saved/orphans.complete" ]]
  [[ "$(sha "$saved/signer-state.fixture")" == "$before" ]]
)
printf 'PASS service-only continuation, pinned auxiliary recipe and retry after old IDs disappear (mock Docker startup)\n'

(
  saved="$scratch/dns-boot"; source="$scratch/dns-source"; export role=source
  mkdir -p "$saved/working/config" "$saved/inference/config" "$saved/new-key" "$source/config"
  printf '[p2p]\nexternal_address = "validator.example.invalid:26656"\npersistent_peers = ""\nseeds = ""\npex = true\n' >"$saved/inference/config/config.toml"
  cp "$saved/inference/config/config.toml" "$saved/working/config/config.toml"
  isolate_testnet_config "$saved/working/config/config.toml"
  grep -Fxq 'external_address = ""' "$saved/working/config/config.toml"
  restore_external_address "$saved/inference/config/config.toml" "$saved/working/config/config.toml"
  grep -Fxq 'external_address = "validator.example.invalid:26656"' "$saved/working/config/config.toml"
  printf '{}\n' >"$source/config/genesis.json"
  cp "$source/config/genesis.json" "$saved/inference/config/genesis.json"
  jq -cn --arg hash "$(sha "$source/config/genesis.json")" '{container:"original-container",genesis_file_sha256:$hash}' >"$saved/context.json"
  touch "$saved/backup.complete" "$saved/boot.started"
  printf 'failed modified database\n' >"$saved/working/modified-data"
  printf 'temporary key fixture\n' >"$saved/new-key/key"
  docker() {
    case "$*" in
      'inspect gdc-incident-transition')
        jq -cn --arg path "$saved/working" --arg network "${mock_network:-none}" --arg status "${mock_status:-exited}" \
          '[{State:{Status:$status,ExitCode:1},HostConfig:{NetworkMode:$network},Config:{Cmd:["in-place-testnet"]},
            Mounts:[{Type:"bind",Source:$path,Destination:"/root/.inference"}]}]' ;;
      'inspect original-container') printf '[{"State":{"Running":false}}]\n' ;;
      'logs gdc-incident-transition') printf '%s\n' "${mock_error:-error looking up host (validator.example.invalid): network is unreachable}" ;;
      'rm gdc-incident-transition') touch "$saved/container-removed" ;;
      *) exit 99 ;;
    esac
  }
  check_dns_boot_retry
  for defect in promoted online running other-error; do
    if (
      case "$defect" in
        promoted) touch "$saved/boot.complete" ;;
        online) mock_network=bridge ;;
        running) mock_status=running ;;
        other-error) mock_error='unrelated startup error' ;;
      esac
      check_dns_boot_retry
    ) >"$scratch/dns-rejection" 2>&1; then
      echo "DNS retry accepted $defect" >&2; exit 1
    fi
    [[ ! -e "$saved/boot.complete" ]] || mv "$saved/boot.complete" "$saved/test-boot.complete"
  done
  archive_dns_boot
  [[ -f "$saved/container-removed" && ! -e "$saved/working" && ! -e "$saved/boot.started" ]]
  failed=("$saved"/failed-dns.*)
  [[ ${#failed[@]} == 1 && -f "${failed[0]}/working/modified-data" && -f "${failed[0]}/new-key/key" \
    && -f "${failed[0]}/boot.started" && -f "${failed[0]}/container.log" && -f "${failed[0]}/container.json" ]]
  cmp "$source/config/genesis.json" "$saved/inference/config/genesis.json"
)
printf 'PASS isolated DNS configuration and preservation of failed boot; unsafe retries refused (mock only)\n'

(
  saved="$scratch/genesis-resume"; source="$scratch/genesis-original"; export role=source
  mkdir -p "$saved/inference/config" "$saved/working/config" "$saved/new-key/config" "$source/config"
  printf '{ "chain_id": "fixture", "app_state": {} }\n' >"$source/config/genesis.json"
  cp "$source/config/genesis.json" "$saved/inference/config/genesis.json"
  jq -cS . "$source/config/genesis.json" >"$saved/working/config/genesis.json"
  printf '{"pub_key":{"value":"fixture-key"}}\n' >"$saved/new-key/config/priv_validator_key.json"
  cp "$saved/new-key/config/priv_validator_key.json" "$saved/working/config/priv_validator_key.json"
  expected="$(sha "$source/config/genesis.json")"
  jq -cn --arg hash "$expected" '{container:"original-container",genesis_file_sha256:$hash}' >"$saved/context.json"
  touch "$saved/backup.complete" "$saved/boot.started"
  docker() {
    case "$1" in
      ps) : ;;
      inspect) printf '[{"State":{"Running":false}}]\n' ;;
      *) exit 99 ;;
    esac
  }
  check_genesis_resume
  restore_genesis_bytes "$saved/inference/config/genesis.json" "$saved/working/config/genesis.json" "$expected"
  cmp "$source/config/genesis.json" "$saved/working/config/genesis.json"
  [[ -f "$saved/working/config/genesis.json.before-restore" ]]
  printf '{"chain_id":"different"}\n' >"$saved/working/config/genesis.json"
  if (restore_genesis_bytes "$saved/inference/config/genesis.json" "$saved/working/config/genesis.json" "$expected") >"$scratch/genesis-error" 2>&1; then
    echo 'accepted changed Genesis content' >&2; exit 1
  fi
  grep -Fq 'different' "$saved/working/config/genesis.json"
)
printf 'PASS equivalent Genesis byte restoration; changed content refused without overwrite\n'

# Real Compose config, no daemon or containers: reproduce a rendered project
# whose optional dependency references an omitted service. Mandatory missing
# dependencies must still fail without replacing the deployed configuration.
(
  deploy="$scratch/compose-deploy"; saved="$scratch/compose-recovery"
  source="$scratch/promoted-source"; export role=source
  export image
  image="sha256:$(printf '%064d' 1)"
  binary=/root/.inference/cosmovisor/upgrades/v0.2.15/bin/inferenced
  mkdir -p "$deploy" "$saved/pre-fork-home/config" "$saved/inference/config" \
    "$saved/new-key/config" "$source/config" "$(dirname "$source/${binary#/root/.inference/}")"
  touch "$deploy/.env" "$saved/backup.complete" "$saved/boot.started"
  printf 'fixture binary\n' >"$source/${binary#/root/.inference/}"
  printf '{"chain_id":"fixture"}\n' >"$source/config/genesis.json"
  cp "$source/config/genesis.json" "$saved/pre-fork-home/config/genesis.json"
  cp "$source/config/genesis.json" "$saved/inference/config/genesis.json"
  jq -cn --arg hash "$(sha "$source/config/genesis.json")" --arg binary_hash "$(sha "$source/${binary#/root/.inference/}")" \
    '{container:"original-container",genesis_file_sha256:$hash,binary_sha256:$binary_hash}' >"$saved/context.json"
  printf '{"pub_key":{"value":"fixture-key"}}\n' >"$saved/new-key/config/priv_validator_key.json"
  cp "$saved/new-key/config/priv_validator_key.json" "$source/config/priv_validator_key.json"
  source_override "$(($(date +%s) + 86400))" >"$saved/override.json"
  jq -cn '{name:"fixture-recovery",services:{node:{image:"fixture",depends_on:{tmkms:{condition:"service_started",required:true}}},
    tmkms:{image:"fixture"},proxy:{image:"fixture",depends_on:{node:{condition:"service_started",required:true},
      omitted:{condition:"service_started",required:false},existing:{condition:"service_started",required:false}}},
    existing:{image:"fixture",profiles:["optional"]}}}' >"$deploy/compose.yaml"
  if command docker compose -f "$deploy/compose.yaml" --profile '*' config --quiet >"$scratch/compose-error" 2>&1; then
    echo 'fixture did not reproduce the dangling Compose dependency' >&2; exit 1
  fi
  grep -Fq 'undefined service "omitted"' "$scratch/compose-error"
  docker() {
    case "$1" in
      ps) : ;;
      inspect) printf '[{"State":{"Running":false}}]\n' ;;
      compose)
        if [[ " $* " == *' up '* ]]; then
          [[ "${*: -7}" == 'up -d --no-deps --pull never --force-recreate node' ]] || exit 99
          printf 'node\n' >>"$saved/started"
        else command docker "$@"; fi ;;
      *) echo "unexpected mutation: $*" >&2; exit 99 ;;
    esac
  }
  check_promoted_resume
  cp "$source/config/priv_validator_key.json" "$scratch/saved-fixture-key.json"
  printf '{}\n' >"$source/config/priv_validator_key.json"
  if (check_promoted_resume) >"$scratch/promoted-error" 2>&1; then
    echo 'accepted a different promoted signer' >&2; exit 1
  fi
  cp "$scratch/saved-fixture-key.json" "$source/config/priv_validator_key.json"
  start_promoted_source
  [[ -f "$saved/boot.complete" && "$(<"$saved/started")" == node && "$(<"$saved/transition-key.public")" == fixture-key ]]
  cmp "$source/config/genesis.json" "$saved/pre-fork-home/config/genesis.json"
  jq -e '.services.proxy.depends_on | has("omitted") | not' "$deploy/compose.yaml" >/dev/null
  jq -e '.services.proxy.depends_on.existing.required == false and .services.node.depends_on.tmkms.required == true
    and .services.existing.profiles == ["optional"] and .services.node.command[0] == "start"' "$deploy/compose.yaml" >/dev/null
  command docker compose -f "$deploy/compose.yaml" --profile '*' config --quiet
  if (check_promoted_resume) >"$scratch/promoted-error" 2>&1; then
    echo 'accepted an already completed startup' >&2; exit 1
  fi
  jq '.services.proxy.depends_on.missing = {condition:"service_started",required:true}' "$deploy/compose.yaml" >"$deploy/broken.json"
  mv "$deploy/broken.json" "$deploy/compose.yaml"
  before="$(sha "$deploy/compose.yaml")"
  if (persist_compose) >"$scratch/compose-required-error" 2>&1; then
    echo 'removed a required dependency to pass Compose validation' >&2; exit 1
  fi
  [[ "$(sha "$deploy/compose.yaml")" == "$before" ]]
)
printf 'PASS real Compose optional-dependency repair and promoted startup without re-forking (startup mocked)\n'

(
  RUN="$scratch/transport"
  mkdir -p "$RUN/hosts"
  jq -cn --arg node "$returning_node" '{node_name:$node}' >"$(host_context "${returning_aliases[0]}")"
  ssh() {
    jq -cn --arg alias "${*: -2:1}" --arg command "${*: -1}" '{alias:$alias,command:$command}' >"$RUN/call.json"
    cat >/dev/null
  }
  remote inspect "$source_alias"
  jq -e --arg alias "$source_alias" '.alias == $alias and (.command | contains("inspect\u0027 \u0027discover\u0027 \u0027source"))' "$RUN/call.json" >/dev/null
  remote reset "${returning_aliases[0]}"
  jq -e --arg alias "${returning_aliases[0]}" --arg node "$returning_node" \
    '.alias == $alias and (.command | contains("reset\u0027 \u0027" + $node + "\u0027 \u0027returning"))' "$RUN/call.json" >/dev/null
)
printf 'PASS SSH transport targets the supplied alias and sends the discovered deployment identity\n'

# Controller flow uses the production recover/reset/join functions. Only the
# remote boundary, cryptographic preparation and human prompt are mocked.
for resume_fixture in backup dns-boot genesis promoted running; do
(
  GDC_DATA_ROOT="$scratch/flow-$resume_fixture"
  mkdir -p "$GDC_DATA_ROOT"
  RUN="$GDC_DATA_ROOT/recovery-$INCIDENT"
  flow_log="$scratch/flow-$resume_fixture.log"
  fixture_commit="$commit"; fixture_validators="$validators"
  active_alias=''
  record() { printf '%s %s\n' "$1" "$2" >>"$flow_log"; }
  check_target() { [[ "$1" == "$source_alias" || "$1" == "$active_alias" ]] || exit 99; }
  inspect_host() {
    local alias="$1" node key
    check_target "$alias"; record inspect "$alias"
    case "$alias" in
      "$source_alias") node="$source_node"; key='original-source' ;;
      "${returning_aliases[0]}") node="$returning_node"; key=returning-a ;;
      "${returning_aliases[1]}") node=ledger-east; key=returning-b ;;
      *) exit 99 ;;
    esac
    mkdir -p "$RUN/hosts" "$RUN/$alias-backup"
    jq -cn --arg node "$node" '{node_name:$node,public_host:"restore.example.test"}' >"$(host_context "$alias")"
    jq -cn --arg key "$key" '{consensus_pubkey:$key}' >"$RUN/$alias-backup/identity.json"
    printf 'mock archive for %s\n' "$node" >"$GDC_DATA_ROOT/$node-validator-backup.tar"
    sha "$GDC_DATA_ROOT/$node-validator-backup.tar" >"$RUN/$alias-archive.sha256"
  }
  backup_host() {
    check_target "$1"; record "${2:-backup}" "$1"
    [[ "$resume_fixture" != backup || ! -f "$scratch/fail-backup" ]] || fail 'mock interrupted stop'
  }
  prepare_governance_key() { export valoper=fixture-valoper; mkdir -p "$RUN/governance-keyring"; }
  record_returning_archives() { printf '["returning-a","returning-b"]\n' >"$RUN/expected-returning.json"; }
  wait_native_epochs() { record "epochs-$1" "$SOURCE_ALIAS"; }
  confirm_recovery() { record confirm "$SOURCE_ALIAS"; }
  remote() {
    check_target "$2"; record "$1" "$2"
    if [[ "$1" == check-source-resume ]]; then
      if [[ -e "$RUN/ready" ]]; then printf 'running\n'; else printf '%s\n' "$resume_fixture"; fi
    fi
    [[ "$1" != boot || "$resume_fixture" == backup || "$resume_fixture" == running || ! -f "$scratch/fail-backup" ]] || fail 'mock isolated boot interruption'
    [[ "$1" != prepare-sync || "$resume_fixture" != running || ! -f "$scratch/fail-backup" ]] || fail 'mock interrupted native sync preparation'
    if [[ "$1" == sync-info ]]; then
      jq -cn --arg chain "$CHAIN" '{chain_id:$chain,snapshot_height:306580,trust_height:306582,rpc_url:"https://source.example.test/chain-rpc/"}'
    fi
    if [[ "$1" == enable && "$2" == "$source_alias" ]]; then
      fixture_validators="$(jq '(.result.validators[] | select(.pub_key.value=="temporary") | .pub_key.value)="original-source"' <<<"$fixture_validators")"
    fi
  }
  progress() {
    check_target "$1"; record progress "$1"
    if [[ -e "$RUN/handoff-removed" && "$1" == "$source_alias" ]]; then
      [[ "$2" == 306601 ]] || exit 99
    fi
  }
  same_chain() { [[ "$1" == "${returning_aliases[0]}" || "$1" == "${returning_aliases[1]}" ]] || exit 99; record compare "$1"; }
  status() { printf '%s\n' '{"result":{"sync_info":{"latest_block_height":"306601","catching_up":false}}}'; }
  retire_lost_keys() {
    record retire "$SOURCE_ALIAS"; touch "$RUN/retired"
    [[ ${1:-} != handoff ]] || touch "$RUN/handoff-removed"
  }
  native_source_handoff() {
    retire_lost_keys handoff
    mkdir -p "$RUN/native-key-removal"; touch "$RUN/native-key-removal/complete"
  }
  ssh() {
    local alias="${*: -2:1}" command="${*: -1}"
    check_target "$alias"; record ssh "$alias"
    case "$command" in
      *tee*) jq -e --arg chain "$CHAIN" '.chain_id == $chain' >/dev/null ;;
      *"test ! -e"*) : ;;
      *'/commit?height=306600'*) printf '%s\n' "$fixture_commit" ;;
      *validators\?*) printf '%s\n' "$fixture_validators" ;;
      *) printf 'unexpected mocked command: %s\n' "$command" >&2; exit 99 ;;
    esac
  }
  touch "$scratch/fail-backup"
  if (recover_source "$source_alias") >"$scratch/interrupted.log" 2>&1; then
    echo 'mock stop failure was ignored' >&2; exit 1
  fi
  [[ -f "$RUN/confirmed" && ! -e "$RUN/ready" ]]
  mv "$scratch/fail-backup" "$scratch/failed-backup-evidence"
  recover_source "$source_alias"
  [[ "$(grep -c '^inspect ' "$flow_log")" == 1 ]]
  if [[ "$resume_fixture" == backup ]]; then
    [[ "$(grep -c '^resume-backup ' "$flow_log")" == 1 && "$(grep -c '^boot ' "$flow_log")" == 1 ]]
  elif [[ "$resume_fixture" == dns-boot ]]; then
    ! grep -q '^resume-backup ' "$flow_log"
    [[ "$(grep -c '^archive-dns-boot ' "$flow_log")" == 1 && "$(grep -c '^boot ' "$flow_log")" == 2 ]]
  elif [[ "$resume_fixture" == genesis ]]; then
    ! grep -Eq '^(resume-backup|archive-dns-boot) ' "$flow_log"
    [[ "$(grep -c '^boot ' "$flow_log")" == 1 && "$(grep -c '^resume-genesis ' "$flow_log")" == 1 ]]
  elif [[ "$resume_fixture" == promoted ]]; then
    ! grep -Eq '^(resume-backup|archive-dns-boot|resume-genesis) ' "$flow_log"
    [[ "$(grep -c '^boot ' "$flow_log")" == 1 && "$(grep -c '^resume-promoted ' "$flow_log")" == 1 ]]
  else
    ! grep -Eq '^(resume-backup|archive-dns-boot|resume-genesis|resume-promoted) ' "$flow_log"
    [[ "$(grep -c '^boot ' "$flow_log")" == 1 ]]
  fi
  recover_source "$source_alias"
  [[ "$(grep -c '^retire ' "$flow_log")" == 1 && "$(grep -c '^services ' "$flow_log")" == 1 ]]
  [[ ! -e "$RUN/chain-data.tar.gz" && -s "$RUN/state-sync.json" ]]
  [[ -f "$RUN/ready" && "$(<"$RUN/source-alias")" == "$source_alias" ]]
  awk -v source="$source_alias" '$2 != source {exit 1}' "$flow_log"
  [[ "$(grep -c '^backup ' "$flow_log")" == 1 ]]
  if (reset_host "$source_alias") >"$scratch/source-reset-error" 2>&1; then
    echo 'reset accepted the recovery source' >&2; exit 1
  fi
  for active_alias in "${returning_aliases[@]}"; do
    reset_host "$active_alias"
    [[ "$(grep -c "^backup $active_alias$" "$flow_log")" == 1 ]]
    reset_host "$active_alias"
    [[ "$(grep -c "^backup $active_alias$" "$flow_log")" == 1 ]]
    archive="$GDC_DATA_ROOT/$(host_name "$active_alias")-validator-backup.tar"
    join_host "$active_alias" "$archive" restore.example.test
    [[ -f "$RUN/$active_alias-joined" ]]
    if [[ "$active_alias" == "${returning_aliases[0]}" ]]; then
      [[ ! -e "$RUN/complete" ]]
      ! grep -Fq "enable $source_alias" "$flow_log"
    fi
  done
  [[ ! -e "$RUN/handoff.complete" ]]
  ! grep -Fq "enable $source_alias" "$flow_log"
  finish_recovery
  [[ -e "$RUN/handoff.complete" && ! -e "$RUN/complete" ]]
  [[ -e "$RUN/handoff-removed" ]]
  [[ "$(grep -Fc "epochs-bootstrap $source_alias" "$flow_log")" == 1 ]]
  [[ "$(grep -Fc "epochs-restored $source_alias" "$flow_log")" == 1 ]]
  [[ "$(grep -Fc "enable $source_alias" "$flow_log")" == 1 ]]
)
done
printf 'PASS single-target recovery, per-target reset/restore and quorum-based source handoff (mock only)\n'

# Exercise the actual launcher with a recording incident entry point in a
# disposable copy. No SSH, Docker, production archive or credential is used.
cp -a "$RUNBOOK" "$scratch/runbook"
cat >"$scratch/runbook/scripts/recover-incident.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$INCIDENT_TEST_ARGS"
SH
export INCIDENT_TEST_ARGS="$scratch/args"
launcher="$scratch/runbook/gdc.sh"
GDC_HOME="$scratch/operator" "$launcher" network recover bootstrap "$source_alias"
[[ "$(<"$scratch/args")" == "$(printf 'bootstrap\n%s' "$source_alias")" ]]
GDC_HOME="$scratch/operator" "$launcher" network recover handoff "$source_alias" --hosts fixture-west,fixture-east
[[ "$(<"$scratch/args")" == "$(printf 'handoff\n%s\n--hosts\nfixture-west,fixture-east' "$source_alias")" ]]
cat >"$scratch/runbook/scripts/fetch-network-bootstrap.sh" <<'SH'
#!/usr/bin/env bash
touch "$INCIDENT_TEST_NORMAL_JOIN"
exit 73
SH
cat >"$scratch/runbook/scripts/phase-node.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$INCIDENT_TEST_NORMAL_RESET"
SH
export INCIDENT_TEST_NORMAL_JOIN="$scratch/normal-join"
export INCIDENT_TEST_NORMAL_RESET="$scratch/normal-reset"
mkdir -p "$scratch/operator/recovery-$INCIDENT"
touch "$scratch/operator/recovery-$INCIDENT/confirmed"
for node in fixture-west fixture-east; do
  rm -f "$scratch/args" "$INCIDENT_TEST_NORMAL_JOIN"
  GDC_HOME="$scratch/operator" "$launcher" host reset "$node"
  [[ "$(<"$INCIDENT_TEST_NORMAL_RESET")" == "$(printf 'reset\n%s' "$node")" && ! -e "$scratch/args" ]]
  # Even an enrolled, unfinished incident must never intercept normal JOIN.
  mkdir -p "$scratch/operator/recovery-$INCIDENT/hosts"
  printf '{}\n' >"$scratch/operator/recovery-$INCIDENT/hosts/$node.json"
  archive="$scratch/$node-validator-backup.tar"
  printf 'dispatcher fixture only\n' >"$archive"
  if GDC_HOME="$scratch/operator" "$launcher" host join --restore "$archive" --public-host restore.example.test "$node" >"$scratch/error" 2>&1; then
    echo 'JOIN ignored deliberate mock fetch failure' >&2; exit 1
  fi
  [[ -e "$INCIDENT_TEST_NORMAL_JOIN" && ! -e "$scratch/args" ]]
done
if GDC_HOME="$scratch/operator" "$launcher" host join --plan --restore "$archive" --public-host restore.example.test "$node" >"$scratch/error" 2>&1; then
  echo 'incident route ignored --plan' >&2; exit 1
fi
[[ -e "$INCIDENT_TEST_NORMAL_JOIN" && ! -e "$scratch/args" ]]
printf 'PASS explicit recovery dispatch; reset and restore always use normal phases\n'

# A new Host without --restore must still follow ordinary JOIN. Its first
# network boundary is a local recorder, so this check cannot fetch Bootstrap.
cat >"$scratch/runbook/scripts/fetch-network-bootstrap.sh" <<'SH'
#!/usr/bin/env bash
touch "$INCIDENT_TEST_NORMAL_JOIN"
exit 73
SH
export INCIDENT_TEST_NORMAL_JOIN="$scratch/normal-join"
if GDC_HOME="$scratch/operator" "$launcher" host join --plan --public-host new.example.test fixture-new >"$scratch/new-host-error" 2>&1; then
  echo 'ordinary JOIN ignored the deliberately failed mock fetch' >&2; exit 1
fi
[[ -e "$INCIDENT_TEST_NORMAL_JOIN" ]]
printf 'PASS new Host uses ordinary JOIN without incident dispatch\n'

# The actual entry point must refuse a reset without a completed recovery
# before attempting a remote call.
if GDC_HOME="$scratch/empty" bash "$RUNBOOK/scripts/recover-incident.sh" reset "${returning_aliases[0]}" >"$scratch/error" 2>&1; then
  echo 'unprepared incident reset was accepted' >&2; exit 1
fi
grep -Fq 'expected bootstrap, handoff, or check' "$scratch/error"
if GDC_HOME="$scratch/empty" bash "$RUNBOOK/scripts/recover-incident.sh" bootstrap '--unsafe' >"$scratch/error" 2>&1; then
  echo 'unsafe source alias was accepted' >&2; exit 1
fi
grep -Fq 'safe source SSH alias' "$scratch/error"
! grep -Eq '(^|[[:space:]])python[0-9]*([[:space:]]|$)' "$RUNBOOK/scripts/recover-incident.sh"
! grep -Fq 'chain-data.tar.gz' "$RUNBOOK/scripts/recover-incident.sh"
printf 'PASS incident preconditions; no new Python runtime\n'
