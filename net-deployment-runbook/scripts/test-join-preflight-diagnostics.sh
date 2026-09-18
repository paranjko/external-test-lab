#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/bootstrap.json" <<'EOF'
{"$schema":"https://gonka-dev.net/v1.bootstrap.schema.json","chain_id":"gonka-devnet-community","genesis":{"sha256":"93c32ec403d59af6337c0d79c3ee16010c99394f8ecd9aee4fc72a898f64a9a6"},"seeds":[{"node_id":"0123456789abcdef0123456789abcdef01234567","rpc":"https://node0.example.test/chain-rpc","p2p":"tcp://node0.example.test:5000","api":"https://node0.example.test"},{"node_id":"89abcdef0123456789abcdef0123456789abcdef","rpc":"https://node1.example.test/chain-rpc","p2p":"tcp://node1.example.test:5000","api":"https://node1.example.test"}],"brokers":[]}
EOF
mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${!#}"
mode="${MODE:-observation_failure}"
write_remote=false
for arg in "$@"; do
  [[ "$arg" == --write-out ]] && write_remote=true
done
attempt=0
if [[ "$mode" == wait_recovery && "$url" == *node0.example.test*/status ]]; then
  : "${OBSERVATION_ATTEMPT_FILE:?OBSERVATION_ATTEMPT_FILE is required for wait_recovery}"
  [[ -r "$OBSERVATION_ATTEMPT_FILE" ]] && attempt="$(<"$OBSERVATION_ATTEMPT_FILE")"
  attempt=$((attempt + 1))
  printf '%s\n' "$attempt" >"$OBSERVATION_ATTEMPT_FILE"
elif [[ "$mode" == wait_recovery && -r "${OBSERVATION_ATTEMPT_FILE:-}" ]]; then
  attempt="$(<"$OBSERVATION_ATTEMPT_FILE")"
fi
case "$url" in
  *'/releases/tags/release%2Fv0.2.15')
    printf '%s\n' '{"tag_name":"release/v0.2.15","assets":[{"name":"inferenced-amd64.zip","browser_download_url":"https://github.com/gonka-ai/gonka/releases/download/release/v0.2.15/inferenced-amd64.zip","digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111"}]}'
    exit 0
    ;;
  *'/git/matching-refs/tags/release/v0.2.15')
    printf '%s\n' '[{"ref":"refs/tags/release/v0.2.15","object":{"type":"commit","sha":"4d687ed6782bcea3931d2d9135bf322f84e190ab"}}]'
    exit 0
    ;;
  *'/releases/tags/release%2Fv0.2.16')
    [[ "$mode" == component_failure || "$mode" == wait_recovery ]] && exit 22
    exit 2
    ;;
  *node0.example.test*) id=0123456789abcdef0123456789abcdef01234567; remote_ip=8.8.4.1 ;;
  *node1.example.test*) id=89abcdef0123456789abcdef0123456789abcdef; remote_ip=8.8.4.2 ;;
  *) exit 2 ;;
esac
case "$url" in
  */status)
    version=0.2.14
    [[ "$mode" == component_failure || ( "$mode" == wait_recovery && "$attempt" -ge 2 ) ]] && version=0.2.15
    printf '{"result":{"node_info":{"id":"%s","network":"gonka-devnet-community","version":"%s"},"sync_info":{"catching_up":false}}}\n' "$id" "$version"
    ;;
  */abci_info)
    version=0.2.14
    [[ "$mode" == component_failure || ( "$mode" == wait_recovery && "$attempt" -ge 2 ) ]] && version=0.2.15
    printf '{"result":{"response":{"version":"%s"}}}\n' "$version"
    ;;
  */net_info)
    printf '%s\n' '{"result":{"peers":[]}}'
    ;;
  */v1/versions)
    if [[ "$mode" == component_failure || ( "$mode" == wait_recovery && "$attempt" -ge 2 ) ]]; then
      printf '%s\n' '{"node_version":{"application_name":"inference-chain","version":"0.2.15","commit":"4d687ed6782bcea3931d2d9135bf322f84e190ab"},"api_version":{"application_name":"decentralized-api","version":"0.2.16","commit":"18506d42c510e0cafe6acd748bcd8d83036cba40"}}'
    else
      printf '%s\n' '{"node_version":{"application_name":"inference-chain","version":"0.2.15","commit":"4d687ed6782bcea3931d2d9135bf322f84e190ab"},"api_version":{"application_name":"decentralized-api","version":"0.2.14-post3","commit":"5dbb53ddf3ddc42655fc04dc39d96003169bdbb0"}}'
    fi
    ;;
  *) exit 2 ;;
esac
if [[ "$write_remote" == true ]]; then
  printf '\n__GDC_REMOTE_IP__=%s\n' "$remote_ip"
fi
EOF
chmod 0755 "$tmp/bin/curl"

if GDC_JOIN_PREFLIGHT_DEADLINE=1 GDC_JOIN_PREFLIGHT_RETRY_SECONDS=1 PATH="$tmp/bin:$PATH" GDC_HOME="$tmp/operator" "$ROOT/gdc.sh" host join \
  --bootstrap-file "$tmp/bootstrap.json" --skip-qualification --public-host validator-a.example.test validator-a >"$tmp/out" 2>"$tmp/err"; then
  echo 'unsafe mixed seed observation unexpectedly entered JOIN' >&2
  exit 1
fi
grep -Fq 'network_observation_insufficient_quorum:' "$tmp/err"
grep -Fq 'network_observation_timeout:' "$tmp/err"
grep -Fq "preflight_receipt=$tmp/operator/gdc-node2/preflight-receipt.env" "$tmp/err" || \
  grep -Fq 'preflight_receipt=' "$tmp/err"
pointer="$tmp/operator/reporting/failures/latest-failure"
failure_id="$(<"$pointer")"
failure="$tmp/operator/reporting/invocations/invocation.$failure_id/failure.env"
grep -qx 'failure_stage=join-preflight' "$failure"
grep -qx 'active_phase=join-preflight' "$failure"
diagnostic="$(awk -F= '$1 == "diagnostic_envelope" { print $2; exit }' "$failure")"
[[ -n "$diagnostic" && -f "$diagnostic" && ! -L "$diagnostic" ]]
receipt="$(awk -F= '$1 == "preflight_receipt" { print $2; exit }' "$failure")"
[[ -n "$receipt" && -f "$receipt" && ! -L "$receipt" ]]
grep -qx 'checkpoint=software-observation' "$receipt"
grep -qx 'result=failed' "$receipt"
"$ROOT/scripts/diagnostic-envelope.sh" validate "$diagnostic"
jq -e '
  .command_family == "join" and .phase == "join-preflight" and
  .checkpoint == "software-observation" and .state == "unavailable" and
  .category == "network" and .tool == "seed-observer-timeout" and
  .resume.decision == "safe" and .resume.token == "join-repeat"
' "$diagnostic" >/dev/null
result="$(find "$tmp/operator" -type f -path '*/join-validator-a/join-result.v1.json' -print -quit)"
[[ -n "$result" && "$(stat -c %a "$result")" == 600 ]]
jq -e '
  .schema_version == 1 and .kind == "gdc-host-join-result" and
  .outcome == "refused" and .phase == "profile" and .category == "observation" and
  .reason == "join_preflight_failed" and .mutation == "none" and
  .signer_state == "absent" and .resume == "new_profile" and
  .join_profile_sha256 == null
' "$result" >/dev/null

attempt_counter="$tmp/observation-attempt-counter"
if MODE=wait_recovery OBSERVATION_ATTEMPT_FILE="$attempt_counter" \
  GDC_JOIN_PREFLIGHT_DEADLINE=5 GDC_JOIN_PREFLIGHT_RETRY_SECONDS=1 \
  PATH="$tmp/bin:$PATH" GDC_HOME="$tmp/recovered-operator" "$ROOT/gdc.sh" host join \
  --bootstrap-file "$tmp/bootstrap.json" --skip-qualification --public-host validator-b.example.test validator-b >"$tmp/recovered.out" 2>"$tmp/recovered.err"; then
  echo 'recovered observation unexpectedly resolved unavailable component metadata' >&2
  exit 1
fi
grep -Fq 'WAIT JOIN software observation stage=candidate-1 attempt=1 unavailable' "$tmp/recovered.err"
grep -Fq 'PASS JOIN software observation stable stage=candidate-1 attempts=3' "$tmp/recovered.out"
[[ "$(<"$attempt_counter")" == 3 ]]
recovered_receipt="$(find "$tmp/recovered-operator" -name preflight-receipt.env -type f -print -quit)"
[[ -n "$recovered_receipt" ]]
grep -qx 'checkpoint=component-resolution' "$recovered_receipt"
grep -qx 'software_observation_attempt_count=3' "$recovered_receipt"
recovered_attempts="$(awk -F= '$1 == "software_observation_attempts_dir" { print $2; exit }' "$recovered_receipt")"
[[ -f "$recovered_attempts/attempt-1.stderr" && -f "$recovered_attempts/attempt-2.json" && -f "$recovered_attempts/attempt-3.json" ]]

if MODE=component_failure GDC_JOIN_PREFLIGHT_DEADLINE=5 GDC_JOIN_PREFLIGHT_RETRY_SECONDS=1 \
  PATH="$tmp/bin:$PATH" GDC_HOME="$tmp/component-operator" "$ROOT/gdc.sh" host join \
  --bootstrap-file "$tmp/bootstrap.json" --skip-qualification --public-host validator-a.example.test validator-a >"$tmp/component.out" 2>"$tmp/component.err"; then
  echo 'missing official artifact unexpectedly entered JOIN' >&2
  exit 1
fi
component_pointer="$tmp/component-operator/reporting/failures/latest-failure"
component_id="$(<"$component_pointer")"
component_failure="$tmp/component-operator/reporting/invocations/invocation.$component_id/failure.env"
component_diagnostic="$(awk -F= '$1 == "diagnostic_envelope" { print $2; exit }' "$component_failure")"
component_receipt="$(awk -F= '$1 == "preflight_receipt" { print $2; exit }' "$component_failure")"
"$ROOT/scripts/diagnostic-envelope.sh" validate "$component_diagnostic"
grep -qx 'checkpoint=component-resolution' "$component_receipt"
grep -qx 'result=failed' "$component_receipt"
grep -qx 'category=dependency' "$component_receipt"
jq -e '
  .checkpoint == "component-resolution" and .state == "unavailable" and
  .category == "dependency" and .tool == "official-artifact-resolver" and
  .resume.decision == "safe" and .resume.token == "join-repeat"
' "$component_diagnostic" >/dev/null

printf 'PASS JOIN preflight retains a typed diagnostic before Host mutation\n'
