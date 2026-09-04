#!/usr/bin/env bash
# Prove that a successful --plan compiles only local evidence and never
# reaches the remote deployment tools.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bootstrap.json" <<'EOF'
{"$schema":"https://gonka-dev.net/v1.bootstrap.schema.json","chain_id":"gonka-devnet-community","genesis":{"sha256":"93c32ec403d59af6337c0d79c3ee16010c99394f8ecd9aee4fc72a898f64a9a6"},"seeds":[{"node_id":"0123456789abcdef0123456789abcdef01234567","rpc":"https://node0.example.test/chain-rpc","p2p":"tcp://node0.example.test:5000","api":"https://node0.example.test"},{"node_id":"89abcdef0123456789abcdef0123456789abcdef","rpc":"https://node1.example.test/chain-rpc","p2p":"tcp://node1.example.test:5000","api":"https://node1.example.test"}],"brokers":[]}
EOF

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
headers='' output='' url='' write_remote=false
while (($#)); do
  case "$1" in
    -D) headers="${2:-}"; shift 2 ;;
    -o|-H|--connect-timeout|--max-time) [[ "$1" == -o ]] && output="${2:-}"; shift 2 ;;
    --write-out) write_remote=true; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
emit() { if [[ -n "$output" ]]; then printf '%s\n' "$1" >"$output"; else printf '%s\n' "$1"; fi; }
case "$url" in
  *node0.example.test*|*node1.example.test*)
    id=0123456789abcdef0123456789abcdef01234567
    remote_ip=8.8.4.1
    if [[ "$url" == *node1.example.test* ]]; then
      id=89abcdef0123456789abcdef0123456789abcdef
      remote_ip=8.8.4.2
    fi
    case "$url" in
      */status) emit "{\"result\":{\"node_info\":{\"id\":\"$id\",\"network\":\"gonka-devnet-community\",\"version\":\"0.2.15\"},\"sync_info\":{\"catching_up\":false}}}" ;;
      */abci_info) emit '{"result":{"response":{"version":"0.2.15"}}}' ;;
      */net_info) emit '{"result":{"peers":[]}}' ;;
      */v1/versions) emit '{"node_version":{"application_name":"inference-chain","version":"0.2.15","commit":"4d687ed6782bcea3931d2d9135bf322f84e190ab"},"api_version":{"application_name":"decentralized-api","version":"0.2.16","commit":"18506d42c510e0cafe6acd748bcd8d83036cba40"}}' ;;
      *) exit 22 ;;
    esac
    if [[ "$write_remote" == true ]]; then
      printf '\n__GDC_REMOTE_IP__=%s\n' "$remote_ip"
    fi
    ;;
  *raw.githubusercontent.com/gonka-ai/gonka/ce33c851282b8f4c0f63d78d46ddd4d8bb248207/deploy/join/docker-compose.yml)
    emit $'services:\n  node:\n    image: ghcr.io/product-science/inferenced:0.2.15\n  api:\n    image: ghcr.io/product-science/api:0.2.15-post3'
    ;;
  *'/releases/tags/release%2Fv0.2.15') emit '{"tag_name":"release/v0.2.15","assets":[{"name":"inferenced-linux-amd64.zip","browser_download_url":"https://github.com/gonka-ai/gonka/releases/download/release/v0.2.15/inferenced-linux-amd64.zip","digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111"}]}' ;;
  *'/releases/tags/release%2Fv0.2.16') emit '{"tag_name":"release/v0.2.16","assets":[{"name":"decentralized-api-amd64.zip","browser_download_url":"https://github.com/gonka-ai/gonka/releases/download/release/v0.2.16/decentralized-api-amd64.zip","digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222"}]}' ;;
  *'/git/matching-refs/tags/release/v0.2.15') emit '[{"ref":"refs/tags/release/v0.2.15","object":{"type":"commit","sha":"4d687ed6782bcea3931d2d9135bf322f84e190ab"}}]' ;;
  *'/git/matching-refs/tags/release/v0.2.16') emit '[{"ref":"refs/tags/release/v0.2.16","object":{"type":"commit","sha":"18506d42c510e0cafe6acd748bcd8d83036cba40"}}]' ;;
  *'ghcr.io/token?'*) emit '{"token":"fixture-token"}' ;;
  *'ghcr.io/v2/'*'/manifests/'*)
    [[ -n "$headers" ]] || exit 2
    printf 'HTTP/2 200\r\nDocker-Content-Digest: sha256:3333333333333333333333333333333333333333333333333333333333333333\r\n' >"$headers"
    ;;
  *) exit 22 ;;
esac
EOF

cat >"$tmp/bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == *host-stack-compose.yml ]]; then
  printf '%s  %s\n' d4b17a18013160236b79aac880a9f5b17705312f45c85ea3d37cc978c8da3f94 "$1"
else
  /usr/bin/sha256sum "$@"
fi
EOF

for tool in ssh scp rsync docker docker-compose; do
  cat >"$tmp/bin/$tool" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${0##*/}" >>"$GDC_PLAN_REMOTE_EFFECT_LOG"
exit 97
EOF
done
chmod 0755 "$tmp/bin"/*

printf 'retained validator archive\n' >"$tmp/validator-backup.tar"
: >"$tmp/remote-effects.log"
PATH="$tmp/bin:$PATH" GDC_PLAN_REMOTE_EFFECT_LOG="$tmp/remote-effects.log" GDC_HOME="$tmp/operator" \
  "$ROOT/gdc.sh" host join --plan --bootstrap-file "$tmp/bootstrap.json" --restore "$tmp/validator-backup.tar" \
    --skip-qualification --public-host validator-a.example.test validator-a >"$tmp/out" 2>"$tmp/err"

[[ ! -s "$tmp/remote-effects.log" ]]
! find "$tmp/operator" -type d -name genesis -print -quit | grep -q .
profile="$(find "$tmp/operator" -type f -path '*/join-validator-a/join-profile.v1.json' -print -quit)"
observation="$(find "$tmp/operator" -type f -path '*/join-validator-a/network-observation.v1.json' -print -quit)"
receipt="$(find "$tmp/operator" -type f -path '*/join-validator-a/preflight-receipt.env' -print -quit)"
result="$(find "$tmp/operator" -type f -path '*/join-validator-a/join-result.v1.json' -print -quit)"
[[ -n "$profile" && -n "$observation" && -n "$receipt" && -n "$result" ]]
[[ "$(stat -c %a "$profile")" == 600 && "$(stat -c %a "$result")" == 600 ]]
[[ ! -e "$tmp/operator/validator-a/state/active-run-id" ]] || { echo '--plan unexpectedly became the active JOIN run' >&2; exit 1; }
"$ROOT/scripts/join-profile.sh" validate "$profile"
jq -e '.operation == "restore" and .spec.identity.mode == "restore"' "$profile" >/dev/null
jq -e '.outcome == "no_op" and .phase == "profile" and .mutation == "none" and .signer_state == "absent" and .reason == "plan_completed"' "$result" >/dev/null
grep -Fq "profile=$profile" "$tmp/out"
grep -Fq "result=$result" "$tmp/out"

run_dir="$(dirname "$profile")"
run_id="$(basename "$(dirname "$run_dir")")"
profile_sha256="$(sha256sum "$profile" | awk '{print $1}')"
observation_sha256="$(sha256sum "$observation" | awk '{print $1}')"

# A normal repeated command is permitted to stop before lineage, installation
# or deployment only when a prior receipt chain is COMPLETE and the freshly
# observed executable profile is byte-for-byte the same semantic profile.
completed_id=completed-join
completed_run="$tmp/operator/validator-a/runs/$completed_id/join-validator-a"
mkdir -p "$completed_run/receipts"
install -m 0600 "$profile" "$completed_run/join-profile.v1.json"
install -m 0600 "$observation" "$completed_run/network-observation.v1.json"
completed_profile_sha256="$(sha256sum "$completed_run/join-profile.v1.json" | awk '{print $1}')"
jq -cn --arg run_id "$completed_id" --arg profile "$completed_profile_sha256" --arg observation "$observation_sha256" '
  {schema_version:2,kind:"gdc-host-join-receipt",run_id:$run_id,operation:"restore",node_name:"validator-a",state:"COMPLETE",join_profile_sha256:$profile,network_observation_sha256:$observation,generation_id:$run_id,identity_fingerprints:{participant_address:"gonka1fixtureparticipant",consensus_pubkey:"fixture-consensus-key",p2p_node_id:"0123456789abcdef0123456789abcdef01234567",warm_address:"gonka1fixturewarm"},signer_ever_started:true,tmkms_state:{height:42,round:0,step:0,block_id:""},evidence:[{kind:"join_profile",sha256:$profile},{kind:"network_observation",sha256:$observation}],outcome:"succeeded",resume_policy:"resume_same_run"}
' >"$tmp/completed-receipt.json"
"$ROOT/scripts/record-join-receipt.sh" --receipt-dir "$completed_run/receipts" --input "$tmp/completed-receipt.json" >/dev/null
jq -cn --arg profile "$completed_profile_sha256" '
  {schema_version:1,kind:"gdc-host-join-result",outcome:"succeeded",phase:"acceptance",category:"internal",reason:"join_complete",exit_code:0,mutation:"signer_may_be_on",signer_state:"enabled",resume:"resume_same_run",join_profile_sha256:$profile,evidence:[]}
' >"$tmp/completed-result.json"
"$ROOT/scripts/record-join-result.sh" --output "$completed_run/join-result.v1.json" --input "$tmp/completed-result.json" >/dev/null
printf '%s\n' "$completed_id" >"$tmp/operator/validator-a/state/active-run-id"
cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$GDC_PLAN_REMOTE_EFFECT_LOG"
exit 0
EOF
chmod 0755 "$tmp/bin/ssh"
: >"$tmp/remote-effects.log"
if ! PATH="$tmp/bin:$PATH" GDC_PLAN_REMOTE_EFFECT_LOG="$tmp/remote-effects.log" GDC_HOME="$tmp/operator" \
  "$ROOT/gdc.sh" host join --bootstrap-file "$tmp/bootstrap.json" --restore "$tmp/validator-backup.tar" \
    --skip-qualification --public-host validator-a.example.test validator-a >"$tmp/reentry.out" 2>"$tmp/reentry.err"; then
  cat "$tmp/reentry.out" "$tmp/reentry.err" >&2
  exit 1
fi
grep -Fq 'PASS Host JOIN is already complete with the current immutable profile; no Host mutation was performed' "$tmp/reentry.out"
[[ -s "$tmp/remote-effects.log" ]]
! grep -Eq 'start-node|install-node|rsync|scp' "$tmp/remote-effects.log"
: >"$tmp/remote-effects.log"

mkdir -m 0700 "$run_dir/receipts"
jq -cn --arg run_id "$run_id" --arg profile "$profile_sha256" --arg observation "$observation_sha256" '
  {schema_version:2,kind:"gdc-host-join-receipt",run_id:$run_id,operation:"restore",node_name:"validator-a",state:"CANDIDATE_RENDERED",join_profile_sha256:$profile,network_observation_sha256:$observation,generation_id:$run_id,identity_fingerprints:{participant_address:"",consensus_pubkey:"",p2p_node_id:"",warm_address:""},signer_ever_started:false,tmkms_state:{height:0,round:0,step:0,block_id:""},evidence:[{kind:"join_profile",sha256:$profile},{kind:"network_observation",sha256:$observation}],outcome:"in_progress",resume_policy:"resume_same_run"}' >"$tmp/resume-receipt.json"
"$ROOT/scripts/record-join-receipt.sh" --receipt-dir "$run_dir/receipts" --input "$tmp/resume-receipt.json" >/dev/null
PATH="$tmp/bin:$PATH" GDC_PLAN_REMOTE_EFFECT_LOG="$tmp/remote-effects.log" GDC_HOME="$tmp/operator" \
  "$ROOT/gdc.sh" host join --plan --resume "$run_id" --public-host validator-a.example.test validator-a >"$tmp/resume.out" 2>"$tmp/resume.err"
[[ ! -s "$tmp/remote-effects.log" ]]
grep -Fq "PASS Host JOIN resume plan verified run_id=$run_id; no Host action was performed" "$tmp/resume.out"

# Incomplete receipts are not generic retries.  The only former mutating
# signer-resume dispatcher accepted an operator-authored fence, so the CLI
# must now fail closed without connecting to the Host.
: >"$tmp/remote-effects.log"
if PATH="$tmp/bin:$PATH" GDC_PLAN_REMOTE_EFFECT_LOG="$tmp/remote-effects.log" GDC_HOME="$tmp/operator" \
  "$ROOT/gdc.sh" host join --resume "$run_id" --public-host validator-a.example.test validator-a >"$tmp/unsupported-resume.out" 2>"$tmp/unsupported-resume.err"; then
  echo 'unsupported partial JOIN unexpectedly dispatched a mutating resume' >&2; exit 1
fi
grep -Fq 'has no safe dispatcher for retained state=CANDIDATE_RENDERED' "$tmp/unsupported-resume.err"
[[ ! -s "$tmp/remote-effects.log" ]]

jq '.spec.target.public_host = "tampered.example.test"' "$profile" >"$tmp/tampered-profile.json"
chmod 600 "$tmp/tampered-profile.json"
mv "$tmp/tampered-profile.json" "$profile"
if PATH="$tmp/bin:$PATH" GDC_PLAN_REMOTE_EFFECT_LOG="$tmp/remote-effects.log" GDC_HOME="$tmp/operator" \
  "$ROOT/gdc.sh" host join --plan --resume "$run_id" --public-host validator-a.example.test validator-a >"$tmp/tampered-resume.out" 2>"$tmp/tampered-resume.err"; then
  echo 'resume accepted a tampered retained profile' >&2; exit 1
fi
grep -Fq 'profile_id does not bind' "$tmp/tampered-resume.err"

printf 'PASS Host JOIN --plan creates a restore-bound local profile without remote effects\n'
