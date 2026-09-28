#!/usr/bin/env bash
# Drive the real launcher against fake externals and prove the whole refusal:
# a Host that already holds its identity and cold account, whose participant
# publishes a validator key its signer does not hold, is stopped before the
# Host is prepared, and the next JOIN can still classify it afresh.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"
cp "$ROOT/test/fixtures/mock-gh" "$tmp/bin/gh"
chmod 0755 "$tmp/bin/gh"

# The unavailable-response case exercises retry classification, not wall-clock
# delay. Keep this deterministic while the fixture is confined to this test.
cat >"$tmp/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$tmp/bin/sleep"

ALIAS=validator-a
PUBLIC_HOST=8.8.4.10
ADDRESS=gonka1fixturevalidatoraccount0000000000qq
# The participant contract accepts only a 32-byte consensus key. These two
# stand for the signer this Host holds and for a registration it cannot sign.
HOST_SIGNER_KEY="$(printf 'gdc-join-durable-tmkms-signer-fixture' | head -c 32 | base64 | tr -d '\n')"
FOREIGN_VALIDATOR_KEY="$(printf 'gdc-join-foreign-registered-key-fix' | head -c 32 | base64 | tr -d '\n')"

fail() { printf '%s\n' "$1" >&2; exit 1; }

printf '{"chain_id":"gonka-devnet-community","genesis_time":"2026-01-01T00:00:00Z","app_state":{}}\n' \
  >"$tmp/genesis.json"
genesis_sha256="$(sha256sum "$tmp/genesis.json" | awk '{print $1}')"
# Two seeds in two fault domains are the minimum the lineage preflight accepts.
jq -n --arg genesis "$genesis_sha256" '{
  "$schema":"https://gonka-dev.net/v1.bootstrap.schema.json",
  chain_id:"gonka-devnet-community",
  genesis:{sha256:$genesis},
  seeds:[
    {node_id:"0123456789abcdef0123456789abcdef01234567",rpc:"https://node0.example.test/chain-rpc",p2p:"tcp://node0.example.test:5000",api:"https://node0.example.test"},
    {node_id:"89abcdef0123456789abcdef0123456789abcdef",rpc:"https://node1.example.test/chain-rpc",p2p:"tcp://node1.example.test:5000",api:"https://node1.example.test"}
  ],
  brokers:[]
}' >"$tmp/bootstrap.json"

# JOIN stages Genesis through the CLI it pins from the observed release, so the
# fixture archive has to carry a binary that answers both of its questions.
mkdir -p "$tmp/inferenced-fixture"
cat >"$tmp/inferenced-fixture/inferenced" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  version) printf 'inferenced v0.2.15\n' ;;
  download-genesis) cp -- "${GDC_TEST_GENESIS_FIXTURE:?}" "${3:?}" ;;
  *) exit 64 ;;
esac
EOF
chmod 0755 "$tmp/inferenced-fixture/inferenced"
python3 - "$tmp/inferenced-fixture/inferenced" "$tmp/inferenced-linux-amd64.zip" <<'PY'
import sys
import zipfile

source, archive = sys.argv[1], sys.argv[2]
entry = zipfile.ZipInfo("inferenced", date_time=(2026, 1, 1, 0, 0, 0))
entry.external_attr = 0o100755 << 16
with open(source, "rb") as handle, zipfile.ZipFile(archive, "w") as bundle:
    bundle.writestr(entry, handle.read())
PY
FIXTURE_INFERENCED_ARCHIVE="$tmp/inferenced-linux-amd64.zip"
FIXTURE_INFERENCED_SHA256="$(sha256sum "$FIXTURE_INFERENCED_ARCHIVE" | awk '{print $1}')"

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
# The URL is not always the last argument, so collect it by shape instead of
# by position, and answer --write-out from the format the caller asked for.
output='' headers='' write_format='' url='' response_status=200
i=1
while (( i <= $# )); do
  case "${!i}" in
    -o|--output) i=$((i + 1)); output="${!i}" ;;
    -D|--dump-header) i=$((i + 1)); headers="${!i}" ;;
    -w|--write-out) i=$((i + 1)); write_format="${!i}" ;;
    -H|--connect-timeout|--max-time|--retry|--retry-delay|--resolve) i=$((i + 1)) ;;
    http://*|https://*) url="${!i}" ;;
  esac
  i=$((i + 1))
done
remote_ip=8.8.4.1
node_id=0123456789abcdef0123456789abcdef01234567
if [[ "$url" == *node1.example.test* ]]; then
  remote_ip=8.8.4.2
  node_id=89abcdef0123456789abcdef0123456789abcdef
fi
emit() { if [[ -n "$output" ]]; then printf '%s\n' "$1" >"$output"; else printf '%s\n' "$1"; fi; }
finish() {
  local rendered="$write_format"
  [[ -n "$rendered" ]] || return 0
  rendered="${rendered//'%{http_code}'/${1:-200}}"
  rendered="${rendered//'%{remote_ip}'/$remote_ip}"
  printf '%b' "$rendered"
}
block() {
  emit "$(printf '{"result":{"block_id":{"hash":"%064x"},"block":{"header":{"height":"%s","app_hash":"%064x"}}}}' \
    "$1" "$1" "$(( $1 + 1000000 ))")"
}
case "$url" in
  */inference/participant/*)
    if [[ -n "${GDC_TEST_PARTICIPANT_BODY:-}" ]]; then
      emit "$GDC_TEST_PARTICIPANT_BODY"
    else
      emit "$(printf '{"participant":{"address":"%s","validator_key":"%s","status":"ACTIVE"}}' \
        "${url##*/}" "${GDC_TEST_REGISTERED_VALIDATOR_KEY:?}")"
    fi
    response_status="${GDC_TEST_PARTICIPANT_HTTP_STATUS:-200}"
    ;;
  *'/releases/tags/release%2Fv0.2.15')
    emit "{\"tag_name\":\"release/v0.2.15\",\"assets\":[{\"name\":\"inferenced-linux-amd64.zip\",\"browser_download_url\":\"https://github.com/gonka-ai/gonka/releases/download/release/v0.2.15/inferenced-linux-amd64.zip\",\"digest\":\"sha256:${FIXTURE_INFERENCED_SHA256:?}\"}]}" ;;
  *'/releases/tags/release%2Fv0.2.16')
    emit '{"tag_name":"release/v0.2.16","assets":[{"name":"decentralized-api-amd64.zip","browser_download_url":"https://github.com/gonka-ai/gonka/releases/download/release/v0.2.16/decentralized-api-amd64.zip","digest":"sha256:2222222222222222222222222222222222222222222222222222222222222222"}]}' ;;
  *'/git/matching-refs/tags/release/v0.2.15')
    emit '[{"ref":"refs/tags/release/v0.2.15","object":{"type":"commit","sha":"4d687ed6782bcea3931d2d9135bf322f84e190ab"}}]' ;;
  *'/git/matching-refs/tags/release/v0.2.16')
    emit '[{"ref":"refs/tags/release/v0.2.16","object":{"type":"commit","sha":"18506d42c510e0cafe6acd748bcd8d83036cba40"}}]' ;;
  *raw.githubusercontent.com/gonka-ai/gonka/ce33c851282b8f4c0f63d78d46ddd4d8bb248207/deploy/join/docker-compose.yml)
    emit $'services:\n  node:\n    image: ghcr.io/product-science/inferenced:0.2.15\n  api:\n    image: ghcr.io/product-science/api:0.2.15-post3' ;;
  *'ghcr.io/token?'*) emit '{"token":"fixture-token"}' ;;
  *'ghcr.io/v2/'*'/manifests/'*)
    [[ -n "$headers" ]] || exit 2
    printf 'HTTP/2 200\r\nDocker-Content-Digest: sha256:3333333333333333333333333333333333333333333333333333333333333333\r\n' >"$headers" ;;
  */inferenced-linux-amd64.zip)
    [[ -n "$output" ]] || exit 2
    cp -- "${FIXTURE_INFERENCED_ARCHIVE:?}" "$output" ;;
  */status)
    emit "$(printf '{"result":{"node_info":{"id":"%s","network":"gonka-devnet-community","version":"0.2.15"},"sync_info":{"latest_block_height":"5000","catching_up":false}}}' "$node_id")" ;;
  */abci_info) emit '{"result":{"response":{"version":"0.2.15"}}}' ;;
  */net_info) emit '{"result":{"peers":[]}}' ;;
  */v1/versions)
    emit '{"node_version":{"application_name":"inference-chain","version":"0.2.15","commit":"4d687ed6782bcea3931d2d9135bf322f84e190ab"},"api_version":{"application_name":"decentralized-api","version":"0.2.16","commit":"18506d42c510e0cafe6acd748bcd8d83036cba40"}}' ;;
  */block?height=*) block "${url##*=}" ;;
  */last_upgrade_height) emit '{"lastUpgradeHeight":"100","found":true}' ;;
  */inference/params)
    emit '{"params":{"devshard_escrow_params":{"approved_versions":[{"name":"v4","binary":"https://example.test/devshard-v4.zip","sha256":"4444444444444444444444444444444444444444444444444444444444444444"}]}}}' ;;
  *) exit 22 ;;
esac
finish "$response_status"
EOF

cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${GDC_TEST_SSH_LOG:?}"
case "$*" in
  # The read-only identity preflight: this Host still holds a validator identity.
  *p2p/node_key.json*) exit 0 ;;
  # The durable TMKMS public key, derived on the Host from its softsign secret.
  *priv_validator_key.softsign*)
    cat >/dev/null
    printf '%s\n' "${GDC_TEST_HOST_SIGNER_KEY:?}"
    exit 0
    ;;
  # GDC selects the immutable ML profile before JOIN. This is an inspection,
  # not Host preparation; consume the script and identify a supported GPU.
  *'bash -s'*)
    cat >/dev/null
    printf 'vendor=nvidia\n'
    exit 0
    ;;
esac
# Every other call would change the Host. Refuse it so the test can see it.
exit 1
EOF

cat >"$tmp/bin/getent" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
# The fixture seeds and the joining Host are not in DNS, and the launcher
# insists on exactly one IPv4 for each of them.
[[ "${1:-}" == ahostsv4 ]] || exec /usr/bin/getent "$@"
case "${2:-}" in
  node0.example.test) printf '%s STREAM %s\n' 8.8.4.1 "$2" ;;
  node1.example.test) printf '%s STREAM %s\n' 8.8.4.2 "$2" ;;
  8.8.4.10) printf '%s STREAM %s\n' "$2" "$2" ;;
  *) exit 2 ;;
esac
EOF

cat >"$tmp/bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
# No fixture Compose file can reproduce the pinned official Host-stack digest,
# so that single path is answered from the lock and everything else is real.
if [[ "${1:-}" == *host-stack-compose.yml ]]; then
  printf '%s  %s\n' d4b17a18013160236b79aac880a9f5b17705312f45c85ea3d37cc978c8da3f94 "$1"
else
  exec /usr/bin/sha256sum "$@"
fi
EOF
chmod 0755 "$tmp/bin"/*

# A Host that finished a JOIN earlier: local identity, cold account and joined
# marker, which is what classify-join-state.sh reads as running_matched.
seed_completed_host() {
  local home="$1" node_home="$1/$ALIAS"
  install -d -m 0700 "$node_home/state/identities" "$node_home/state/joined" "$node_home/accounts"
  jq -n --arg node "$ALIAS" --arg consensus "$HOST_SIGNER_KEY" '{
    node_name:$node,
    node_id:"a1b2c3d4e5f60718293a4b5c6d7e8f9012345678",
    consensus_pubkey:$consensus,
    warm_address:"gonka1fixturewarmaccount000000000000wz",
    warm_pubkey_b64:"AjAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  }' >"$node_home/state/identities/$ALIAS.json"
  jq -n --arg address "$ADDRESS" '{name:"validator-a-cold",address:$address,type:"local"}' \
    >"$node_home/accounts/$ALIAS-cold.json"
  : >"$node_home/state/joined/$ALIAS"
}

run_join() {
  local home="$1" registered_key="$2" log="$3" ssh_log="$4" participant_body="${5:-}" participant_status="${6:-200}"
  : >"$ssh_log"
  seed_completed_host "$home"
  env -u GDC_ENV -u GDC_NODE_ALIASES \
    GDC_HOME="$home" PATH="$tmp/bin:$PATH" \
    GDC_TEST_SSH_LOG="$ssh_log" \
    GDC_TEST_HOST_SIGNER_KEY="$HOST_SIGNER_KEY" \
    GDC_TEST_REGISTERED_VALIDATOR_KEY="$registered_key" \
    GDC_TEST_PARTICIPANT_BODY="$participant_body" \
    GDC_TEST_PARTICIPANT_HTTP_STATUS="$participant_status" \
    GDC_TEST_GENESIS_FIXTURE="$tmp/genesis.json" \
    FIXTURE_INFERENCED_ARCHIVE="$FIXTURE_INFERENCED_ARCHIVE" \
    FIXTURE_INFERENCED_SHA256="$FIXTURE_INFERENCED_SHA256" \
    GDC_JOIN_PREFLIGHT_RETRY_SECONDS=1 \
    GDC_JOIN_FAULT_DOMAIN_MAP='node0.example.test=domain-a,node1.example.test=domain-b' \
    GDC_JOIN_RPC_IP_MAP='node0.example.test=8.8.4.1,node1.example.test=8.8.4.2' \
    "$ROOT/gdc.sh" host join "$ALIAS" --public-host "$PUBLIC_HOST" --skip-qualification \
      --bootstrap-file "$tmp/bootstrap.json" >"$log" 2>&1
}

join_result() {
  find "$1/$ALIAS" -type f -path "*/join-$ALIAS/join-result.v1.json" -print -quit
}

if run_join "$tmp/mismatch" "$FOREIGN_VALIDATOR_KEY" "$tmp/mismatch.log" "$tmp/mismatch-ssh.log"; then
  sed -n '1,200p' "$tmp/mismatch.log" >&2
  fail 'JOIN accepted a participant registered with a key this Host cannot sign with'
fi

grep -Fq 'registered_validator_key_mismatch' "$tmp/mismatch.log" \
  || { sed -n '1,200p' "$tmp/mismatch.log" >&2; fail 'the run did not refuse the foreign registration'; }

mismatch_run="$(find "$tmp/mismatch/$ALIAS/runs" -maxdepth 2 -type d -name "join-$ALIAS" -print -quit)"
[[ -n "$mismatch_run" ]] || fail 'the refused run left no evidence directory'
# What the operator is told: the message on the way out and the verdict the
# refusal retains beside it.
cat "$tmp/mismatch.log" >"$tmp/mismatch-refusal.txt"
[[ ! -f "$mismatch_run/verdict.md" ]] || cat "$mismatch_run/verdict.md" >>"$tmp/mismatch-refusal.txt"
grep -Eq -- '--mnemonic-prompt|--mnemonic-file' "$tmp/mismatch-refusal.txt" \
  || fail 'the refusal does not name the command that repairs the registration'
# gdc.sh unsets GDC_JOIN_REBIND_EXISTING_PARTICIPANT for every join, so naming
# it here would be an instruction the operator cannot follow.
if grep -Fq 'GDC_JOIN_REBIND_EXISTING_PARTICIPANT' "$tmp/mismatch-refusal.txt"; then
  fail 'the refusal sends the operator to a capability the launcher scrubs'
fi

mismatch_result="$(join_result "$tmp/mismatch")"
[[ -n "$mismatch_result" ]] || fail 'the refused run retained no terminal result'
jq -e '.outcome == "refused" and .mutation == "none" and .reason == "registered_validator_key_mismatch"' \
  "$mismatch_result" >/dev/null \
  || { jq -c . "$mismatch_result" >&2; fail 'the terminal result does not record a refusal before mutation'; }

# Profile inspection plus two identity/key reads and nothing else: the Host
# was never prepared, rendered or started.
[[ "$(wc -l <"$tmp/mismatch-ssh.log")" == 3 ]] \
  || { cat "$tmp/mismatch-ssh.log" >&2; fail 'the refused run made an unexpected Host call'; }
grep -Fq 'bash -s' <<<"$(sed -n 1p "$tmp/mismatch-ssh.log")" \
  || fail 'the first Host call was not read-only accelerator inspection'
grep -Fq 'p2p/node_key.json' <<<"$(sed -n 2p "$tmp/mismatch-ssh.log")" \
  || fail 'the second Host call was not the read-only identity preflight'
grep -Fq 'priv_validator_key.softsign' <<<"$(sed -n 3p "$tmp/mismatch-ssh.log")" \
  || fail 'the third Host call was not the durable signer key derivation'
if grep -Eq 'prepare-host|verify-host|install|render|start|systemctl|docker|rsync|scp|BatchMode' "$tmp/mismatch-ssh.log"; then
  cat "$tmp/mismatch-ssh.log" >&2
  fail 'the refused run reached a Host call that changes the Host'
fi

assert_unreadable_before_prepare() {
  local name="$1" body="$2" status="${3:-200}" home
  home="$tmp/unreadable-$name"
  if run_join "$home" "$FOREIGN_VALIDATOR_KEY" "$tmp/$name.log" "$tmp/$name-ssh.log" "$body" "$status"; then
    sed -n '1,200p' "$tmp/$name.log" >&2
    fail "$name unexpectedly reached JOIN"
  fi
  grep -Fq 'registered_validator_key_unreadable' "$tmp/$name.log" \
    || { sed -n '1,200p' "$tmp/$name.log" >&2; fail "$name was not a typed unreadable refusal"; }
  result="$(join_result "$home")"
  [[ -n "$result" ]] && jq -e '.outcome == "refused" and .mutation == "none" and .reason == "registered_validator_key_unreadable"' "$result" >/dev/null \
    || fail "$name did not retain a no-mutation unreadable refusal"
  [[ "$(wc -l <"$tmp/$name-ssh.log")" == 2 ]] \
    || { cat "$tmp/$name-ssh.log" >&2; fail "$name made a Host call beyond profile and identity inspection"; }
  grep -Fq 'bash -s' <<<"$(sed -n 1p "$tmp/$name-ssh.log")" \
    || fail "$name did not use the read-only accelerator inspection"
  grep -Fq 'p2p/node_key.json' <<<"$(sed -n 2p "$tmp/$name-ssh.log")" \
    || fail "$name read a signer key after incomplete participant evidence"
}

assert_unreadable_before_prepare missing-key \
  '{"participant":{"address":"gonka1fixturevalidatoraccount0000000000qq","status":"ACTIVE"}}'
assert_unreadable_before_prepare null-key \
  '{"participant":{"address":"gonka1fixturevalidatoraccount0000000000qq","validator_key":null,"status":"ACTIVE"}}'
assert_unreadable_before_prepare numeric-key \
  '{"participant":{"address":"gonka1fixturevalidatoraccount0000000000qq","validator_key":7,"status":"ACTIVE"}}'
assert_unreadable_before_prepare unavailable '{}' 503

# The typed 503 refusal becomes the selected failure report. It must traverse
# the real reporter and its mnemonic scanner, not only the diagnostic envelope.
PATH="$tmp/bin:$PATH" FAKE_GH_ARGS="$tmp/report.args" FAKE_GH_BODY="$tmp/report.md" GDC_REPORT_TEST_INTERACTIVE=true \
  GDC_HOME="$tmp/unreadable-unavailable" "$ROOT/gdc.sh" report github >"$tmp/report.out" 2>"$tmp/report.err" <<'EOF'
1

.
y
EOF
grep -Fq 'Published and verified:' "$tmp/report.out" \
  || { sed -n '1,160p' "$tmp/report.out" >&2; sed -n '1,160p' "$tmp/report.err" >&2; fail 'unreadable refusal could not be reported'; }
! grep -Fq 'unsafe generated report body' "$tmp/report.err" \
  || fail 'unreadable refusal was rejected by the public report scanner'

# This is the point of the whole change: the refusal is typed, so the next
# ordinary JOIN classifies the Host afresh instead of demanding recovery.
reentry_class="$("$ROOT/scripts/classify-join-reentry.sh" --previous-run-dir "$mismatch_run" \
  --current-profile "$mismatch_run/join-profile.v1.json" | jq -r .classification)"
[[ "$reentry_class" == refused_before_mutation ]] \
  || fail "a re-entry after the refusal answers $reentry_class, not refused_before_mutation"

# The control: the same harness with the key this Host signs with must get
# past the verdict instead of refusing everything that looks like it.
run_join "$tmp/control" "$HOST_SIGNER_KEY" "$tmp/control.log" "$tmp/control-ssh.log" || true
grep -Fq 'registered validator key is the durable TMKMS signer' "$tmp/control.log" \
  || { sed -n '1,200p' "$tmp/control.log" >&2; fail 'a matching registration did not pass the verdict'; }
control_result="$(join_result "$tmp/control")"
if [[ -n "$control_result" ]] && jq -e '.reason == "registered_validator_key_mismatch"' "$control_result" >/dev/null; then
  fail 'a matching registration was still recorded as a key mismatch'
fi

printf 'PASS a foreign registered validator key is refused before the Host is prepared\n'
