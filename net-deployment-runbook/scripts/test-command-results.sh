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

# Real JOIN resume dispatch, including its early no-op and --plan returns.
cat >"$fixture/scripts/verify-join-resume-inputs.sh" <<'SH'
#!/usr/bin/env bash
printf '{"receipt_chain":{"last_state":"COMPLETE"}}\n'
SH
for mode in resume plan; do
  home_dir="$scratch/join-$mode"
  mkdir -p "$home_dir/fixture-peer/runs/fixture-run/join-fixture-peer"
  printf '{}\n' >"$home_dir/fixture-peer/runs/fixture-run/join-fixture-peer/join-profile.v1.json"
  args=(host join --resume fixture-run --public-host peer.example.test fixture-peer)
  expected='END host join SUCCESS'
  if [[ "$mode" == plan ]]; then args+=(--plan); expected='END host join PLAN SUCCESS'; fi
  GDC_HOME="$home_dir" bash "$fixture/gdc.sh" "${args[@]}" >"$scratch/join-$mode.log" 2>&1
  [[ "$(tail -n 1 "$scratch/join-$mode.log")" == "$expected" ]]
  [[ "$(grep -c '^END host join ' "$scratch/join-$mode.log")" == 1 ]]
done
printf 'PASS completed JOIN resume has a final result; plan success is explicitly labelled PLAN\n'

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
