#!/usr/bin/env bash
# Exercise two unrelated parent/donor pairs through the shipped lending phase.
# The transport only accepts the selected pair, so a fixed fleet target or an
# accidental alias-derived endpoint turns this into a failing behavior test.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
cleanup() {
  if [[ "${GDC_TEST_KEEP_TMP:-false}" == true ]]; then
    printf 'KEEP_TEST_TMP=%s\n' "$tmp" >&2
  else
    rm -rf -- "$tmp"
  fi
}
trap cleanup EXIT
kit="$tmp/kit"
mkdir -p "$kit/scripts" "$kit/02-node" "$kit/03-join" "$tmp/bin"
cp "$ROOT/scripts/phase-ml-lend.sh" "$ROOT/scripts/phase-node-lent-start.sh" "$ROOT/scripts/read-lent-ml-record.sh" \
  "$ROOT/scripts/add-network-ml-endpoint.sh" "$kit/scripts/"
cp "$ROOT/02-node/sync-node-config.sh" "$kit/02-node/"
cat >"$kit/03-join/start-local-ml.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$#" == 9 && "$1" == "${GDC_CASE_DONOR:?}" ]]
printf 'start-local-ml:%s\n' "$*" >>"$GDC_TEST_EVENTS"
SH
chmod 0755 "$kit/03-join/start-local-ml.sh"

cat >"$kit/scripts/ensure-ml-callback.sh" <<'CALLBACK'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$#" == 3 && -n "$1" && -n "$2" && -n "$3" ]]
# The real callback transport and remote apply are exercised separately in
# test-ml-callback; this fixture isolates the lending/return state machine.
CALLBACK
cat >"$kit/scripts/lib.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="${GDC_TEST_KIT:?}"
load_project() {
  ROOT="${GDC_TEST_KIT:?}"
  GDC_DATA_ROOT="${GDC_TEST_OPERATOR:?}"
  GDC_HOME="$GDC_DATA_ROOT/operator"
  STATE="$GDC_DATA_ROOT/operator/state"
}
topology_contains_node() { [[ "$1" == "${GDC_CASE_PARENT:?}" ]]; }
ssh_ready() {
  echo "unexpected duplicate SSH readiness probe: $1" >&2
  exit 93
}
die() { printf '%s\n' "$*" >&2; exit 1; }
step() { printf 'step:%s\n' "$*" >>"$GDC_TEST_EVENTS"; }
SH
cat >"$kit/scripts/check-running-network-node.sh" <<'SH'
#!/usr/bin/env bash
[[ "$1" == "${GDC_CASE_PARENT:?}" ]]
printf 'parent-ready:%s\n' "$1" >>"$GDC_TEST_EVENTS"
SH
cat >"$kit/scripts/node-container-control.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$GDC_TEST_EVENTS"
case "$1" in
  stop) [[ "$#" == 2 && "$2" == "${GDC_CASE_DONOR:?}" ]] ;;
  lend)
    [[ "$#" == 5 && "$2" == "${GDC_CASE_DONOR:?}" && "$3" == "${GDC_CASE_PARENT:?}" && "$4" == "${GDC_CASE_ENDPOINT:?}" && "$5" == "${GDC_CASE_NODE_ID:?}" ]]
    jq -cn --arg parent "$3" --arg endpoint "$4" --arg node_id "$5" \
      '{schema_version:1,kind:"gdc-lent-validator-ml",parent_alias:$parent,endpoint:$endpoint,node_id:$node_id}' >"$GDC_TEST_REMOTE_RECORD"
    ;;
  reclaim)
    [[ "$#" == 2 && "$2" == "${GDC_CASE_DONOR:?}" ]]
    rm -f -- "$GDC_TEST_REMOTE_RECORD"
    ;;
  start) [[ "$#" == 2 && "$2" == "${GDC_CASE_DONOR:?}" ]] ;;
  *) exit 97 ;;
esac
SH
cat >"$kit/scripts/detach-network-ml-host.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == --network && "$2" == "${GDC_CASE_PARENT:?}" ]]
[[ "$3" == --ml-host && "$4" == "${GDC_CASE_DONOR:?}" ]]
[[ "$5" == --data-root && "$6" == "${GDC_TEST_OPERATOR:?}" ]]
[[ "$7" == --run-dir && "$8" == /* ]]
[[ "$9" == --expected-endpoint && "${10}" == "${GDC_CASE_ENDPOINT:?}" ]]
[[ "${11}" == --expected-node-id && "${12}" == "${GDC_CASE_NODE_ID:?}" ]]
printf 'detach:%s:%s\n' "$2" "$4" >>"$GDC_TEST_EVENTS"
SH
chmod 0755 "$kit/scripts"/*.sh

cat >"$tmp/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$1" == -G ]]; then
  [[ "$2" == "${GDC_CASE_DONOR:?}" && "${GDC_CASE_DISCOVERY_ALLOWED:?}" == true ]] || exit 91
  printf 'hostname %s\n' "$GDC_CASE_DISCOVERED_ENDPOINT"
  exit 0
fi
host=''
for arg in "$@"; do
  [[ "$arg" == "$GDC_CASE_PARENT" || "$arg" == "$GDC_CASE_DONOR" ]] && { host="$arg"; break; }
done
[[ -n "$host" ]] || exit 92
args="$*"
printf '%s|%s\n' "$host" "$args" >>"$GDC_TEST_SSH_LOG"
case "$host:$args" in
  "$GDC_CASE_DONOR":*'test -s /srv/dai/identity/p2p/node_key.json'*)
    [[ "$args" != *'/srv/dai/deploy/compose.yaml'* ]] || exit 93
    exit 0
    ;;
  "$GDC_CASE_DONOR":*'gdc-lent-ml-record'*)
    [[ -f "$GDC_TEST_REMOTE_RECORD" ]] && cat "$GDC_TEST_REMOTE_RECORD"
    ;;
  "$GDC_CASE_DONOR":*'lent-ml.json'*)
    [[ -f "$GDC_TEST_REMOTE_RECORD" ]] && cat "$GDC_TEST_REMOTE_RECORD" || exit 10
    ;;
  "$GDC_CASE_DONOR":*'cat /srv/dai/deploy/node-config.json'*) cat "$GDC_TEST_DONOR_CONFIG" ;;
  "$GDC_CASE_PARENT":*'cat /srv/dai/deploy/node-config.json'*) cat "$GDC_TEST_CONFIG" ;;
  "$GDC_CASE_PARENT":*'getent ahostsv4'*)
    printf 'parent-resolved:%s\n' "$GDC_CASE_ENDPOINT" >>"$GDC_TEST_EVENTS"
    if [[ "$GDC_CASE_ENDPOINT" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s\n' "$GDC_CASE_ENDPOINT"
    else
      printf '192.0.2.17\n'
    fi
    ;;
  "$GDC_CASE_PARENT":*'/v1/models'*) printf '{"data":[]}' ;;
  "$GDC_CASE_PARENT":*'node-config.json.tmp'*) cp "$GDC_TEST_STAGED_CONFIG" "$GDC_TEST_CONFIG" ;;
  "$GDC_CASE_PARENT":*'admin/v1/nodes'*)
    jq -cn --arg id "$GDC_CASE_NODE_ID" --arg host "$GDC_CASE_ENDPOINT" \
      '[{node:{id:$id,host:$host,inference_port:5000,poc_port:5000}}]'
    ;;
  "$GDC_CASE_PARENT":*'install_path=/srv/dai/deploy/gdc-ml-link.json'*) cat >"$GDC_TEST_REMOTE_LINK" ;;
  "$GDC_CASE_PARENT":*'cat /srv/dai/deploy/gdc-ml-link.json'*) cat "$GDC_TEST_LINK" ;;
  "$GDC_CASE_PARENT":*'rm -rf'*'gdc-ml-lend-'*) exit 0 ;;
  *) echo "unexpected ssh: $host $args" >&2; exit 93 ;;
esac
SH
cat >"$tmp/bin/scp" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$GDC_TEST_SCP_LOG"
[[ "$1" == -q && "$#" == 3 && "$3" == "$GDC_CASE_PARENT":/tmp/gdc-ml-lend-* ]] || exit 94
case "$2" in
  "$GDC_TEST_KIT"/02-node/sync-node-config.sh) ;;
  */node-config.next.json) cp "$2" "$GDC_TEST_STAGED_CONFIG" ;;
  *) echo "unexpected scp source: $2" >&2; exit 95 ;;
esac
SH
chmod 0755 "$tmp/bin/ssh" "$tmp/bin/scp"

has_line() {
  local file="$1" expected="$2" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "$expected" ]] && return 0
  done <"$file"
  return 1
}

has_text() {
  local file="$1" expected="$2"
  [[ "$(<"$file")" == *"$expected"* ]]
}

first_text_line() {
  local file="$1" expected="$2" line number=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    number=$((number + 1))
    [[ "$line" == *"$expected"* ]] && { printf '%s\n' "$number"; return 0; }
  done <"$file"
  return 1
}

count_text_lines() {
  local file="$1" expected="$2" line count=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *"$expected"* ]] && count=$((count + 1))
  done <"$file"
  printf '%s\n' "$count"
}

run_case() {
  local label="$1" parent="$2" donor="$3" endpoint="$4" discovered="$5" explicit="$6" mode="${7:-fresh}"
  local work operator config donor_config link events ssh_log scp_log output remote_record remote_parent_link start_output recorded_id run_rc
  work="$tmp/$label"
  operator="$work/operator"
  config="$work/node-config.json"
  donor_config="$work/donor-node-config.json"
  link="$work/link.json"
  events="$work/events"
  ssh_log="$work/ssh.log"
  scp_log="$work/scp.log"
  output="$work/output"
  remote_record="$work/lent-ml.json"
  remote_parent_link="$work/parent-gdc-ml-link.json"
  start_output="$work/start-output"
  local base_id node_id
  base_id="qwen3-4b:gonka-${label}-parent"
  node_id="qwen3-0.6b:gonka-${label}-parent--${donor}"
  mkdir -p "$operator"
  printf '%s\n' "[{\"id\":\"$base_id\",\"host\":\"inference\",\"inference_port\":5000,\"poc_port\":5000,\"max_concurrent\":32,\"models\":{\"Qwen/Qwen3-4B-Instruct-2507\":{\"args\":[\"--revision\",\"4b-parent-revision\",\"--dtype\",\"half\",\"--max-num-seqs\",\"8\"]}}},{\"id\":\"$base_id--baseline\",\"host\":\"baseline.$label.example.test\",\"inference_port\":5000,\"poc_port\":5000}]" >"$config"
  printf '%s\n' '{"id":"qwen3-0.6b:donor","host":"inference","models":{"Qwen/Qwen3-0.6B":{"args":["--tensor-parallel-size","1","--dtype","float16","--revision","c1899de289a04d12100db370d81485cdf75e47ca","--max-num-seqs","32","--gpu-memory-utilization","0.45","--max-model-len","2048","--kv-cache-dtype","auto","--kv-cache-memory-bytes","4294967296","--enforce-eager"]}}}' | jq -s . >"$donor_config"
  printf '%s\n' "{\"schema_version\":2,\"validator_alias\":\"$parent\",\"ml_hosts\":[{\"ssh_alias\":\"baseline-$label\",\"endpoint\":\"baseline.$label.example.test\",\"node_id\":\"$base_id--baseline\"}]}" >"$link"
  if [[ "$mode" == parent-conflict ]]; then
    jq --arg endpoint "$endpoint" '. + [{id:"conflicting-parent-id",host:$endpoint,inference_port:5000,poc_port:5000}]' "$config" >"$work/node-config.conflict.json"
    mv "$work/node-config.conflict.json" "$config"
  fi
  if [[ "$mode" == interrupted || "$mode" == bad-id || "$mode" == parent-conflict ]]; then
    recorded_id="$node_id"
    [[ "$mode" != bad-id ]] || recorded_id="$node_id-wrong"
    jq -cn --arg parent "$parent" --arg endpoint "$endpoint" --arg node_id "$recorded_id" \
      '{schema_version:1,kind:"gdc-lent-validator-ml",parent_alias:$parent,endpoint:$endpoint,node_id:$node_id,deployment:"/srv/dai/deploy"}' >"$remote_record"
  fi
  cp "$config" "$work/node-config.before.json"
  cp "$link" "$work/link.before.json"
  [[ ! -e "$remote_record" ]] || cp "$remote_record" "$work/lent-ml.before.json"
  : >"$events"; : >"$ssh_log"; : >"$scp_log"
  run_rc=0
  env PATH="$tmp/bin:$PATH" GDC_TEST_KIT="$kit" GDC_TEST_OPERATOR="$operator" \
    GDC_TEST_EVENTS="$events" GDC_TEST_SSH_LOG="$ssh_log" GDC_TEST_SCP_LOG="$scp_log" \
    GDC_TEST_CONFIG="$config" GDC_TEST_STAGED_CONFIG="$work/staged-node-config.json" GDC_TEST_DONOR_CONFIG="$donor_config" GDC_TEST_LINK="$link" GDC_TEST_REMOTE_RECORD="$remote_record" GDC_TEST_REMOTE_LINK="$remote_parent_link" \
    GDC_DATA_ROOT="$operator" GDC_HOME="$operator/operator" \
    GDC_CASE_PARENT="$parent" GDC_CASE_DONOR="$donor" GDC_CASE_ENDPOINT="$endpoint" \
    GDC_CASE_NODE_ID="$node_id" GDC_CASE_DISCOVERED_ENDPOINT="$discovered" \
    GDC_CASE_DISCOVERY_ALLOWED="$([[ -z "$explicit" ]] && printf true || printf false)" \
    GDC_RUN_ID="fixture-$label" \
    bash "$kit/scripts/phase-ml-lend.sh" "$parent" "$explicit" "$donor" >"$output" 2>&1 || run_rc=$?

  if [[ "$mode" == bad-id || "$mode" == parent-conflict ]]; then
    [[ "$run_rc" == 195 ]] || { cat "$output" >&2; echo "expected guarded refusal for $mode (exit 195), got $run_rc" >&2; exit 1; }
    has_text "$output" 'OPERATOR ACTION REQUIRED'
    if has_text "$events" "lend $donor $parent $endpoint $node_id"; then exit 1; fi
    if has_text "$events" "start-local-ml:$donor"; then exit 1; fi
    [[ ! -s "$scp_log" ]]
    [[ -s "$remote_record" ]]
    cmp -s "$config" "$work/node-config.before.json"
    cmp -s "$link" "$work/link.before.json"
    cmp -s "$remote_record" "$work/lent-ml.before.json"
    [[ ! -e "$remote_parent_link" ]]
    return 0
  fi
  [[ "$run_rc" == 0 ]] || { cat "$output" >&2; echo "lend failed for $mode (exit $run_rc)" >&2; exit 1; }

  has_line "$events" "lend $donor $parent $endpoint $node_id"
  has_line "$events" "start-local-ml:$donor Qwen/Qwen3-0.6B c1899de289a04d12100db370d81485cdf75e47ca float16 1 32 0.45 2048 [\"--tensor-parallel-size\",\"1\",\"--dtype\",\"float16\",\"--revision\",\"c1899de289a04d12100db370d81485cdf75e47ca\",\"--max-num-seqs\",\"32\",\"--gpu-memory-utilization\",\"0.45\",\"--max-model-len\",\"2048\",\"--kv-cache-dtype\",\"auto\",\"--kv-cache-memory-bytes\",\"4294967296\",\"--enforce-eager\"]"
  jq -e --arg id "$node_id" --arg host "$endpoint" --arg baseline "baseline.$label.example.test" --slurpfile donor "$donor_config" '
    any(.[]; .id == $id and .host == $host and
      .models == $donor[0][0].models and .max_concurrent == 32)
    and any(.[]; .id | startswith("qwen3-4b:"))
    and any(.[]; .host == $baseline)
  ' "$config" >/dev/null
  has_line "$events" "parent-ready:$parent"
  resolve_line="$(first_text_line "$events" "parent-resolved:$endpoint")"
  lend_line="$(first_text_line "$events" "lend $donor $parent $endpoint $node_id")"
  [[ "$resolve_line" =~ ^[1-9][0-9]*$ && "$lend_line" =~ ^[1-9][0-9]*$ && "$resolve_line" -lt "$lend_line" ]]
  jq -e --arg parent "$parent" --arg donor "$donor" --arg endpoint "$endpoint" --arg node_id "$node_id" '
    .network_alias == $parent and .ml_alias == $donor and .endpoint == $endpoint and .node_id == $node_id
  ' "$operator/$donor/state/ml-parent.json" >/dev/null
  jq -e --arg parent "$parent" --arg baseline "baseline-$label" --arg donor "$donor" --arg endpoint "$endpoint" --arg node_id "$node_id" '
    any(.ml_hosts[]; .ssh_alias == $baseline)
    and any(.ml_hosts[]; .ssh_alias == $donor and .endpoint == $endpoint and .node_id == $node_id and .ownership == "lent_validator")
  ' "$operator/operator/state/ml-attached/$parent.json" >/dev/null
  jq -e --arg parent "$parent" --arg baseline "baseline-$label" --arg donor "$donor" --arg endpoint "$endpoint" --arg node_id "$node_id" '
    .schema_version == 2 and .validator_alias == $parent and
    any(.ml_hosts[]; .ssh_alias == $baseline) and
    any(.ml_hosts[]; .ssh_alias == $donor and .endpoint == $endpoint and .node_id == $node_id and .ownership == "lent_validator")
  ' "$remote_parent_link" >/dev/null
  has_text "$ssh_log" "$parent|"
  has_text "$ssh_log" "$donor|"
  [[ "$(count_text_lines "$ssh_log" '|')" -ge 6 ]]
  [[ -s "$remote_record" ]]

  env PATH="$tmp/bin:$PATH" GDC_TEST_KIT="$kit" GDC_TEST_OPERATOR="$operator" \
    GDC_TEST_EVENTS="$events" GDC_TEST_SSH_LOG="$ssh_log" GDC_TEST_SCP_LOG="$scp_log" \
    GDC_TEST_CONFIG="$config" GDC_TEST_STAGED_CONFIG="$work/staged-node-config.json" GDC_TEST_DONOR_CONFIG="$donor_config" GDC_TEST_LINK="$link" GDC_TEST_REMOTE_RECORD="$remote_record" GDC_TEST_REMOTE_LINK="$remote_parent_link" \
    GDC_DATA_ROOT="$operator" GDC_HOME="$operator/operator" \
    GDC_CASE_PARENT="$parent" GDC_CASE_DONOR="$donor" GDC_CASE_ENDPOINT="$endpoint" \
    GDC_CASE_NODE_ID="$node_id" GDC_CASE_DISCOVERED_ENDPOINT="$discovered" \
    GDC_CASE_DISCOVERY_ALLOWED=false GDC_RUN_ID="fixture-$label" \
    bash "$kit/scripts/phase-node-lent-start.sh" "$donor" >"$start_output"
  has_line "$events" "detach:$parent:$donor"
  has_line "$events" "reclaim $donor"
  has_line "$events" "start $donor"
  [[ ! -e "$remote_record" ]]
  if [[ -z "$explicit" ]]; then
    has_text "$output" "READY $parent uses the stopped validator ML runtime of $donor; run gdc host start $donor to reclaim it"
  else
    if has_text "$ssh_log" '-G '; then exit 1; fi
  fi
}

run_case alpha controller.alpha accelerator-west_2 gpu-west.alpha.example.test gpu-west.alpha.example.test ''
run_case beta validator-z9 gpu-borrower 198.51.100.37 ignored.example.test 198.51.100.37
run_case interrupted validator-resume gpu-resume gpu-resume.example.test ignored.example.test gpu-resume.example.test interrupted
run_case bad-id validator-bad-id gpu-bad-id gpu-bad-id.example.test ignored.example.test gpu-bad-id.example.test bad-id
run_case parent-conflict validator-conflict gpu-conflict gpu-conflict.example.test ignored.example.test gpu-conflict.example.test parent-conflict

printf '%s\n' '[{"id":"qwen3-4b:gonka-parent","host":"inference","inference_port":5000,"poc_port":5000,"models":{"Qwen/Qwen3-4B-Instruct-2507":{"args":["--dtype","half"]}}}]' >"$tmp/legacy-4b-parent.json"
printf '%s\n' '{"id":"qwen3-4b:short-worker-id","host":"inference","models":{"Qwen/Qwen3-4B-Instruct-2507":{"args":["--revision","legacy-4b-revision","--dtype","float16"]}}}' | jq -s . >"$tmp/legacy-4b-donor.json"
"$ROOT/scripts/add-network-ml-endpoint.sh" --input "$tmp/legacy-4b-parent.json" --ml-host gpu.example.test --ml-alias donor --models-config "$tmp/legacy-4b-donor.json" --output "$tmp/legacy-4b-output.json" --id-output "$tmp/legacy-4b-id"
[[ "$(<"$tmp/legacy-4b-id")" == 'qwen3-4b-instruct-2507:gonka-parent--donor' ]]
jq -e --slurpfile donor "$tmp/legacy-4b-donor.json" '
  length == 2 and
  .[1].id == "qwen3-4b-instruct-2507:gonka-parent--donor" and
  .[1].models == $donor[0][0].models and
  .[0].id == "qwen3-4b:gonka-parent"
' "$tmp/legacy-4b-output.json" >/dev/null

printf 'PASS ML lending resumes only a matching interrupted identity, rejects conflicts before mutation, and preserves return behavior across independent pairs\n'
