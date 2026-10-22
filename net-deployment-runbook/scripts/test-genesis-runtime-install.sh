#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $EUID -ne 0 || ! -f /.dockerenv || "${GDC_TEST_DISPOSABLE_ROOT:-false}" != true ]]; then
  echo 'Run this test as root in an isolated container with a fresh /srv/dai tmpfs and GDC_TEST_DISPOSABLE_ROOT=true' >&2
  exit 2
fi
if [[ -d /srv/dai ]] && find /srv/dai -mindepth 1 -print -quit | grep -q .; then
  echo 'Refusing a non-empty /srv/dai; the test requires a fresh disposable tmpfs' >&2
  exit 2
fi
for tool in bash jq unzip sha256sum docker od wc; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing test dependency: $tool" >&2; exit 2; }
done

temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
bin="$temporary/bin"
archives="$temporary/archives"
mkdir -p "$bin" "$archives" "$temporary/work"
export GDC_FIXTURE_ARCHIVES="$archives"

cat >"$bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -eu
url=''; output=''
while (($#)); do
  case "$1" in
    https://fixture.invalid/*) url="$1" ;;
    -o) shift; output="$1" ;;
  esac
  shift
done
[[ -n "$url" && -n "$output" ]]
cp "$GDC_FIXTURE_ARCHIVES/${url##*/}" "$output"
MOCK_CURL
cat >"$bin/docker" <<'MOCK_DOCKER'
#!/usr/bin/env bash
set -eu
case " $* " in
  *' --no-interpolate --no-normalize --no-path-resolution --format json '*)
    # Compose consumes the complete document from -f -. Closing this pipe
    # early makes the real renderer fail with SIGPIPE under pipefail.
    cat >/dev/null
    jq -n '{services:{node:{environment:{},volumes:[]},api:{environment:{},volumes:[]}}}'
    ;;
  *' config --quiet '*) exit 0 ;;
  *) printf 'unexpected Docker operation: %s\n' "$*" >&2; exit 97 ;;
esac
MOCK_DOCKER
for command_name in ssh scp; do
  printf '#!/bin/sh\nprintf "unexpected %s call\\n" >&2\nexit 97\n' "$command_name" >"$bin/$command_name"
done
chmod 0755 "$bin/"*
if [[ "${GDC_TEST_TRACE:-false}" == true ]]; then
  printf '#!/bin/sh\nexec /bin/bash -x "$@"\n' >"$bin/bash"
  chmod 0755 "$bin/bash"
fi

core_binary="$temporary/work/inferenced"
dapi_binary="$temporary/work/decentralized-api"
printf '#!/bin/sh\nprintf "fixture Core\\n"\n' >"$core_binary"
printf '#!/bin/sh\nprintf "fixture DAPI\\n"\n' >"$dapi_binary"
chmod 0755 "$core_binary" "$dapi_binary"
core_binary_sha="$(sha256sum "$core_binary" | awk '{print $1}')"
dapi_binary_sha="$(sha256sum "$dapi_binary" | awk '{print $1}')"

zip_u16() {
  local target="$1" value="$2" encoded
  printf -v encoded '%02x%02x' "$((value & 255))" "$(((value >> 8) & 255))"
  printf '%b' "\\x${encoded:0:2}\\x${encoded:2:2}" >>"$target"
}
zip_u32() {
  local target="$1" value="$2" encoded
  printf -v encoded '%02x%02x%02x%02x' "$((value & 255))" "$(((value >> 8) & 255))" \
    "$(((value >> 16) & 255))" "$(((value >> 24) & 255))"
  printf '%b' "\\x${encoded:0:2}\\x${encoded:2:2}\\x${encoded:4:2}\\x${encoded:6:2}" >>"$target"
}
zip_crc32() {
  local crc=4294967295 byte bit
  for byte in $(od -An -v -tu1 "$1"); do
    crc=$((crc ^ byte))
    for ((bit=0; bit<8; bit++)); do
      if ((crc & 1)); then crc=$(((crc >> 1) ^ 0xedb88320)); else crc=$((crc >> 1)); fi
    done
  done
  printf '%u\n' "$((crc ^ 4294967295))"
}
zip_begin() {
  zip_path="$1" zip_central="$temporary/central.bin"
  : >"$zip_path"; : >"$zip_central"
  zip_names=(); zip_sizes=(); zip_crcs=(); zip_offsets=()
}
zip_add() {
  local name="$1" source="$2" size crc offset
  size="$(wc -c <"$source")"
  crc="$(zip_crc32 "$source")"
  offset="$(wc -c <"$zip_path")"
  zip_u32 "$zip_path" 0x04034b50; zip_u16 "$zip_path" 20; zip_u16 "$zip_path" 0
  zip_u16 "$zip_path" 0; zip_u16 "$zip_path" 0; zip_u16 "$zip_path" 0
  zip_u32 "$zip_path" "$crc"; zip_u32 "$zip_path" "$size"; zip_u32 "$zip_path" "$size"
  zip_u16 "$zip_path" "${#name}"; zip_u16 "$zip_path" 0
  printf '%s' "$name" >>"$zip_path"; cat "$source" >>"$zip_path"
  zip_names+=("$name"); zip_sizes+=("$size"); zip_crcs+=("$crc"); zip_offsets+=("$offset")
}
zip_finish() {
  local index count central_offset central_size name
  count="${#zip_names[@]}"; central_offset="$(wc -c <"$zip_path")"
  for ((index=0; index<count; index++)); do
    name="${zip_names[index]}"
    zip_u32 "$zip_central" 0x02014b50; zip_u16 "$zip_central" 20; zip_u16 "$zip_central" 20
    zip_u16 "$zip_central" 0; zip_u16 "$zip_central" 0; zip_u16 "$zip_central" 0; zip_u16 "$zip_central" 0
    zip_u32 "$zip_central" "${zip_crcs[index]}"; zip_u32 "$zip_central" "${zip_sizes[index]}"
    zip_u32 "$zip_central" "${zip_sizes[index]}"; zip_u16 "$zip_central" "${#name}"
    zip_u16 "$zip_central" 0; zip_u16 "$zip_central" 0; zip_u16 "$zip_central" 0
    zip_u16 "$zip_central" 0; zip_u32 "$zip_central" 0; zip_u32 "$zip_central" "${zip_offsets[index]}"
    printf '%s' "$name" >>"$zip_central"
  done
  central_size="$(wc -c <"$zip_central")"
  cat "$zip_central" >>"$zip_path"
  zip_u32 "$zip_path" 0x06054b50; zip_u16 "$zip_path" 0; zip_u16 "$zip_path" 0
  zip_u16 "$zip_path" "$count"; zip_u16 "$zip_path" "$count"
  zip_u32 "$zip_path" "$central_size"; zip_u32 "$zip_path" "$central_offset"; zip_u16 "$zip_path" 0
  rm -f -- "$zip_central"
}
make_archive() {
  local role="$1" binary="$2" executable
  executable=inferenced; [[ "$role" != api ]] || executable=decentralized-api
  zip_begin "$archives/$role.zip"
  zip_add "$executable" "$binary"
  zip_add libgcc_s.so.1 "$temporary/work/libgcc_s.so.1"
  zip_finish
}
printf 'fixture shared library\n' >"$temporary/work/libgcc_s.so.1"
make_archive node "$core_binary"
make_archive api "$dapi_binary"
core_archive_sha="$(sha256sum "$archives/node.zip" | awk '{print $1}')"
dapi_archive_sha="$(sha256sum "$archives/api.zip" | awk '{print $1}')"
core_image='ghcr.io/fixture/inferenced:0.2.16-post1@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
dapi_image='ghcr.io/fixture/api:0.2.16-post1@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
commit=136041c81ea8ff38e7620d76af66a7c7fe7eec50

make_fragment() {
  local output="$1" core_archive="$2" dapi_archive="$3" core_sha="$4" dapi_sha="$5"
  jq -n -S \
    --arg commit "$commit" --arg core_image "$core_image" --arg dapi_image "$dapi_image" \
    --arg core_archive "$core_archive" --arg dapi_archive "$dapi_archive" \
    --arg core_sha "$core_sha" --arg dapi_sha "$dapi_sha" \
    'def artifact($url;$sha;$exe): {url:$url,sha256:$sha,format:"zip",executable:$exe};
     {schema_version:1,kind:"gdc-genesis-software-fragment",
      source:{release_profile:"v2026.10.06",release_lock_sha256:("a"*64),model_profile:"qwen3-0.6b",
        model_lock_sha256:("b"*64)},
      spec:{deployment:{software:{schema_version:1,platform:"linux/amd64",accelerator:"cuda",
        deployment:{repository:"https://github.com/gonka-ai/gonka.git",commit:$commit,
          compose_files:[{path:"deploy/join/docker-compose.yml",sha256:("c"*64)}]},
        components:{node:{version:"0.2.16-post1",image:$core_image,commit:$commit,
            upgrade:{name:"v0.2.16",artifact:artifact("https://fixture.invalid/node.zip";$core_archive;"inferenced")}},
          api:{version:"0.2.16-post1",image:$dapi_image,commit:$commit,
            upgrade:{name:"v0.2.16",artifact:artifact("https://fixture.invalid/api.zip";$dapi_archive;"decentralized-api")}},
          tmkms:{version:"0.2.15",image:("ghcr.io/fixture/tmkms:0.2.15@sha256:"+("d"*64))},
          mlnode:{version:"3.0.16",image:("ghcr.io/fixture/mlnode:3.0.16@sha256:"+("e"*64))}},
        operator_cli:{version:"0.2.16-post1",artifact:artifact("https://fixture.invalid/operator.zip";("f"*64);"inferenced")},
        model:{id:"Qwen/Qwen3-0.6B",revision:("1"*40),context_length:4096,max_num_seqs:32,
          gpu_memory_utilization:0.5,dtype:"bfloat16",tensor_parallel_size:1}}}},
      binary_sha256:{inferenced:$core_sha,decentralized_api:$dapi_sha}}' >"$output"
}

env_file="$temporary/node.env"
node_config="$temporary/node-config.json"
genesis="$temporary/genesis.json"
fragment="$temporary/genesis-software.json"
printf '[]\n' >"$node_config"
printf '{"chain_id":"fixture-chain"}\n' >"$genesis"
make_fragment "$fragment" "$core_archive_sha" "$dapi_archive_sha" "$core_binary_sha" "$dapi_binary_sha"

make_env() {
  local data_dir="$1"
  cat >"$env_file" <<EOF
GDC_PROFILE_KIND=release
GDC_RELEASE_PROFILE=v2026.10.06
GDC_PROFILE_HASH=$(printf 'a%.0s' {1..64})
IS_GENESIS=true
CHAIN_ID=fixture-chain
DATA_DIR=$data_dir
INFERENCED_IMAGE=$core_image
DAPI_IMAGE=$dapi_image
EOF
}
run_installer() {
  local expected="$1"; shift
  local trace=()
  [[ "${GDC_TEST_TRACE:-false}" != true ]] || trace=(-x)
  set +e
  env -i PATH="$bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    GDC_FIXTURE_ARCHIVES="$archives" bash "${trace[@]}" "$ROOT/02-node/install-node.sh" \
    --node-name gdc-node0 --env "$env_file" --node-config "$node_config" --genesis "$genesis" \
    --genesis-software "$fragment" --genesis-software-sha256 "$(sha256sum "$fragment" | awk '{print $1}')" "$@" \
    >"$temporary/installer.stdout" 2>"$temporary/installer.stderr"
  local rc=$?
  set -e
  if [[ "$expected" == success && $rc -ne 0 ]]; then
    cat "$temporary/installer.stdout" "$temporary/installer.stderr" >&2
    return 1
  elif [[ "$expected" == failure && $rc -eq 0 ]]; then
    echo 'installer unexpectedly succeeded' >&2
    return 1
  fi
}
assert_no_install_writes() {
  [[ ! -e /srv/dai/deploy && ! -e /srv/dai/shared/genesis.json ]] \
    || { echo 'refusal changed the deployment or shared Genesis' >&2; return 1; }
  [[ -z "$(find /srv/dai -maxdepth 1 -name '.gdc-stage.*' -print -quit)" ]] \
    || { echo 'refusal left an installer stage behind' >&2; return 1; }
}
reset_fixture() {
  rm -rf -- /srv/dai/deploy /srv/dai/shared /srv/dai/inference /srv/dai/dapi /srv/dai/gdc-node0 /srv/dai/identity
  mkdir -p /srv/dai/inference/config /srv/dai/gdc-node0/inference/config /srv/dai/identity/p2p
  printf 'fixture identity config\n' >/srv/dai/inference/config/config.toml
  printf 'fixture application config\n' >/srv/dai/inference/config/app.toml
  printf 'fixture client config\n' >/srv/dai/inference/config/client.toml
  printf '{"fixture":"p2p-key"}\n' >/srv/dai/inference/config/node_key.json
  cp /srv/dai/inference/config/node_key.json /srv/dai/identity/p2p/node_key.json
  printf '{"fixture":"validator-key"}\n' >/srv/dai/inference/config/priv_validator_key.json
  jq -n '{chain_id:"fixture-chain",initial_height:1,app_hash:null,
    app_state:{auth:{accounts:[]},genutil:{gen_txs:[]},staking:{validators:[]}}}' \
    >/srv/dai/inference/config/genesis.json
  printf 'fixture identity config\n' >/srv/dai/gdc-node0/inference/config/config.toml
  printf 'fixture application config\n' >/srv/dai/gdc-node0/inference/config/app.toml
  printf 'fixture client config\n' >/srv/dai/gdc-node0/inference/config/client.toml
  printf '{"fixture":"p2p-key"}\n' >/srv/dai/gdc-node0/inference/config/node_key.json
  printf '{"fixture":"validator-key"}\n' >/srv/dai/gdc-node0/inference/config/priv_validator_key.json
  jq -n '{chain_id:"fixture-chain",initial_height:1,app_hash:null,
    app_state:{auth:{accounts:[]},genutil:{gen_txs:[]},staking:{validators:[]}}}' \
    >/srv/dai/gdc-node0/inference/config/genesis.json
}
make_zeroheight_init_state() {
  local root="$1"
  mkdir -p "$root/inference/data"
  printf '{"height":"0","round":0,"step":0}\n' >"$root/inference/data/priv_validator_state.json"
}

# Current canonical deployment accepts only the fresh identity bootstrap files.
reset_fixture
make_env /srv/dai
make_zeroheight_init_state /srv/dai
run_installer success
jq -e --arg fragment_sha "$(sha256sum "$fragment" | awk '{print $1}')" \
  --arg core "$core_binary_sha" --arg dapi "$dapi_binary_sha" \
  '.kind == "gdc-genesis-runtime-install" and .fragment_sha256 == $fragment_sha
   and .core.binary_sha256 == $core and .dapi.binary_sha256 == $dapi' \
  /srv/dai/deploy/.gdc-genesis-software >/dev/null
[[ "$(sha256sum /srv/dai/deploy/bootstrap-runtime/node/bin/inferenced | awk '{print $1}')" == "$core_binary_sha" ]]
[[ "$(sha256sum /srv/dai/deploy/bootstrap-runtime/api/bin/decentralized-api | awk '{print $1}')" == "$dapi_binary_sha" ]]
jq -e '
  .services.node.environment.GDC_BOOTSTRAP_SOFTWARE == "true"
  and .services.api.environment.GDC_BOOTSTRAP_SOFTWARE == "true"
  and any(.services.node.volumes[]; .source == "./bootstrap-runtime" and .target == "/gdc-bootstrap-runtime" and .read_only == true)
  and any(.services.api.volumes[]; .source == "./bootstrap-runtime" and .target == "/gdc-bootstrap-runtime" and .read_only == true)
  and any(.services.node.volumes[]; .source == "./bootstrap-runtime.sh" and .target == "/usr/local/bin/gdc-bootstrap-runtime" and .read_only == true)
  and any(.services.api.volumes[]; .source == "./bootstrap-runtime.sh" and .target == "/usr/local/bin/gdc-bootstrap-runtime" and .read_only == true)
' /srv/dai/deploy/compose.yaml >/dev/null || { echo 'Genesis Compose does not mount the verified Core/DAPI runtime packages' >&2; exit 1; }
[[ "$(sha256sum /srv/dai/shared/genesis.json | awk '{print $1}')" == "$(sha256sum "$genesis" | awk '{print $1}')" ]]
rm -rf -- /srv/dai/deploy /srv/dai/shared

# Default upstream init Genesis is accepted only with empty genesis
# transactions/accounts/validators, expected chain ID, and a zero-height
# validator state file as the sole data entry.
reset_fixture
make_env /srv/dai
make_zeroheight_init_state /srv/dai
run_installer success
rm -rf -- /srv/dai/deploy /srv/dai/shared

reset_fixture
make_env /srv/dai
make_zeroheight_init_state /srv/dai
printf '{"height":"1","round":0,"step":0}\n' >/srv/dai/inference/data/priv_validator_state.json
run_installer failure
grep -Fq 'nonzero or malformed validator state' "$temporary/installer.stderr"
assert_no_install_writes

reset_fixture
make_env /srv/dai
make_zeroheight_init_state /srv/dai
mkdir -p /srv/dai/inference/data/application.db
run_installer failure
grep -Fq 'existing consensus/application database state' "$temporary/installer.stderr"
assert_no_install_writes

reset_fixture
make_env /srv/dai
make_zeroheight_init_state /srv/dai
jq '.app_state.genutil.gen_txs=[{"fixture":"unexpected"}]' \
  /srv/dai/inference/config/genesis.json >"$temporary/populated-genesis.json"
mv "$temporary/populated-genesis.json" /srv/dai/inference/config/genesis.json
run_installer failure
grep -Fq 'non-default or populated init Genesis' "$temporary/installer.stderr"
assert_no_install_writes

# The fragment's command-line SHA guard is mandatory, and Genesis fragments
# cannot be combined with the generated JOIN profile path.
reset_fixture
make_env /srv/dai
run_installer failure --genesis-software-sha256 "$(printf '%064d' 0)"
grep -Fq 'does not match its SHA-256 guard' "$temporary/installer.stderr"
assert_no_install_writes
run_installer failure --join-profile "$fragment"
grep -Fq 'cannot be combined with a JOIN profile' "$temporary/installer.stderr"
assert_no_install_writes

# A mismatched executable is rejected after a valid archive digest, before installation.
reset_fixture
printf '#!/bin/sh\nprintf "wrong Core\\n"\n' >"$temporary/work/wrong-inferenced"
chmod 0755 "$temporary/work/wrong-inferenced"
zip_begin "$archives/node.zip"
zip_add inferenced "$temporary/work/wrong-inferenced"
zip_add libgcc_s.so.1 "$temporary/work/libgcc_s.so.1"
zip_finish
core_archive_sha="$(sha256sum "$archives/node.zip" | awk '{print $1}')"
make_fragment "$fragment" "$core_archive_sha" "$dapi_archive_sha" "$core_binary_sha" "$dapi_binary_sha"
make_env /srv/dai
run_installer failure
grep -Fq 'Genesis node executable SHA-256 does not match the pinned binary' "$temporary/installer.stderr"
assert_no_install_writes

# A damaged archive fails its archive pin before any target state is installed.
reset_fixture
make_archive node "$core_binary"
printf 'corrupt' >>"$archives/node.zip"
make_env /srv/dai
run_installer failure
grep -Fq 'FAILED' "$temporary/installer.stdout" "$temporary/installer.stderr"
assert_no_install_writes

# A legacy per-node DATA_DIR and initialized deployment/Cosmovisor are refused before staging.
reset_fixture
make_env /srv/dai/gdc-node0
run_installer failure
grep -Fq 'canonical DATA_DIR=/srv/dai' "$temporary/installer.stderr"
assert_no_install_writes

make_env /srv/dai
mkdir -p /srv/dai/deploy
printf 'preserve\n' >/srv/dai/deploy/preserved
run_installer failure
grep -Fq 'existing deployment directory' "$temporary/installer.stderr"
grep -Fxq 'preserve' /srv/dai/deploy/preserved
rm -rf -- /srv/dai/deploy

mkdir -p /srv/dai/gdc-node0/deploy
printf 'preserve legacy runtime\n' >/srv/dai/gdc-node0/deploy/.env
run_installer failure
grep -Fq 'existing deployment directory: /srv/dai/gdc-node0/deploy' "$temporary/installer.stderr"
[[ -f /srv/dai/gdc-node0/inference/config/config.toml ]]
assert_no_install_writes
rm -rf -- /srv/dai/gdc-node0/deploy

mkdir -p /srv/dai/inference/cosmovisor/genesis/bin
printf 'preserve\n' >/srv/dai/inference/cosmovisor/genesis/bin/inferenced
run_installer failure
grep -Fq 'existing Cosmovisor home' "$temporary/installer.stderr"
assert_no_install_writes

rm -rf -- /srv/dai/deploy /srv/dai/shared /srv/dai/inference /srv/dai/dapi /srv/dai/gdc-node0

echo 'PASS fresh Genesis pinned Core/DAPI runtime install and refusal fixtures'
