#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/../02-node/install-consensus-signer.sh"
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
public_key_tool="$(realpath "$(dirname "$0")/tmkms-softsign-public-key.sh")"
printf '%s\n' AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= >"$temporary/new-key"
expected="$(bash "$public_key_tool" "$temporary/new-key")"
jq -n '{height:"100",round:"2147483647",step:127,block_id:null}' >"$temporary/boundary"
recovery_require_stopped() { [[ "${running:-false}" == false ]]; }
fixture() {
  local base="$temporary/$1" old_sha archive_sha
  mkdir -p "$base/deploy" "$base/identity" "$base/signer/tmkms/secrets" "$base/signer/tmkms/state" "$base/preparation"
  printf '%s\n' old-key >"$base/signer/tmkms/secrets/priv_validator_key.softsign"
  printf '%s\n' connection-key >"$base/signer/tmkms/secrets/kms-identity.key"
  printf '%s\n' configuration >"$base/signer/tmkms/tmkms.toml"
  printf '%s\n' warm-and-p2p >"$base/identity/preserved"
  printf '%s\n' '{"height":"0"}' >"$base/signer/tmkms/state/priv_validator_state.json"
  tar -C "$base" -cf "$base/preparation/validator-before.tar" signer identity
  old_sha="$(sha256sum "$base/signer/tmkms/secrets/priv_validator_key.softsign")"
  archive_sha="$(sha256sum "$base/preparation/validator-before.tar")"
  jq -n --arg old "${old_sha%% *}" --arg archive "${archive_sha%% *}" \
    '{kind:"gdc-consensus-recovery-preparation",run_id:"fixture",previous_softsign_sha256:$old,
      archive_sha256:$archive,consensus_processes_stopped:true,restart_disabled:true,activation_authorized:false}' >"$base/preparation/prepared.json"
}
execute_install() {
  install_consensus_signer "$temporary/$1/deploy" "$temporary/$1/preparation" \
    "$temporary/new-key" "$temporary/boundary" "$expected" "$public_key_tool"
}
fixture pass
execute_install pass
cmp "$temporary/new-key" "$temporary/pass/signer/tmkms/secrets/priv_validator_key.softsign"
[[ "$(<"$temporary/pass/signer/tmkms.before-fixture/secrets/priv_validator_key.softsign")" == old-key ]]
[[ "$(<"$temporary/pass/identity/preserved")" == warm-and-p2p ]]
[[ "$(<"$temporary/pass/signer/tmkms/secrets/kms-identity.key")" == connection-key ]]
[[ "$(<"$temporary/pass/signer/tmkms/tmkms.toml")" == configuration ]]
jq -e '.activation_authorized == false and .container_recreation_required' "$temporary/pass/preparation/installed.json" >/dev/null
if execute_install pass >/dev/null 2>&1; then echo 'FAIL repeated installation accepted' >&2; exit 1; fi
fixture running
running=true
if execute_install running >/dev/null 2>&1; then echo 'FAIL running signer replaced' >&2; exit 1; fi
[[ "$(<"$temporary/running/signer/tmkms/secrets/priv_validator_key.softsign")" == old-key ]]
running=false
for failure in archive key invalid-boundary; do
  fixture "$failure"
  cp "$temporary/boundary" "$temporary/boundary-original"
  saved_expected="$expected"
  case "$failure" in
    archive) printf changed >>"$temporary/$failure/preparation/validator-before.tar" ;;
    key) expected=wrong-key ;;
    invalid-boundary) jq '.round="0"' "$temporary/boundary-original" >"$temporary/boundary" ;;
  esac
  if execute_install "$failure" >/dev/null 2>&1; then echo "FAIL invalid $failure accepted" >&2; exit 1; fi
  [[ "$(<"$temporary/$failure/signer/tmkms/secrets/priv_validator_key.softsign")" == old-key ]]
  [[ ! -e "$temporary/$failure/preparation/installed.json" ]]
  expected="$saved_expected"
  cp "$temporary/boundary-original" "$temporary/boundary"
done
fixture interrupted
mv() {
  if [[ "${*: -1}" == "$temporary/interrupted/signer/tmkms" ]]; then return 1; fi
  command mv "$@"
}
if execute_install interrupted >/dev/null 2>&1; then echo 'FAIL interrupted replacement succeeded' >&2; exit 1; fi
[[ ! -e "$temporary/interrupted/signer/tmkms" && ! -e "$temporary/interrupted/preparation/installed.json" ]]
[[ "$(<"$temporary/interrupted/signer/tmkms.before-fixture/secrets/priv_validator_key.softsign")" == old-key ]]
cmp "$temporary/new-key" "$temporary/interrupted/signer/tmkms.staged-fixture/secrets/priv_validator_key.softsign"
if execute_install interrupted >/dev/null 2>&1; then echo 'FAIL interrupted replacement retried automatically' >&2; exit 1; fi
echo 'PASS Bash signer installation preserves identities and fails closed across interrupted directory replacement'
unset -f mv
image_id="sha256:$(printf '%064d' 0)"
jq -n --arg image "$image_id" '[{service:"node",Image:$image},{service:"tmkms",Image:$image}]' >"$temporary/pass/preparation/containers.json"
docker() {
  printf '%s\n' "$*" >>"$temporary/docker-calls"
  if [[ "$1" == inspect ]]; then
    jq -n --arg image "${test_image:-$image_id}" --arg active "${test_mount:-$temporary/pass/signer/tmkms}" '
      ["node","tmkms"] | map({Image:$image,State:{Running:false},HostConfig:{RestartPolicy:{Name:"no"}},
        Config:{Env:["DO_NOT_RETAIN_SECRET"],Labels:{"com.docker.compose.service":.}},
        Mounts:[{Type:"bind",Destination:"/root/.tmkms",Source:$active}]})'
  elif [[ " $* " == *' ps '* ]]; then
    printf '%012d\n' 1 2
  elif [[ " $* " == *' config --format json ' ]]; then
    jq -n --arg dependency "${test_dependency:-tmkms}" '{services:{node:{depends_on:{($dependency):{}}},tmkms:{}}}'
  elif [[ " $* " == *' create --no-build --pull never --force-recreate node tmkms ' ]]; then
    [[ ${test_create_failure:-false} == false ]]
  else
    echo 'FAIL unexpected Docker operation' >&2; return 1
  fi
}
for failure in image mount create; do
  test_image="$image_id"; test_mount="$temporary/pass/signer/tmkms"; test_create_failure=false
  case "$failure" in
    image) test_image="sha256:$(printf '%064d' 1)" ;;
    mount) test_mount="$temporary/pass/signer/tmkms.before-fixture" ;;
    create) test_create_failure=true ;;
  esac
  if recreate_consensus_stopped "$temporary/pass/deploy" "$temporary/pass/preparation" "$public_key_tool" >/dev/null 2>&1; then
    echo "FAIL recreation accepted invalid $failure" >&2; exit 1
  fi
  [[ ! -e "$temporary/pass/preparation/recreated.json" ]]
  [[ -s "$temporary/pass/preparation/consensus-images.json" ]]
  cmp "$temporary/new-key" "$temporary/pass/signer/tmkms/secrets/priv_validator_key.softsign"
done
unset test_image test_mount test_create_failure
recreate_consensus_stopped "$temporary/pass/deploy" "$temporary/pass/preparation" "$public_key_tool"
test_dependency=api
: >"$temporary/docker-calls"
if recreate_consensus_stopped "$temporary/pass/deploy" "$temporary/pass/preparation" "$public_key_tool"; then
  echo 'FAIL recreation followed an unrelated service dependency' >&2; exit 1
fi
if grep -q ' create ' "$temporary/docker-calls"; then exit 1; fi
unset test_dependency
recreate_consensus_stopped "$temporary/pass/deploy" "$temporary/pass/preparation" "$public_key_tool"
jq -e '.activation_authorized == false and (.images | keys) == ["node","tmkms"]' "$temporary/pass/preparation/recreated.json" >/dev/null
if grep -Eq '(^| )(start|up|pull)( |$)' "$temporary/docker-calls"; then
  # --pull never is an option, not a pull operation.
  if grep -Eq '(^| )(start|up)( |$)|^pull ' "$temporary/docker-calls"; then exit 1; fi
fi
if grep -R -q DO_NOT_RETAIN_SECRET "$temporary/pass/preparation"; then
  echo 'FAIL Docker environment retained' >&2; exit 1
fi
echo 'PASS Bash recreation pins existing image IDs and leaves consensus stopped without retaining environment'
docker() {
  printf '%s\n' "$*" >>"$temporary/activation-docker-calls"
  case "$1" in
    inspect)
      local running=false
      [[ ! -e "$temporary/started" ]] || running=true
      jq -n --arg image "$image_id" --argjson running "$running" '
        ["node","tmkms"] | map({Image:$image,State:{Running:$running},
          HostConfig:{RestartPolicy:{Name:"no"}},Config:{Labels:{"com.docker.compose.service":.}}})' ;;
    compose) printf '%012d\n' 1 2 ;;
    start) touch "$temporary/started" ;;
    stop) rm -f "$temporary/started" ;;
    *) return 1 ;;
  esac
}
jq --argjson now "$(date +%s)" '. + {kind:"gdc-consensus-recovery-activation",activation_authorized:true,
  exclusive_signer_confirmed:true,checkpoint_height:"100",issued_at_unix:$now,expires_at_unix:($now+60)}' \
  "$temporary/pass/preparation/recreated.json" >"$temporary/authorization.json"
cp "$temporary/authorization.json" "$temporary/authorization-original.json"
for mutation in '.activation_authorized=false' '.exclusive_signer_confirmed=false' '.run_id="another"' \
  '.checkpoint_height="99"' '.expires_at_unix=0' '.consensus_pubkey="other"' '.images.node="other"'; do
  jq "$mutation" "$temporary/authorization-original.json" >"$temporary/authorization.json"
  if activate_consensus_recovery "$temporary/pass/deploy" "$temporary/pass/preparation" "$public_key_tool" "$temporary/authorization.json" >/dev/null 2>&1; then
    echo "FAIL accepted invalid activation: $mutation" >&2; exit 1
  fi
  [[ ! -e "$temporary/started" && ! -e "$temporary/pass/preparation/activation-claim" ]]
done
cp "$temporary/authorization-original.json" "$temporary/authorization.json"
activate_consensus_recovery "$temporary/pass/deploy" "$temporary/pass/preparation" "$public_key_tool" "$temporary/authorization.json"
[[ -e "$temporary/started" ]]
jq -e '.signing_verified == false and .restart_enabled == false' "$temporary/pass/preparation/started.json" >/dev/null
rm "$temporary/started"
if activate_consensus_recovery "$temporary/pass/deploy" "$temporary/pass/preparation" "$public_key_tool" "$temporary/authorization.json" >/dev/null 2>&1; then
  echo 'FAIL activation replay accepted' >&2; exit 1
fi
[[ ! -e "$temporary/started" ]]
echo 'PASS activation requires fresh exact-key authority and consumes it before start'

jq '.height="105" | .round="0" | .step=2' "$temporary/boundary" >"$temporary/pass/signer/tmkms/state/priv_validator_state.json"
jq 'map(. + {restart_policy:{Name:"unless-stopped",MaximumRetryCount:0}})' \
  "$temporary/pass/preparation/containers.json" >"$temporary/containers-final.json"
cp "$temporary/containers-final.json" "$temporary/pass/preparation/containers.json"
jq -n --arg key "$expected" '{verdict:"VALIDATING",consensus_pubkey:$key,epoch_transition_verified:true,
  signed_blocks:([101,102,103,104] | map({height:tostring,epoch:(if . < 104 then "1" else "2" end),
    consensus_pubkey:$key,signature_verified:true,voting_power:18}))}' >"$temporary/validation.json"
docker() {
  case "$1" in
    compose) printf '%012d\n' 1 2 ;;
    inspect)
      local services='["node","tmkms"]'
      if [[ $# == 2 ]]; then
        case "$2" in
          000000000001) services='["node"]' ;;
          000000000002) services='["tmkms"]' ;;
          *) return 1 ;;
        esac
      fi
      local policy=no
      [[ ! -f "$temporary/policies-updated" ]] || policy=unless-stopped
      jq -n --argjson services "$services" --arg image "$image_id" --arg policy "$policy" \
        '$services | map({Image:$image,State:{Running:true},Config:{Labels:{"com.docker.compose.service":.}},
          HostConfig:{RestartPolicy:{Name:$policy,MaximumRetryCount:0}}})' ;;
    update)
      [[ "$2" == --restart && "$3" == unless-stopped ]] || return 1
      printf '%s\n' "$4" >>"$temporary/policies-updated" ;;
    *) echo 'FAIL finalization tried to start or replace a container' >&2; return 1 ;;
  esac
}
cp "$temporary/validation.json" "$temporary/validation-original.json"
for mutation in '.verdict="ACTIVE"' '.consensus_pubkey="other"' '.signed_blocks[0].signature_verified=false' \
  '.signed_blocks[0].voting_power=0' '.signed_blocks[0].height="100"' '.signed_blocks[3].epoch="1"' \
  '.signed_blocks[0].epoch="2"'; do
  jq "$mutation" "$temporary/validation-original.json" >"$temporary/validation.json"
  if finalize_consensus_recovery "$temporary/pass/deploy" "$temporary/pass/preparation" "$public_key_tool" "$temporary/validation.json" >/dev/null 2>&1; then
    echo "FAIL restored restart policy without complete proof: $mutation" >&2; exit 1
  fi
  [[ ! -e "$temporary/policies-updated" ]]
done
cp "$temporary/validation-original.json" "$temporary/validation.json"
finalize_consensus_recovery "$temporary/pass/deploy" "$temporary/pass/preparation" "$public_key_tool" "$temporary/validation.json"
[[ "$(wc -l <"$temporary/policies-updated")" -eq 2 ]]
finalize_consensus_recovery "$temporary/pass/deploy" "$temporary/pass/preparation" "$public_key_tool" "$temporary/validation.json"
[[ "$(wc -l <"$temporary/policies-updated")" -eq 4 ]]
echo 'PASS restart policies are restored only after VALIDATING and repeated finalization does not restart containers'
