#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
unset GDC_ENV GDC_INTERNAL_DATA_ROOT GDC_RUN_ID GDC_JOIN_PROFILE GDC_JOIN_RESULT_OUTPUT
export GDC_HOME="$scratch/operator"

# Real comparison with a block larger than the Linux single-argument limit.
# SSH and status are closed local fixtures; no node is contacted.
for defect in none block-hash app-hash malformed; do
  rc=0
  bash -c '
    source "$1/scripts/recover-incident.sh"
    SOURCE_ALIAS=fixture-anchor
    status() { printf "{\"result\":{\"sync_info\":{\"catching_up\":false,\"latest_block_height\":\"306600\"}}}\n"; }
    ssh() {
      local target="${*: -2:1}"
      [[ "$target" == fixture-anchor || "$target" == fixture-peer ]] || exit 99
      if [[ "$target" == fixture-peer && "$defect" == malformed ]]; then printf "broken JSON\n"; return; fi
      jq -cn --arg target "$target" --arg defect "$defect" "
        {result:{block_id:{hash:((if \$target==\"fixture-peer\" and \$defect==\"block-hash\" then \"b\" else \"a\" end)*64)},
          block:{header:{app_hash:((if \$target==\"fixture-peer\" and \$defect==\"app-hash\" then \"d\" else \"c\" end)*64)},
            data:{txs:[\"x\"*1048576]}}}}"
    }
    defect="$2"
    same_chain fixture-peer
  ' bash "$ROOT" "$defect" >"$scratch/block-$defect.log" 2>&1 || rc=$?
  expected_rc=3; [[ "$defect" != none ]] || expected_rc=0
  if [[ "$rc" != "$expected_rc" ]]; then cat "$scratch/block-$defect.log" >&2; exit 1; fi
  ! grep -Fq 'Argument list too long' "$scratch/block-$defect.log"
done
printf 'PASS large matching blocks compare over streams; mismatched and malformed blocks fail\n'

# Exercise the actual launcher with only its Host-mutating entry points
# replaced in a disposable copy. Arbitrary aliases are fixtures, not topology.
fixture="$scratch/runbook"
mkdir -p "$fixture"
cp "$ROOT/gdc.sh" "$fixture/gdc.sh"
cp -a "$ROOT/scripts" "$ROOT/profiles" "$fixture/"
cp -a "$ROOT/../model" "$fixture/../model"
# The launcher fixture replaces every Host-mutating phase.  Its resume tests
# exercise dispatcher selection, not profile-schema validation, so keep the
# manifest writer out of the synthetic phase path.
sed -i 's/ensure_run_manifest "[$]phase"/: # fixture manifest omitted/' "$fixture/gdc.sh"
cat >>"$fixture/scripts/profile.sh" <<'SH'
# The launcher fixture checks dispatch only; profile contents are exercised by
# the dedicated Join Profile tests.
load_join_profile() { GDC_JOIN_PROFILE="$1"; }
SH
for script in recover-incident phase-node host-peers; do
  cat >"$fixture/scripts/$script.sh" <<'SH'
#!/usr/bin/env bash
printf 'fixture operation completed\n'
if [[ "${*: -1}" == fixture-broken ]]; then exit 19; fi
exit "${GDC_RESULT_FIXTURE_RC:-0}"
SH
  chmod +x "$fixture/scripts/$script.sh"
done

assert_end() {
  local expected="$1" expected_rc="$2"; shift 2
  local rc=0
  GDC_HOME="$scratch/run-$RANDOM" bash "$fixture/gdc.sh" "$@" >"$scratch/result.log" 2>&1 || rc=$?
  [[ "$rc" == "$expected_rc" ]]
  [[ "$(tail -n 1 "$scratch/result.log")" == "$expected" ]]
  [[ "$(grep -Ec '^END (bootstrap|check|host (reset|peers|join)) ' "$scratch/result.log")" == 1 ]]
  if (( rc != 0 )); then ! grep -Eq '^END .* SUCCESS$' "$scratch/result.log"; fi
}
for rc in 0 19; do
  export GDC_RESULT_FIXTURE_RC="$rc"
  if (( rc == 0 )); then suffix=SUCCESS; else suffix="FAILED exit=$rc"; fi
  assert_end "END bootstrap $suffix" "$rc" network recover bootstrap fixture-anchor
  assert_end "END check $suffix" "$rc" network recover check fixture-anchor --hosts fixture-peer
  assert_end "END host peers $suffix" "$rc" host peers --pex true fixture-peer
  assert_end "END host reset $suffix" "$rc" host reset fixture-peer
done
unset GDC_RESULT_FIXTURE_RC
assert_end 'END host reset FAILED exit=19' 19 host reset fixture-peer fixture-broken
assert_end 'END host join FAILED exit=2' 2 host join --restore "$scratch/missing.tar" --public-host peer.example.test fixture-peer
printf 'PASS one final command result, preserved exit codes and no success for partial multi-host reset\n'

# Real JOIN resume dispatch, including its early no-op and read-only
# --preflight return. `--plan` remains an accepted compatibility spelling.
cat >"$fixture/scripts/verify-join-resume-inputs.sh" <<'SH'
#!/usr/bin/env bash
printf '{"operation":"new","receipt_chain":{"last_state":"COMPLETE"}}\n'
SH
for mode in resume plan; do
  home_dir="$scratch/join-$mode"
  mkdir -p "$home_dir/fixture-peer/runs/fixture-run/join-fixture-peer" "$home_dir/fixture-peer/state/role-inputs"
  printf '{}\n' >"$home_dir/fixture-peer/runs/fixture-run/join-fixture-peer/join-profile.v1.json"
  printf 'GDC_JOIN_ROLE_INPUT=true\n' >"$home_dir/fixture-peer/state/role-inputs/join-fixture-peer"
  printf '%s\n' "$home_dir/fixture-peer/state/role-inputs/join-fixture-peer" >"$home_dir/fixture-peer/state/active-role-config"
  args=(host join --resume fixture-run --public-host peer.example.test fixture-peer)
  expected='END host join SUCCESS'
  if [[ "$mode" == plan ]]; then args+=(--plan); expected='END host join PREFLIGHT SUCCESS'; fi
  GDC_HOME="$home_dir" bash "$fixture/gdc.sh" "${args[@]}" >"$scratch/join-$mode.log" 2>&1
  [[ "$(tail -n 1 "$scratch/join-$mode.log")" == "$expected" ]]
  [[ "$(grep -c '^END host join ' "$scratch/join-$mode.log")" == 1 ]]
done
printf 'PASS completed JOIN resume has a final result; read-only preflight is explicitly labelled\n'

# A fresh JOIN may reach membership before a transient faucet response ends
# the phase.  Its receipt already proves registration and signer-off state;
# resume must select the dedicated continuation, not the restore-only path.
cat >"$fixture/scripts/verify-join-resume-inputs.sh" <<'SH'
#!/usr/bin/env bash
printf '{"operation":"new","receipt_chain":{"last_state":"MEMBERSHIP_RECONCILED","signer_ever_started":false}}\n'
SH
cat >"$fixture/scripts/phase-join-resume-membership.sh" <<'SH'
#!/usr/bin/env bash
[[ "$1" == fixture-peer && "$2" == "$GDC_HOME/runs/fixture-run/join-fixture-peer" ]]
printf 'fixture membership continuation completed\n'
SH
chmod +x "$fixture/scripts/verify-join-resume-inputs.sh" "$fixture/scripts/phase-join-resume-membership.sh"
home_dir="$scratch/join-membership"
mkdir -p "$home_dir/fixture-peer/runs/fixture-run/join-fixture-peer" "$home_dir/fixture-peer/state/role-inputs"
printf '{}\n' >"$home_dir/fixture-peer/runs/fixture-run/join-fixture-peer/join-profile.v1.json"
printf 'GDC_JOIN_ROLE_INPUT=true\n' >"$home_dir/fixture-peer/state/role-inputs/join-fixture-peer"
printf '%s\n' "$home_dir/fixture-peer/state/role-inputs/join-fixture-peer" >"$home_dir/fixture-peer/state/active-role-config"
if ! GDC_HOME="$home_dir" bash "$fixture/gdc.sh" host join --resume fixture-run --public-host peer.example.test fixture-peer >"$scratch/join-membership.log" 2>&1; then
  cat "$scratch/join-membership.log" >&2
  exit 1
fi
membership_log="$(<"$scratch/join-membership.log")"
[[ "$membership_log" == *'fixture membership continuation completed'* ]]
[[ "$(tail -n 1 "$scratch/join-membership.log")" == 'END host join SUCCESS' ]]
printf 'PASS fresh JOIN resumes from retained membership without rerunning registration or funding\n'

# A fresh JOIN that already has a promoted signerless application runtime
# resumes through its dedicated path. It must not select the restore-only
# validator-recovery continuation.
cat >"$fixture/scripts/verify-join-resume-inputs.sh" <<'SH'
#!/usr/bin/env bash
printf '{"operation":"new","receipt_chain":{"last_state":"APPLICATION_ACTIVE","signer_ever_started":false}}\n'
SH
cat >"$fixture/scripts/phase-join-resume-new-canonical.sh" <<'SH'
#!/usr/bin/env bash
[[ "$1" == fixture-peer && "$2" == "$GDC_HOME/runs/fixture-run/join-fixture-peer" ]]
printf 'fixture new canonical continuation completed\n'
SH
chmod +x "$fixture/scripts/verify-join-resume-inputs.sh" "$fixture/scripts/phase-join-resume-new-canonical.sh"
home_dir="$scratch/join-new-canonical"
mkdir -p "$home_dir/fixture-peer/runs/fixture-run/join-fixture-peer" "$home_dir/fixture-peer/state/role-inputs"
printf '{}\n' >"$home_dir/fixture-peer/runs/fixture-run/join-fixture-peer/join-profile.v1.json"
printf 'GDC_JOIN_ROLE_INPUT=true\n' >"$home_dir/fixture-peer/state/role-inputs/join-fixture-peer"
printf '%s\n' "$home_dir/fixture-peer/state/role-inputs/join-fixture-peer" >"$home_dir/fixture-peer/state/active-role-config"
if ! GDC_HOME="$home_dir" bash "$fixture/gdc.sh" host join --resume fixture-run --public-host peer.example.test fixture-peer >"$scratch/join-new-canonical.log" 2>&1; then
  cat "$scratch/join-new-canonical.log" >&2
  exit 1
fi
new_canonical_log="$(<"$scratch/join-new-canonical.log")"
[[ "$new_canonical_log" == *'fixture new canonical continuation completed'* ]]
[[ "$(tail -n 1 "$scratch/join-new-canonical.log")" == 'END host join SUCCESS' ]]
printf 'PASS fresh JOIN resumes its signerless canonical state through the new-operation dispatcher\n'

# A run that reached CANARY_CAUGHT_UP must dispatch only its receipt-bound
# signerless continuation. This launcher fixture replaces that phase, so it
# cannot contact a Host while still proving the operation and retained run
# arguments reach the correct dispatcher.
cat >"$fixture/scripts/verify-join-resume-inputs.sh" <<'SH'
#!/usr/bin/env bash
printf '{"operation":"new","receipt_chain":{"last_state":"CANARY_CAUGHT_UP","signer_ever_started":false}}\n'
SH
cat >"$fixture/scripts/phase-join-resume-caught-up-canary.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == fixture-peer && "$2" == "$GDC_HOME/runs/fixture-run/join-fixture-peer" && "$3" == new ]]
printf 'fixture caught-up canary continuation completed\n'
SH
chmod +x "$fixture/scripts/verify-join-resume-inputs.sh" "$fixture/scripts/phase-join-resume-caught-up-canary.sh"
home_dir="$scratch/join-caught-up"
mkdir -p "$home_dir/fixture-peer/runs/fixture-run/join-fixture-peer" "$home_dir/fixture-peer/state/role-inputs"
printf '{}\n' >"$home_dir/fixture-peer/runs/fixture-run/join-fixture-peer/join-profile.v1.json"
printf 'GDC_JOIN_ROLE_INPUT=true\n' >"$home_dir/fixture-peer/state/role-inputs/join-fixture-peer"
printf '%s\n' "$home_dir/fixture-peer/state/role-inputs/join-fixture-peer" >"$home_dir/fixture-peer/state/active-role-config"
if ! GDC_HOME="$home_dir" bash "$fixture/gdc.sh" host join --resume fixture-run --public-host peer.example.test fixture-peer >"$scratch/join-caught-up.log" 2>&1; then
  cat "$scratch/join-caught-up.log" >&2
  exit 1
fi
caught_up_log="$(<"$scratch/join-caught-up.log")"
[[ "$caught_up_log" == *'fixture caught-up canary continuation completed'* ]]
[[ "$(tail -n 1 "$scratch/join-caught-up.log")" == 'END host join SUCCESS' ]]
printf 'PASS caught-up canary resume reaches its receipt-bound signerless continuation\n'

# Test the real phase wrapper and real terminal-result writer call. Only the
# external phase and receipt-writing script are mocked. A receipt failure
# after a successful phase must change both phase END and command END to fail.
cat >"$fixture/scripts/record-join-result.sh" <<'SH'
#!/usr/bin/env bash
printf 'fixture terminal receipt write attempted\n' >&2
exit "${GDC_RESULT_FIXTURE_RC:-0}"
SH
for expected_rc in 0 70; do
  rc=0
  GDC_HOME="$scratch/receipt-$expected_rc" GDC_RESULT_FIXTURE_RC="$expected_rc" bash -c '
    source "$1/gdc.sh" help >/dev/null
    GDC_END_COMMAND="host join"
    ensure_run_manifest() { :; }
    GDC_JOIN_RESULT_OUTPUT="$GDC_HOME/result.json"
    run_phase join-fixture-peer true
  ' bash "$fixture" >"$scratch/receipt-$expected_rc.log" 2>&1 || rc=$?
  [[ "$rc" == "$expected_rc" ]]
  grep -Fq "END phase=join-fixture-peer status=$expected_rc" "$scratch/receipt-$expected_rc.log"
  [[ "$(grep -c '^END host join ' "$scratch/receipt-$expected_rc.log")" == 1 ]]
  if (( rc == 0 )); then
    [[ "$(tail -n 1 "$scratch/receipt-$expected_rc.log")" == 'END host join SUCCESS' ]]
  else
    [[ "$(tail -n 1 "$scratch/receipt-$expected_rc.log")" == 'END host join FAILED exit=70' ]]
    ! grep -Eq 'status=0|END .* SUCCESS$' "$scratch/receipt-$expected_rc.log"
  fi
  awk '/fixture terminal receipt write attempted/ {written=1} /^END phase=/ {if (!written) exit 1}' "$scratch/receipt-$expected_rc.log"
done
printf 'PASS phase and command success follow the terminal receipt; write failure returns 70\n'

# Monitoring publication runs after JOIN has retained its terminal result. The
# registry helper can be a tracked non-executable source file and can fail;
# neither condition may turn a completed JOIN into a failed command.
cat >"$fixture/scripts/register-join-monitoring-targets.sh" <<'SH'
#!/usr/bin/env bash
exit 126
SH
chmod 0644 "$fixture/scripts/register-join-monitoring-targets.sh"
rc=0
GDC_JOIN_MONITORING_REGISTRY_HOST=registry-fixture bash -c '
  source "$1/gdc.sh" help >/dev/null
  publish_completed_join_monitoring fixture-peer peer.example.test
' bash "$fixture" >"$scratch/monitoring-after-join.log" 2>&1 || rc=$?
[[ "$rc" == 0 ]]
[[ "$(<"$scratch/monitoring-after-join.log")" == 'WARN monitoring target registration failed after fixture-peer JOIN completed; retry it separately when the registry is reachable' ]]
printf 'PASS failed non-executable monitoring publication preserves completed JOIN outcome\n'

# A reboot-required setup phase must reach run_phase post-processing. It
# retains its non-zero continuation code but is not rendered as a command failure.
rc=0
GDC_HOME="$scratch/phase-failure" GDC_RESULT_FIXTURE_RC=0 bash -c '
  source "$1/gdc.sh" help >/dev/null
  GDC_END_COMMAND="host setup"
  ensure_run_manifest() { :; }
  GDC_JOIN_RESULT_OUTPUT="$GDC_HOME/result.json"
  run_phase join-fixture-peer bash -c "exit 194"
' bash "$fixture" >"$scratch/phase-failure.log" 2>&1 || rc=$?
[[ "$rc" == 194 ]]
grep -Fq 'fixture terminal receipt write attempted' "$scratch/phase-failure.log"
grep -Fq 'END phase=join-fixture-peer status=194' "$scratch/phase-failure.log"
! grep -Fq 'ERROR gdc command failed' "$scratch/phase-failure.log"
reboot_log="$(<"$scratch/phase-failure.log")"
[[ "$reboot_log" == *'REBOOT REQUIRED: reboot the prepared Host, then rerun the same command'* ]]
[[ "$reboot_log" != *'Hint: review the retained local failure'* ]]
[[ "$(tail -n 1 "$scratch/phase-failure.log")" == 'END host setup REBOOT_REQUIRED exit=194' ]]
printf 'PASS reboot-required setup records one typed terminal result before launcher exit\n'

# A Host readiness stop is distinct from a failed JOIN: no identity exists,
# and the operator receives a specific remedy plus a reportable typed result.
action_home="$scratch/prepare-action-required"
mkdir -p "$action_home"
action_result="$action_home/join-result.v1.json"
jq -cn '
  {schema_version:1,kind:"gdc-host-join-result",outcome:"failed",phase:"staging",category:"host",
   reason:"host_prepare_operator_action_required",exit_code:195,mutation:"staging_only",signer_state:"disabled",
   resume:"new_profile",join_profile_sha256:null,evidence:[]}
' >"$action_result"
rc=0
GDC_HOME="$action_home" bash -c '
  source "$1/gdc.sh" help >/dev/null
  GDC_END_COMMAND="host join"
  GDC_JOIN_RESULT_OUTPUT="$2"
  bash -c "exit 195"
' bash "$fixture" "$action_result" >"$scratch/prepare-action-required.log" 2>&1 || rc=$?
[[ "$rc" == 195 ]]
[[ "$(<"$scratch/prepare-action-required.log")" == 'JOIN cannot continue because the Host needs operator action; resolve the stated prerequisite and rerun the same command' ]]
printf 'PASS Host preparation action-required result is typed and does not claim a JOIN incident\n'

# A validator backup for a different signer is invalid operator recovery input,
# not an operational incident. It must retain the typed refusal, avoid the
# generic failure/report wording, and preserve the data-error exit code.
restore_refusal_home="$scratch/restore-input-refusal"
mkdir -p "$restore_refusal_home"
restore_refusal_result="$restore_refusal_home/join-result.v1.json"
jq -cn '
  {schema_version:1,kind:"gdc-host-join-result",outcome:"refused",phase:"identity",category:"identity",
   reason:"restore_identity_mismatch",exit_code:65,mutation:"canonical_signer_off",signer_state:"disabled",
   resume:"new_profile",join_profile_sha256:null,evidence:[]}
' >"$restore_refusal_result"
rc=0
GDC_HOME="$restore_refusal_home" bash -c '
  source "$1/gdc.sh" help >/dev/null
  GDC_END_COMMAND="host join"
  GDC_JOIN_RESULT_OUTPUT="$2"
  bash -c "exit 65"
' bash "$fixture" "$restore_refusal_result" >"$scratch/restore-input-refusal.log" 2>&1 || rc=$?
[[ "$rc" == 65 ]]
grep -Fq 'REFUSED restored validator backup does not match the signer captured by reset;' "$scratch/restore-input-refusal.log"
! grep -Fq 'ERROR gdc command failed' "$scratch/restore-input-refusal.log"
! grep -Fq 'gdc report github' "$scratch/restore-input-refusal.log"
[[ "$(tail -n 1 "$scratch/restore-input-refusal.log")" == 'END host join REFUSED exit=65' ]]
printf 'PASS mismatched restore input is a typed refusal, not a reportable operational failure\n'

# `host setup ... add mlnode DONOR` is the short validator-lending form. The
# launcher must preserve its empty endpoint for safe phase-side discovery;
# the explicit endpoint remains an override. Exercise the actual parser and
# phase wrapper rather than asserting usage text.
cat >"$fixture/scripts/phase-ml-add.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$#" == 3 && "$1" == parent && "$3" == donor ]]
printf 'phase-called\n' >>"${GDC_TEST_PHASE_LOG:?}"
printf 'fixture ml add endpoint=%s donor=%s\n' "${2:-empty}" "$3"
SH
chmod +x "$fixture/scripts/phase-ml-add.sh"
ml_home="$scratch/ml-setup"
mkdir -p "$ml_home"
ml_phase_log="$scratch/ml-setup-phase.log"
: >"$ml_phase_log"
cat >"$ml_home/.env" <<'ENV'
GDC_NODE_ALIASES="parent donor"
GDC_NODE_PUBLIC_HOSTS="parent=127.0.0.1 donor=127.0.0.1"
GDC_NODE_P2P_PORTS="parent=5000 donor=5001"
ENV
for variant in discovered explicit; do
  if [[ "$variant" == discovered ]]; then
    args=(host setup parent add mlnode donor)
    expected='fixture ml add endpoint=empty donor=donor'
  else
    args=(host setup parent add mlnode --mlnode-peer gpu.example.test donor)
    expected='fixture ml add endpoint=gpu.example.test donor=donor'
  fi
  if ! GDC_HOME="$ml_home" GDC_TEST_PHASE_LOG="$ml_phase_log" bash "$fixture/gdc.sh" "${args[@]}" >"$scratch/ml-$variant.log" 2>&1; then
    cat "$scratch/ml-$variant.log" >&2
    exit 1
  fi
  ml_log="$(<"$scratch/ml-$variant.log")"
  [[ "$ml_log" == *"$expected"* ]]
  [[ "${ml_log##*$'\n'}" == 'END host setup SUCCESS' ]]
done
rc=0
GDC_HOME="$ml_home" GDC_TEST_PHASE_LOG="$ml_phase_log" bash "$fixture/gdc.sh" host setup parent add mlnode parent >"$scratch/ml-self-attach.log" 2>&1 || rc=$?
[[ "$rc" == 2 ]]
[[ "$(<"$scratch/ml-self-attach.log")" == 'host setup cannot attach a Network Node to itself' ]]
[[ "$(wc -l <"$ml_phase_log")" == 2 ]]
printf 'PASS validator ML setup preserves discovery and explicit endpoint inputs through the launcher\n'

# An ambiguous target ownership state is an operator-action refusal. The
# launcher must not turn that expected no-mutation result into a reportable
# failure or print a generic FAILED terminal line.
cat >"$fixture/scripts/phase-ml-add.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'OPERATOR ACTION REQUIRED cannot safely classify donor as a validator or ML-only Host; leave it unchanged and resolve its retained identity state before retrying' >&2
exit 195
SH
chmod +x "$fixture/scripts/phase-ml-add.sh"
rc=0
GDC_HOME="$ml_home" bash "$fixture/gdc.sh" host setup parent add mlnode donor >"$scratch/ml-add-ownership.log" 2>&1 || rc=$?
[[ "$rc" == 195 ]]
ml_add_log="$(<"$scratch/ml-add-ownership.log")"
[[ "$ml_add_log" == *'OPERATOR ACTION REQUIRED cannot safely classify donor as a validator or ML-only Host; leave it unchanged and resolve its retained identity state before retrying'* ]]
[[ "$ml_add_log" != *'ERROR gdc command failed'* ]]
[[ "$ml_add_log" != *'gdc report github'* ]]
[[ "$ml_add_log" != *'END host setup '* ]]
printf 'PASS ambiguous ML ownership is an actionable setup refusal, not a reportable failure\n'

# Removing an ML-only Host is destructive. If the target is a validator lent
# to the parent, the phase must return the dedicated ownership refusal and the
# launcher must not create a reportable failure envelope or generic FAILED end.
cat >"$fixture/scripts/phase-ml-remove.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'OPERATOR ACTION REQUIRED donor is a lent validator; run gdc host start donor to detach it and restore its validator services' >&2
exit 195
SH
chmod +x "$fixture/scripts/phase-ml-remove.sh"
rc=0
GDC_HOME="$ml_home" bash "$fixture/gdc.sh" host setup parent remove mlnode donor >"$scratch/ml-remove-lent.log" 2>&1 || rc=$?
[[ "$rc" == 195 ]]
ml_remove_log="$(<"$scratch/ml-remove-lent.log")"
[[ "$ml_remove_log" == *'OPERATOR ACTION REQUIRED donor is a lent validator; run gdc host start donor to detach it and restore its validator services'* ]]
[[ "$ml_remove_log" != *'ERROR gdc command failed'* ]]
[[ "$ml_remove_log" != *'gdc report github'* ]]
[[ "$ml_remove_log" != *'END host setup '* ]]
printf 'PASS lent-validator removal is an actionable ownership refusal, not a reportable setup failure\n'

# A timed-out parent detach is a normal operator continuation point: the donor
# must remain stopped, and `host start` must not turn it into an incident or a
# generic FAILED result. Exercise the real command alias and launcher traps.
cat >"$fixture/scripts/phase-node-lent-start.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'OPERATOR ACTION REQUIRED parent did not confirm removal of donor; leave the donor stopped and rerun gdc host start donor after parent DAPI readback succeeds' >&2
exit 195
SH
cat >"$fixture/scripts/read-lent-ml-record.sh" <<'SH'
#!/usr/bin/env bash
# The dedicated lending fixtures validate retained-record parsing. This command
# result fixture needs a confirmed ordinary-start preflight before it exercises
# the typed phase outcome.
exit 10
SH
chmod +x "$fixture/scripts/phase-node-lent-start.sh" "$fixture/scripts/read-lent-ml-record.sh"
start_home="$scratch/lent-start-action-required"
rc=0
GDC_HOME="$start_home" bash "$fixture/gdc.sh" host start donor >"$scratch/lent-start-action-required.log" 2>&1 || rc=$?
[[ "$rc" == 195 ]]
lent_start_log="$(<"$scratch/lent-start-action-required.log")"
[[ "$lent_start_log" == *'OPERATOR ACTION REQUIRED parent did not confirm removal of donor; leave the donor stopped and rerun gdc host start donor after parent DAPI readback succeeds'* ]]
[[ "$lent_start_log" != *'ERROR gdc command failed'* ]]
[[ "$lent_start_log" != *'gdc report github'* ]]
[[ "$lent_start_log" != *'END host start '* ]]
printf 'PASS uncertain ML release is an actionable host-start refusal, not a reportable failure\n'
