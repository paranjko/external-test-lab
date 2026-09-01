#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
cleanup() {
  local rc=$?
  if (( rc != 0 )) && [[ -s "${log:-}" ]]; then
    printf '%s\n' '--- gateway migration mock operations ---' >&2
    sed -n '1,240p' "$log" >&2
  fi
  rm -rf "$tmp"
  exit "$rc"
}
trap cleanup EXIT
ops="$tmp/ops"
migration="$ops/gateway-migrations/test-run"
mkdir -p "$tmp/bin" "$ops" "$migration/04-ops"
cp "$ROOT/04-ops/compose.yaml" "$ops/compose.yaml"
printf '%s\n' '# retained-source-compose-contract' >>"$ops/compose.yaml"
cp "$ROOT/04-ops/compose.yaml" "$migration/04-ops/compose.yaml"
printf '%s\n' 'LOCAL_GATEWAY_IMAGE=source-image' >"$ops/.env"
printf '%s\n' 'LOCAL_GATEWAY_IMAGE=target-image' >"$tmp/target-compose.env"
log="$tmp/operations.log"

cat >"$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'docker %s\n' "$*" >>"$GDC_TEST_MIGRATION_LOG"
if [[ "${1:-}" == ps && "${2:-}" == -q ]]; then
  if [[ -e "$GDC_TEST_PROMOTED" ]]; then
    printf '%064d\n' 3
  else
    printf '%064d\n' 1
    printf '%064d\n' 2
  fi
elif [[ "${1:-}" == inspect && "$2" == "$(printf '%064d' 1)" ]]; then
  printf '%s\n' '[{"Id":"'"$(printf '%064d' 1)"'","Config":{"Image":"source-image","Env":["DEVSHARD_PORT=18080"]},"Image":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","Mounts":[{"Type":"volume","Name":"gdc-ops_gateway-data-v4-source","Destination":"/root/.devshardctl"}]}]'
elif [[ "${1:-}" == inspect && "$2" == "$(printf '%064d' 2)" ]]; then
  target_volume=gdc-ops_gateway-data-v5-target
  [[ ! -e "$GDC_TEST_WRONG_TARGET_VOLUME" ]] || target_volume=gdc-ops_gateway-data-unexpected
  printf '%s\n' '[{"Id":"'"$(printf '%064d' 2)"'","Config":{"Image":"target-image","Env":["DEVSHARD_PORT=18085"]},"Image":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","Mounts":[{"Type":"volume","Name":"'"$target_volume"'","Destination":"/root/.devshardctl"}]}]'
elif [[ "${1:-}" == inspect && "$2" == "$(printf '%064d' 3)" ]]; then
  promoted_volume=gdc-ops_gateway-data-v5-target
  [[ ! -e "$GDC_TEST_PROMOTION_IDENTITY_FAIL" ]] || promoted_volume=gdc-ops_gateway-data-unexpected
  printf '%s\n' '[{"Id":"'"$(printf '%064d' 3)"'","Config":{"Image":"target-image","Env":["DEVSHARD_PORT=18080"]},"Image":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","Mounts":[{"Type":"volume","Name":"'"$promoted_volume"'","Destination":"/root/.devshardctl"}]}]'
elif [[ "${1:-}" == image && "${2:-}" == inspect ]]; then
  case "${*: -1}" in
    source-image) printf '%s\n' 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ;;
    target-image) printf '%s\n' 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ;;
    *) exit 1 ;;
  esac
elif [[ "${1:-}" == stop && "${2:-}" == "$(printf '%064d' 3)" ]]; then
  rm -f "$GDC_TEST_PROMOTED"
fi
if [[ "$PWD" == "$GDC_GATEWAY_OPS_ROOT" && " $* " == *' up '* \
  && -f "$GDC_GATEWAY_OPS_ROOT/.env" \
  && -e "$GDC_TEST_SOURCE_RESTORE_FAIL" ]] \
  && grep -Fxq 'LOCAL_GATEWAY_IMAGE=source-image' "$GDC_GATEWAY_OPS_ROOT/.env"; then
  exit 1
fi
if [[ "$PWD" == "$GDC_GATEWAY_OPS_ROOT" && " $* " == *' up '* \
  && -f "$GDC_GATEWAY_OPS_ROOT/.env" ]] \
  then
  if grep -Fxq 'LOCAL_GATEWAY_IMAGE=target-image' "$GDC_GATEWAY_OPS_ROOT/.env"; then
    : >"$GDC_TEST_PROMOTED"
  else
    rm -f "$GDC_TEST_PROMOTED"
  fi
fi
EOF

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
method=GET
output=''
data_file=''
data=''
url=''
while (($#)); do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -o) output="$2"; shift 2 ;;
    --data-binary)
      if [[ "$2" == @* ]]; then data_file="${2#@}"; else data="$2"; fi
      shift 2
      ;;
    -d|-H|--connect-timeout|--max-time) shift 2 ;;
    -*) shift ;;
    http://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf 'curl %s %s\n' "$method" "$url" >>"$GDC_TEST_MIGRATION_LOG"
case "$url" in
  http://127.0.0.1:26657/status)
    payload='{"result":{"sync_info":{"latest_block_height":"40"}}}'
    ;;
  http://127.0.0.1:1317/productscience/inference/inference/params)
    payload='{"params":{"epoch_params":{"epoch_length":"100","epoch_shift":"0","poc_stage_duration":"2","poc_exchange_duration":"2","poc_validation_delay":"2","poc_validation_duration":"2","set_new_validators_delay":"2"}}}'
    ;;
  http://127.0.0.1:18080/v1/admin/settings|http://127.0.0.1:18085/v1/admin/settings)
    if [[ "$method" == GET && "$url" == http://127.0.0.1:18085/* \
      && -e "$GDC_TEST_TARGET_SETTINGS_DELAY" ]]; then
      printf 'attempt\n' >>"$GDC_TEST_TARGET_SETTINGS_DELAY_COUNT"
      if (( $(wc -l <"$GDC_TEST_TARGET_SETTINGS_DELAY_COUNT") < 3 )); then
        exit 22
      fi
      rm -f "$GDC_TEST_TARGET_SETTINGS_DELAY"
    fi
    if [[ "$method" == POST ]]; then
      if [[ "$url" == http://127.0.0.1:18080/* && -e "$GDC_TEST_PROMOTED" \
        && -e "$GDC_TEST_CANONICAL_SETTINGS_FAIL" ]]; then
        exit 22
      fi
      [[ -s "$data_file" ]] && cp "$data_file" "$GDC_TEST_LAST_SETTINGS"
      payload='{"ok":true}'
    elif [[ -s "$GDC_TEST_LAST_SETTINGS" ]]; then
      payload="$(<"$GDC_TEST_LAST_SETTINGS")"
    else
      payload='{"escrow_rotation":{"enabled":true,"settlement_enabled":true,"pre_poc_blocks":5,"models":[]}}'
    fi
    ;;
  http://127.0.0.1:18085/v1/admin/escrows)
    [[ "$method" == POST ]] || exit 22
    [[ -n "$data" ]] || data="$(<"$data_file")"
    printf '%s\n' "$data" >"$GDC_TEST_LAST_ESCROW_CREATE"
    printf 'create\n' >>"$GDC_TEST_ESCROW_CREATE_COUNT"
    : >"$GDC_TEST_TARGET_CREATED"
    payload='{"escrow_id":"52","registered":true}'
    if [[ -e "$GDC_TEST_CREATE_RESPONSE_LOSS" ]]; then
      exit 28
    fi
    ;;
  http://127.0.0.1:18080/v1/admin/state)
    if [[ -e "$GDC_TEST_PROMOTED" ]]; then
      payload='{"limiter":{"in_flight_requests":0},"capacity":{"models":{"Qwen/Qwen3-0.6B":{"routable":true}}},"devshards":[{"id":"52","model":"Qwen/Qwen3-0.6B","active":true,"protocol_version":"v5","route_prefix":"/devshard/v5","runtime":{"phase":"active","chain_phase":"Inference","session_version":"v5","active_requests":0}}]}'
    elif [[ -e "$GDC_TEST_FREEZE_NO_ESCROW" ]]; then
      payload='{"limiter":{"in_flight_requests":0},"capacity":{"models":{}},"devshards":[]}'
    else
      payload='{"limiter":{"in_flight_requests":0},"capacity":{"models":{"Qwen/Qwen3-0.6B":{"routable":true}}},"devshards":[{"id":"41","model":"Qwen/Qwen3-0.6B","active":true,"protocol_version":"v4","route_prefix":"/devshard/v4","runtime":{"phase":"active","chain_phase":"Inference","session_version":"v4","active_requests":0}}]}'
    fi
    ;;
  http://127.0.0.1:18085/v1/admin/state)
    if [[ -e "$GDC_TEST_AMBIGUOUS_TARGET" ]]; then
      payload='{"limiter":{"in_flight_requests":0},"capacity":{"models":{"Qwen/Qwen3-0.6B":{"routable":true}}},"devshards":[{"id":"52","model":"Qwen/Qwen3-0.6B","route_prefix":"/devshard/v5"},{"id":"53","model":"Qwen/Qwen3-0.6B","route_prefix":"/devshard/v5"}]}'
    elif [[ -e "$GDC_TEST_TARGET_CREATED" ]]; then
      payload='{"limiter":{"in_flight_requests":0},"capacity":{"models":{"Qwen/Qwen3-0.6B":{"routable":true}}},"devshards":[{"id":"52","model":"Qwen/Qwen3-0.6B","active":true,"protocol_version":"v5","route_prefix":"/devshard/v5","runtime":{"phase":"active","chain_phase":"Inference","session_version":"v5","requests_blocked":false,"active_requests":0}}]}'
    else
      payload='{"limiter":{"in_flight_requests":0},"capacity":{"models":{}},"devshards":[]}'
    fi
    ;;
  http://127.0.0.1:18085/v1/chat/completions)
    if [[ -e "$GDC_TEST_BAD_SMOKE" ]]; then
      payload='{"id":"completion-test","model":"wrong-model","choices":[]}'
    else
      payload='{"id":"completion-test","model":"Qwen/Qwen3-0.6B","choices":[{"message":{"content":"ok"}}]}'
    fi
    ;;
  *) exit 22 ;;
esac
if [[ "$url" == */v1/admin/state ]]; then
  if [[ -e "$GDC_TEST_DRAIN_MISSING_GLOBAL" ]]; then
    payload="$(jq -c 'del(.limiter.in_flight_requests)' <<<"$payload")"
  fi
  if [[ -e "$GDC_TEST_DRAIN_EMPTY_DEVSHARDS" ]]; then
    payload="$(jq -c '.devshards=[]' <<<"$payload")"
  fi
  if [[ -e "$GDC_TEST_DRAIN_MISSING_ACTIVE" ]]; then
    payload="$(jq -c 'del(.devshards[].runtime.active_requests,.devshards[].active_requests)' <<<"$payload")"
  fi
fi
if [[ -n "$output" ]]; then
  printf '%s\n' "$payload" >"$output"
else
  printf '%s\n' "$payload"
fi
EOF
chmod 0755 "$tmp/bin/docker" "$tmp/bin/curl"

write_gateway_env() {
  local output="$1" version="$2" port="$3" volume="$4" escrow="$5"
  cat >"$output" <<EOF
DEVSHARD_ADMIN_API_KEY=admin-key
DEVSHARD_API_KEYS=client-key
DEVSHARD_PRIVATE_KEY=private-key-secret
DEVSHARD_MODEL=Qwen/Qwen3-0.6B
DEVSHARD_PORT=$port
DEVSHARD_ROUTE_PREFIX=/devshard/$version
DEVSHARD_BINARY_SHA256=$(if [[ "$version" == v4 ]]; then printf '%064d' 4; else printf '%064d' 5; fi)
DEVSHARD_GATEWAY_DATA_VOLUME=gateway-data-$version
DEVSHARD_GATEWAY_DATA_VOLUME_NAME=$volume
$(if [[ -n "$escrow" ]]; then printf 'DEVSHARD_ESCROW_ID=%s' "$escrow"; else printf 'DEVSHARDS_JSON=[]'; fi)
GATEWAY_MAX_CONCURRENT_REQUESTS=4
GATEWAY_DEFAULT_MAX_TOKENS=128
GATEWAY_MAX_CONCURRENT_REQUESTS_PER_10000_WEIGHT=1000000000
GATEWAY_MAX_INPUT_TOKENS_IN_FLIGHT=4096
GATEWAY_PARTICIPANT_REQUEST_BURST=1000
GATEWAY_PARTICIPANT_RECOVERY_PER_MINUTE=1000
GDC_GATEWAY_PRE_POC_BLOCKS=5
GDC_GATEWAY_ROTATION_TEMP_COUNT=2
GDC_GATEWAY_ROTATION_TARGET_COUNT=2
DEVSHARD_ROTATION_ESCROW_AMOUNT=1000000
DEVSHARD_GATEWAY_DATA_VOLUME_${version^^}_NAME=$volume
EOF
  chmod 0600 "$output"
}

# A previously promoted multi-DevShard gateway has no bootstrap escrow in its
# environment. The migration must resolve its active source escrow from the
# authenticated admin state instead of requiring legacy DEVSHARD_ESCROW_ID.
write_gateway_env "$ops/gateway.env" v4 18080 gdc-ops_gateway-data-v4-source ''
write_gateway_env "$tmp/target.env" v5 18085 gdc-ops_gateway-data-v5-target ''

export PATH="$tmp/bin:$PATH"
export GDC_TEST_MIGRATION_LOG="$log"
export GDC_TEST_LAST_SETTINGS="$tmp/last-settings.json"
export GDC_TEST_PROMOTED="$tmp/promoted"
export GDC_TEST_WRONG_TARGET_VOLUME="$tmp/wrong-target-volume"
export GDC_TEST_BAD_SMOKE="$tmp/bad-smoke"
export GDC_TEST_LAST_ESCROW_CREATE="$tmp/last-escrow-create.json"
export GDC_TEST_ESCROW_CREATE_COUNT="$tmp/escrow-create-count"
export GDC_TEST_TARGET_CREATED="$tmp/target-created"
export GDC_TEST_CREATE_RESPONSE_LOSS="$tmp/create-response-loss"
export GDC_TEST_AMBIGUOUS_TARGET="$tmp/ambiguous-target"
export GDC_TEST_FREEZE_NO_ESCROW="$tmp/freeze-no-escrow"
export GDC_TEST_DRAIN_MISSING_GLOBAL="$tmp/drain-missing-global"
export GDC_TEST_DRAIN_EMPTY_DEVSHARDS="$tmp/drain-empty-devshards"
export GDC_TEST_DRAIN_MISSING_ACTIVE="$tmp/drain-missing-active"
export GDC_TEST_CANONICAL_SETTINGS_FAIL="$tmp/canonical-settings-fail"
export GDC_TEST_SOURCE_RESTORE_FAIL="$tmp/source-restore-fail"
export GDC_TEST_PROMOTION_IDENTITY_FAIL="$tmp/promotion-identity-fail"
export GDC_TEST_TARGET_SETTINGS_DELAY="$tmp/target-settings-delay"
export GDC_TEST_TARGET_SETTINGS_DELAY_COUNT="$tmp/target-settings-delay-count"
export GDC_GATEWAY_OPS_ROOT="$ops"
helper="$ROOT/04-ops/gateway-migration-remote.sh"

"$helper" preflight-window 1

freeze_failure="$ops/gateway-migrations/freeze-failure"
mkdir -p "$freeze_failure/04-ops"
cp "$ROOT/04-ops/compose.yaml" "$freeze_failure/04-ops/compose.yaml"
touch "$GDC_TEST_FREEZE_NO_ESCROW"
if "$helper" freeze "$freeze_failure" 18080 \
  >"$tmp/freeze-failure.out" 2>"$tmp/freeze-failure.err"; then
  echo 'gateway migration accepted a source freeze without its retained escrow' >&2
  exit 1
fi
grep -Fq 'source gateway has no active escrow' "$tmp/freeze-failure.err"
jq -e '.escrow_rotation.enabled == true and .escrow_rotation.settlement_enabled == true' \
  "$GDC_TEST_LAST_SETTINGS" >/dev/null
rm -f "$GDC_TEST_FREEZE_NO_ESCROW"

# A gateway deployed by the previous Compose contract may not report an
# explicit physical volume name in gateway.env. Resolve and retain the exact
# mounted source volume instead of requiring an in-place source redeploy.
cp "$ops/gateway.env" "$tmp/source-with-volume-name.env"
sed -i '/^DEVSHARD_GATEWAY_DATA_VOLUME_NAME=/d' "$ops/gateway.env"
legacy_volume="$ops/gateway-migrations/legacy-volume"
mkdir -p "$legacy_volume/04-ops"
cp "$ROOT/04-ops/compose.yaml" "$legacy_volume/04-ops/compose.yaml"
"$helper" freeze "$legacy_volume" 18080 >/dev/null
"$helper" prepare "$legacy_volume" "$tmp/target.env" "$tmp/target-compose.env" \
  gdc-ops-migrate-v5-legacy-volume 18080 18085 >/dev/null
grep -Fxq 'source_volume=gdc-ops_gateway-data-v4-source' "$legacy_volume/manifest.env"
"$helper" restore-source "$legacy_volume" >/dev/null
install -m 0600 "$tmp/source-with-volume-name.env" "$ops/gateway.env"
rm -f "$GDC_TEST_ESCROW_CREATE_COUNT" "$GDC_TEST_TARGET_CREATED"

"$helper" freeze "$migration" 18080
jq -e '.escrow_rotation.enabled == false and .escrow_rotation.settlement_enabled == false' \
  "$GDC_TEST_LAST_SETTINGS" >/dev/null
touch "$GDC_TEST_CREATE_RESPONSE_LOSS"
"$helper" prepare "$migration" "$tmp/target.env" "$tmp/target-compose.env" \
  gdc-ops-migrate-v5-test 18080 18085
rm -f "$GDC_TEST_CREATE_RESPONSE_LOSS"
jq -e '
  .amount == 1000000
  and .model_id == "Qwen/Qwen3-0.6B"
  and .private_key_env == "DEVSHARD_PRIVATE_KEY"
  and .route_prefix == "/devshard/v5"
  and .register == true
  and has("private_key") == false
  and has("protocol_version") == false
  and has("chain_id") == false
' "$GDC_TEST_LAST_ESCROW_CREATE" >/dev/null
if grep -Fq 'private-key-secret' "$GDC_TEST_LAST_ESCROW_CREATE"; then
  echo 'gateway migration persisted a private key in escrow evidence' >&2
  exit 1
fi
[[ "$(wc -l <"$GDC_TEST_ESCROW_CREATE_COUNT")" == 1 ]]
# A retained failed preparation resumes the exact target identity instead of
# creating another migration or accepting changed inputs.
sed -i 's/^phase=prepared$/phase=failed/' "$migration/manifest.env"
"$helper" prepare "$migration" "$tmp/target.env" "$tmp/target-compose.env" \
  gdc-ops-migrate-v5-test 18080 18085
[[ "$(wc -l <"$GDC_TEST_ESCROW_CREATE_COUNT")" == 1 ]]
grep -Fxq 'phase=prepared' "$migration/manifest.env"
status="$tmp/status.json"
"$helper" status "$migration" >"$status"
jq -e '
  .phase == "prepared"
  and .images.source.reference == "source-image"
  and .images.target.reference == "target-image"
  and .images.source.id == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  and .images.target.id == "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  and .source.available == true and .source.in_flight == 0
  and .target.available == true
  and (.target.devshards | any(.protocol_version == "v5" and .route_prefix == "/devshard/v5"))
' "$status" >/dev/null

freeze_line="$(grep -nF 'curl POST http://127.0.0.1:18080/v1/admin/settings' "$log" | head -1 | cut -d: -f1)"
target_start_line="$(grep -nF 'docker compose -p gdc-ops-migrate-v5-test' "$log" | head -1 | cut -d: -f1)"
(( freeze_line < target_start_line ))
grep -Fq -- "--env-file $migration/target-compose.env --env-file $migration/target.env up" "$log"

"$helper" mark "$migration" cutover_pending
grep -Fxq 'phase=cutover_pending' "$migration/manifest.env"
"$helper" mark "$migration" cutover
grep -Fxq 'phase=cutover' "$migration/manifest.env"
for invalid_state in \
  "$GDC_TEST_DRAIN_MISSING_GLOBAL" \
  "$GDC_TEST_DRAIN_EMPTY_DEVSHARDS" \
  "$GDC_TEST_DRAIN_MISSING_ACTIVE"; do
  touch "$invalid_state"
  if GDC_GATEWAY_MIGRATION_DRAIN_POLL_SECONDS=0 \
    "$helper" drain "$migration" 1 >"$tmp/drain-invalid.out" 2>"$tmp/drain-invalid.err"; then
    echo "gateway migration accepted incomplete drain evidence flag=$invalid_state" >&2
    exit 1
  fi
  grep -Fq 'did not prove a complete zero-request state' "$tmp/drain-invalid.err"
  grep -Fxq 'phase=cutover' "$migration/manifest.env"
  rm -f "$invalid_state"
done

"$helper" drain "$migration" 1
grep -Fxq 'phase=drained' "$migration/manifest.env"
"$helper" mark "$migration" cutover | grep -Fq 'already recorded'
grep -Fxq 'phase=drained' "$migration/manifest.env"
"$helper" drain-target "$migration" 1
"$helper" restore-source "$migration"
grep -Fxq 'phase=rolled_back' "$migration/manifest.env"
if "$helper" mark "$migration" cutover >"$tmp/regression.out" 2>"$tmp/regression.err"; then
  echo 'gateway migration accepted a rolled-back to cutover phase regression' >&2
  exit 1
fi
grep -Fq 'invalid gateway migration transition' "$tmp/regression.err"
jq -e '.escrow_rotation.enabled == true and .escrow_rotation.settlement_enabled == true' \
  "$GDC_TEST_LAST_SETTINGS" >/dev/null
"$helper" freeze "$migration" 18080 >/dev/null
"$helper" prepare "$migration" "$tmp/target.env" "$tmp/target-compose.env" \
  gdc-ops-migrate-v5-test 18080 18085 | grep -Fq 'target gateway prepared side-by-side'
grep -Fxq 'phase=prepared' "$migration/manifest.env"
"$helper" restore-source "$migration" >/dev/null

promote_migration="$ops/gateway-migrations/promote-run"
mkdir -p "$promote_migration/04-ops"
cp "$ROOT/04-ops/compose.yaml" "$promote_migration/04-ops/compose.yaml"
"$helper" freeze "$promote_migration" 18080 >/dev/null
rm -f "$GDC_TEST_TARGET_CREATED"
"$helper" prepare "$promote_migration" "$tmp/target.env" "$tmp/target-compose.env" \
  gdc-ops-migrate-v5-promote 18080 18085 >/dev/null
"$helper" mark "$promote_migration" cutover_pending >/dev/null
"$helper" mark "$promote_migration" cutover >/dev/null
"$helper" drain "$promote_migration" 1 >/dev/null
"$helper" drain-target "$promote_migration" 1 >/dev/null
touch "$GDC_TEST_CANONICAL_SETTINGS_FAIL"
touch "$GDC_TEST_SOURCE_RESTORE_FAIL"
if "$helper" promote "$promote_migration" >"$tmp/promote-failure.out" 2>"$tmp/promote-failure.err"; then
  echo 'gateway migration accepted a failed post-start target configuration' >&2
  exit 1
fi
grep -Fq 'runtime restoration is incomplete; retained phase=promoting' "$tmp/promote-failure.err"
grep -Fxq 'phase=promoting' "$promote_migration/manifest.env"
rm -f "$GDC_TEST_SOURCE_RESTORE_FAIL"
if "$helper" promote "$promote_migration" >"$tmp/promote-recovery.out" 2>"$tmp/promote-recovery.err"; then
  echo 'gateway migration accepted the injected target settings failure after recovery' >&2
  exit 1
fi
grep -Fq 'both retained runtimes were restored for a safe retry' "$tmp/promote-recovery.err"
grep -Fxq 'phase=drained' "$promote_migration/manifest.env"
grep -Fxq 'LOCAL_GATEWAY_IMAGE=source-image' "$ops/.env"
grep -Fxq 'DEVSHARD_PORT=18080' "$ops/gateway.env"
grep -Fq '# retained-source-compose-contract' "$ops/compose.yaml"
[[ ! -e "$GDC_TEST_PROMOTED" ]]
rm -f "$GDC_TEST_CANONICAL_SETTINGS_FAIL"
touch "$GDC_TEST_PROMOTION_IDENTITY_FAIL"
touch "$GDC_TEST_TARGET_SETTINGS_DELAY"
: >"$GDC_TEST_TARGET_SETTINGS_DELAY_COUNT"
if GDC_GATEWAY_MIGRATION_ADMIN_READY_TIMEOUT_SECONDS=2 \
  GDC_GATEWAY_MIGRATION_ADMIN_READY_POLL_SECONDS=0 \
  "$helper" promote "$promote_migration" >"$tmp/promote-identity-failure.out" \
  2>"$tmp/promote-identity-failure.err"; then
  echo 'gateway migration accepted a promoted runtime with the wrong retained identity' >&2
  exit 1
fi
grep -Fq 'both retained runtimes were restored for a safe retry' \
  "$tmp/promote-identity-failure.err"
grep -Fxq 'phase=drained' "$promote_migration/manifest.env"
jq -e '.escrow_rotation.enabled == false and .escrow_rotation.settlement_enabled == false' \
  "$GDC_TEST_LAST_SETTINGS" >/dev/null
[[ "$(wc -l <"$GDC_TEST_TARGET_SETTINGS_DELAY_COUNT")" == 3 ]]
rm -f "$GDC_TEST_PROMOTION_IDENTITY_FAIL"
"$helper" promote "$promote_migration"
grep -Fxq 'phase=completed' "$promote_migration/manifest.env"
grep -Fxq 'LOCAL_GATEWAY_IMAGE=target-image' "$ops/.env"
grep -Fxq 'DEVSHARD_PORT=18080' "$ops/gateway.env"
if grep -Fq '# retained-source-compose-contract' "$ops/compose.yaml"; then
  echo 'gateway promotion retained the obsolete source Compose contract' >&2
  exit 1
fi
"$helper" promote "$promote_migration" | grep -Fq 'already promoted'
"$helper" prepare "$promote_migration" "$tmp/target.env" "$tmp/target-compose.env" \
  gdc-ops-migrate-v5-promote 18080 18085 | grep -Fq 'phase=completed'

# Restore the source fixture before testing an invalid new target.
install -m 0600 "$promote_migration/source-compose.env" "$ops/.env"
install -m 0600 "$promote_migration/source.env" "$ops/gateway.env"
rm -f "$GDC_TEST_PROMOTED"

bad="$ops/gateway-migrations/bad-run"
mkdir -p "$bad/04-ops"
cp "$ROOT/04-ops/compose.yaml" "$bad/04-ops/compose.yaml"
"$helper" freeze "$bad" 18080 >/dev/null
write_gateway_env "$tmp/bad-target.env" v5 18085 gdc-ops_gateway-data-v4-source ''
if "$helper" prepare "$bad" "$tmp/bad-target.env" "$tmp/target-compose.env" \
  gdc-ops-migrate-v5-bad 18080 18085 \
  >"$tmp/bad.out" 2>"$tmp/bad.err"; then
  echo 'gateway migration accepted a shared source/target volume' >&2
  exit 1
fi
grep -Fq 'source and target gateway identities are not distinct' "$tmp/bad.err"

install -m 0600 "$promote_migration/source-compose.env" "$ops/.env"
install -m 0600 "$promote_migration/source.env" "$ops/gateway.env"
rm -f "$GDC_TEST_PROMOTED"

wrong_volume="$ops/gateway-migrations/wrong-volume-run"
mkdir -p "$wrong_volume/04-ops"
cp "$ROOT/04-ops/compose.yaml" "$wrong_volume/04-ops/compose.yaml"
touch "$GDC_TEST_WRONG_TARGET_VOLUME"
"$helper" freeze "$wrong_volume" 18080 >/dev/null
if "$helper" prepare "$wrong_volume" "$tmp/target.env" "$tmp/target-compose.env" \
  gdc-ops-migrate-v5-wrong-volume 18080 18085 \
  >"$tmp/wrong-volume.out" 2>"$tmp/wrong-volume.err"; then
  echo 'gateway migration accepted an unexpected mounted target volume' >&2
  exit 1
fi
grep -Fq 'runtime image or exact data volume differs port=18085' "$tmp/wrong-volume.err"
rm -f "$GDC_TEST_WRONG_TARGET_VOLUME"

bad_smoke="$ops/gateway-migrations/bad-smoke-run"
mkdir -p "$bad_smoke/04-ops"
cp "$ROOT/04-ops/compose.yaml" "$bad_smoke/04-ops/compose.yaml"
touch "$GDC_TEST_BAD_SMOKE"
"$helper" freeze "$bad_smoke" 18080 >/dev/null
rm -f "$GDC_TEST_TARGET_CREATED"
if "$helper" prepare "$bad_smoke" "$tmp/target.env" "$tmp/target-compose.env" \
  gdc-ops-migrate-v5-bad-smoke 18080 18085 \
  >"$tmp/bad-smoke.out" 2>"$tmp/bad-smoke.err"; then
  echo 'gateway migration accepted an invalid target inference response' >&2
  exit 1
fi
grep -Fq 'target direct inference returned an invalid completion' "$tmp/bad-smoke.err"
rm -f "$GDC_TEST_BAD_SMOKE"

ambiguous="$ops/gateway-migrations/ambiguous-run"
mkdir -p "$ambiguous/04-ops"
cp "$ROOT/04-ops/compose.yaml" "$ambiguous/04-ops/compose.yaml"
touch "$GDC_TEST_AMBIGUOUS_TARGET"
"$helper" freeze "$ambiguous" 18080 >/dev/null
if "$helper" prepare "$ambiguous" "$tmp/target.env" "$tmp/target-compose.env" \
  gdc-ops-migrate-v5-ambiguous 18080 18085 \
  >"$tmp/ambiguous.out" 2>"$tmp/ambiguous.err"; then
  echo 'gateway migration accepted ambiguous target escrows' >&2
  exit 1
fi
grep -Fq 'ambiguous matching escrows' "$tmp/ambiguous.err"
rm -f "$GDC_TEST_AMBIGUOUS_TARGET"

orchestrator="$ROOT/scripts/phase-gateway-migration.sh"
suspend_route_line="$(grep -nF '  suspend_and_verify_admission' "$orchestrator" | head -1 | cut -d: -f1)"
observer_bind_line="$(grep -nF '  step "Bind the admission observer' "$orchestrator" | cut -d: -f1)"
(( suspend_route_line < observer_bind_line ))
grep -Fq 'docker compose ps --status running -q gateway-admission' "$orchestrator"
if grep -Eq 'stop gateway-admission.*\|\| true' "$orchestrator"; then
  echo 'gateway migration still masks a public admission stop failure' >&2
  exit 1
fi
rollback_line="$(grep -nF '  rollback_route() {' "$orchestrator" | cut -d: -f1)"
rollback_suspend_line="$(grep -nF '      if suspend_and_verify_admission; then' "$orchestrator" | cut -d: -f1)"
rollback_observer_line="$(grep -nF 'sudo install -m 0600' "$orchestrator" | head -1 | cut -d: -f1)"
rollback_admission_start_line="$(grep -nF 'restart-gateway-admission-after-rollback.log' "$orchestrator" | cut -d: -f1)"
(( rollback_line < rollback_suspend_line \
  && rollback_suspend_line < rollback_observer_line \
  && rollback_observer_line < rollback_admission_start_line ))
grep -Fq 'observer_port" != "$upstream_port' "$orchestrator"
grep -Fq 'route recovery is incomplete; admission was not restarted' "$orchestrator"
# shellcheck disable=SC2016
pending_line="$(grep -nF "mark '\$remote_dir' cutover_pending" "$orchestrator" | cut -d: -f1)"
# shellcheck disable=SC2016
target_route_line="$(grep -nF 'install_route "$target_port" target' "$orchestrator" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016
cutover_line="$(grep -nF "mark '\$remote_dir' cutover\"" "$orchestrator" | head -1 | cut -d: -f1)"
(( pending_line < target_route_line && target_route_line < cutover_line ))
grep -Fq 'prepared|cutover_pending|cutover|drained|failed|preparing)' "$orchestrator"
# shellcheck disable=SC2016
grep -Fq '[[ "$phase" =~ ^(drained|promoting)$ ]]' "$orchestrator"

printf 'PASS side-by-side gateway migration state machine\n'
