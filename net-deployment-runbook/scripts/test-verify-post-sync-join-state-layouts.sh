#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/gdc-post-sync-layout.XXXXXX)"
trap 'rm -rf -- "$tmp"' EXIT
image=gdc-post-sync-layout-test:local

if ! docker image inspect "$image" >/dev/null 2>&1; then
  docker build --file "$ROOT/test/Dockerfile" --tag "$image" "$ROOT/.." >/dev/null
fi

profile="$tmp/join-profile.json"
printf '%s\n' '{}' >"$profile"
profile_sha256="$(sha256sum "$profile" | awk '{print $1}')"

write_receipt() {
  local receipts="$1" state="$2" input="$tmp/input.json"
  jq -cn --arg state "$state" --arg profile "$profile_sha256" '
    {schema_version:2,kind:"gdc-host-join-receipt",run_id:"fixture-run",operation:"new",node_name:"fixture",state:$state,
     join_profile_sha256:$profile,network_observation_sha256:("a" * 64),generation_id:"fixture-run",
     identity_fingerprints:{participant_address:"",consensus_pubkey:"",p2p_node_id:"",warm_address:""},
     signer_ever_started:false,tmkms_state:{height:0,round:0,step:0,block_id:""},
     evidence:[],outcome:"in_progress",resume_policy:"resume_same_run"}' >"$input"
  "$ROOT/scripts/record-join-receipt.sh" --receipt-dir "$receipts" --input "$input" >/dev/null
}

make_receipts() {
  local destination="$1"
  mkdir -p "$destination"
  write_receipt "$destination" RUN_CREATED
  write_receipt "$destination" CANARY_VERIFIED
  write_receipt "$destination" PROMOTED
  write_receipt "$destination" CANONICAL_RUNNING
  write_receipt "$destination" APPLICATION_ACTIVE
}

make_layout() {
  local layout="$1" lineage_mode="${2:-stub}" root data
  root="$tmp/$layout"
  data="$root/srv/dai/data"
  mkdir -p "$root/srv/dai/deploy" "$root/srv/dai/data.generations/fixture-run" "$root/tmp/gdc-fixture"
  jq -cn --arg generation /srv/dai/data.generations/fixture-run \
    '{schema_version:1,kind:"gdc-state-sync-promotion",state:"PROMOTED",node_name:"fixture",generation:$generation}' \
    >"$root/srv/dai/deploy/.promotion-receipt.json"
  if [[ "$layout" == flat* ]]; then
    ln -s /srv/dai/data.generations/fixture-run "$data"
  else
    mkdir -p "$data"
  fi
  cat >"$root/srv/dai/deploy/verify-canonical-join-state.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == /srv/dai/deploy && "$2" == gonka-devnet-community ]]
touch /srv/dai/deploy/canonical-called
EOF
  if [[ "$lineage_mode" == actual ]]; then
    cp "$ROOT/scripts/verify-join-lineage-state.sh" "$root/tmp/gdc-fixture/verify-join-lineage-state.real.sh"
    cat >"$root/tmp/gdc-fixture/verify-join-lineage-state.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
PATH="$script_dir/bin:$PATH" exec "$script_dir/verify-join-lineage-state.real.sh" "$@"
EOF
    mkdir -p "$root/tmp/gdc-fixture/bin"
    cat >"$root/tmp/gdc-fixture/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${!#}"; resolved=false; resolve_target=''
for ((index = 1; index <= $#; index++)); do
  if [[ "${!index}" == --resolve ]]; then
    resolved=true
    next=$((index + 1))
    resolve_target="${!next}"
  fi
done
if [[ "$resolve_target" == rpc-b.fixture.test:443:192.0.2.11 && -e "$(dirname "$0")/../unavailable" ]]; then
  exit 7
fi
case "$url" in
  */status) printf '%s\n' '{"result":{"sync_info":{"latest_block_height":"5000"}}}' ;;
  *'/block?height='*)
    app=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    if [[ "$resolved" == false && -e "$(dirname "$0")/../divergent" ]]; then
      app=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    fi
    printf '{"result":{"block_id":{"hash":"1111111111111111111111111111111111111111111111111111111111111111"},"block":{"header":{"height":"5000","app_hash":"%s"}}}}\n' "$app"
    ;;
  *) exit 22 ;;
esac
EOF
    chmod 0755 "$root/tmp/gdc-fixture/verify-join-lineage-state.real.sh" "$root/tmp/gdc-fixture/bin/curl"
    jq -cn '
      {bootstrap:{mode:"state_sync",trust:{height:3000,expires_at:"2000-01-01T00:00:00Z"}},
       checkpoints:{trust:{height:3000}},
       fault_domains:[
         {rpc_url:"https://rpc-a.fixture.test/chain-rpc",host:"rpc-a.fixture.test",port:443,ip:"192.0.2.10"},
         {rpc_url:"https://rpc-b.fixture.test/chain-rpc",host:"rpc-b.fixture.test",port:443,ip:"192.0.2.11"}]}' \
      >"$root/tmp/gdc-fixture/lineage-receipt.json"
  else
    cat >"$root/tmp/gdc-fixture/verify-join-lineage-state.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == http://127.0.0.1:26657 && "$3" == --resume-current ]]
touch /srv/dai/deploy/lineage-called
EOF
  fi
  chmod 0755 "$root/srv/dai/deploy/verify-canonical-join-state.sh" "$root/tmp/gdc-fixture/verify-join-lineage-state.sh"
  chmod -R a+rwx "$root"
}

mkdir -p "$tmp/bin"
cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == fixture && "$2" == bash && "$3" == -s && "$4" == -- ]] || exit 41
layout="${GDC_TEST_LAYOUT:?GDC_TEST_LAYOUT is required}"
root="${GDC_TEST_LAYOUT_ROOT:?GDC_TEST_LAYOUT_ROOT is required}/$layout"
script="$root/remote.sh"
cat >"$script"
shift 4
exec docker run --rm --network none --user "$(id -u):$(id -g)" \
  -v "$root/srv/dai:/srv/dai:rw" -v "$root/tmp:/tmp:ro" -v "$script:/run/remote.sh:ro" \
  --entrypoint bash "${GDC_TEST_LAYOUT_IMAGE:?GDC_TEST_LAYOUT_IMAGE is required}" /run/remote.sh "$@"
EOF
chmod 0755 "$tmp/bin/ssh"

verify() {
  local verifier="${GDC_TEST_POST_SYNC_VERIFIER:-$ROOT/scripts/verify-post-sync-join-state.sh}"
  GDC_RUN_ID=fixture-run GDC_TEST_LAYOUT_ROOT="$tmp" GDC_TEST_LAYOUT_IMAGE="$image" PATH="$tmp/bin:$PATH" \
    "$verifier" --node fixture --run-dir "$tmp/run" --profile "$profile" \
    --remote-dir /tmp/gdc-fixture --expected-chain-id gonka-devnet-community \
    --expected-p2p-node-id 0123456789abcdef0123456789abcdef01234567 \
    --expected-core-version 0.2.15 --expected-core-commit 1111111111111111111111111111111111111111 \
    --expected-dapi-version 0.2.15-post3 --expected-dapi-commit 2222222222222222222222222222222222222222
}

mkdir -p "$tmp/run/receipts"
make_receipts "$tmp/run/receipts"
make_layout flat
export GDC_TEST_LAYOUT=flat
if verify >"$tmp/flat.out" 2>"$tmp/flat.err"; then
  :
else
  cat "$tmp/flat.out" "$tmp/flat.err" >&2
  exit 1
fi
if [[ ! -f "$tmp/flat/srv/dai/deploy/canonical-called" || ! -f "$tmp/flat/srv/dai/deploy/lineage-called" ]]; then
  echo 'flat post-sync layout did not execute both runtime checks' >&2
  exit 1
fi

make_layout legacy
export GDC_TEST_LAYOUT=legacy
if verify >"$tmp/legacy.out" 2>"$tmp/legacy.err"; then
  echo 'legacy directory unexpectedly passed post-sync verification' >&2
  exit 1
fi
if [[ -e "$tmp/legacy/srv/dai/deploy/canonical-called" || -e "$tmp/legacy/srv/dai/deploy/lineage-called" ]]; then
  echo 'legacy directory reached a runtime check before the layout guard' >&2
  exit 1
fi

# The receipt is intentionally expired here: it proves that initial trust is
# still rejected at canary time, while the consumed promoted generation uses a
# fresh common checkpoint instead. The divergent control must remain fatal.
make_layout flat-expiry actual
expiry_root="$tmp/flat-expiry/tmp/gdc-fixture"
if PATH="$expiry_root/bin:$PATH" "$expiry_root/verify-join-lineage-state.real.sh" \
  http://127.0.0.1:26657 "$expiry_root/lineage-receipt.json" >/dev/null 2>&1; then
  echo 'expired trust unexpectedly passed before the post-sync boundary' >&2
  exit 1
fi
export GDC_TEST_LAYOUT=flat-expiry
verify >"$tmp/expiry.out"

# The expired canary receipt is intentionally consumed by the promoted
# generation. Restoring the former non-current lineage call must make this
# otherwise valid post-sync verification fail; the control executes that
# broken verifier rather than inspecting its source text.
negative_control_dir="$tmp/negative-controls"
mkdir -p "$negative_control_dir"
cp "$ROOT/scripts/verify-join-receipt-chain.sh" "$negative_control_dir/"
late_expiry_verifier="$negative_control_dir/verify-post-sync-late-expiry.sh"
sed 's/ --resume-current$//' "$ROOT/scripts/verify-post-sync-join-state.sh" >"$late_expiry_verifier"
chmod 0755 "$late_expiry_verifier"
if GDC_TEST_POST_SYNC_VERIFIER="$late_expiry_verifier" verify >"$tmp/late-expiry.out" 2>"$tmp/late-expiry.err"; then
  echo 'late expiry control unexpectedly accepted a consumed trust receipt' >&2
  exit 1
fi

touch "$expiry_root/divergent"
if verify >"$tmp/divergent.out" 2>"$tmp/divergent.err"; then
  echo 'divergent current checkpoint unexpectedly passed post-sync verification' >&2
  exit 1
fi
# Removing the fresh current-checkpoint call makes the same divergent promoted
# generation pass. This is an execution control: it proves the preceding
# divergent assertion would catch that regression.
missing_checkpoint_verifier="$negative_control_dir/verify-post-sync-missing-checkpoint.sh"
sed 's|^bash "\$remote/verify-join-lineage-state.sh".*$|true # TEST-007 negative control removes the current-checkpoint proof|' \
  "$ROOT/scripts/verify-post-sync-join-state.sh" >"$missing_checkpoint_verifier"
chmod 0755 "$missing_checkpoint_verifier"
if ! GDC_TEST_POST_SYNC_VERIFIER="$missing_checkpoint_verifier" verify >"$tmp/missing-checkpoint.out" 2>"$tmp/missing-checkpoint.err"; then
  echo 'missing current-checkpoint control did not expose its divergent-state acceptance' >&2
  cat "$tmp/missing-checkpoint.out" "$tmp/missing-checkpoint.err" >&2
  exit 1
fi
rm -f "$expiry_root/divergent"
touch "$expiry_root/unavailable"
if verify >"$tmp/unavailable.out" 2>"$tmp/unavailable.err"; then
  echo 'unavailable trusted origin unexpectedly passed post-sync verification' >&2
  exit 1
fi

printf 'PASS post-sync verifier accepts only a matching current checkpoint after promotion and rejects legacy, divergent or unavailable state; expiry and checkpoint negative controls are detected\n'
