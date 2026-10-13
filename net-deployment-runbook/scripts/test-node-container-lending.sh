#!/usr/bin/env bash
# Exercise the installed-container lending primitive without a Host, SSH key,
# Docker daemon or network. The SSH fixture rejects all actions except the
# four exact lifecycle calls below.
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
mkdir -p "$tmp/bin" "$tmp/deploy"
export CONTROL_TEST_ROOT="$tmp"

cat >"$tmp/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
sed "s@/srv/dai/deploy@$CONTROL_TEST_DEPLOY@g; s@/srv/dai@$CONTROL_TEST_ROOT@g" >"$CONTROL_TEST_ROOT/remote.sh"
case "$*" in
  *"'stop'"*) bash "$CONTROL_TEST_ROOT/remote.sh" stop ;;
  *"'start'"*) bash "$CONTROL_TEST_ROOT/remote.sh" start ;;
  *"'lend'"*) bash "$CONTROL_TEST_ROOT/remote.sh" lend parent-alias gpu.example.test fixture-node ;;
  *"'reclaim'"*) bash "$CONTROL_TEST_ROOT/remote.sh" reclaim ;;
  *) exit 99 ;;
esac
SH
cat >"$tmp/bin/stat" <<'SH'
#!/usr/bin/env bash
if [[ "$1 $2" == '-c %u' ]]; then echo 0; else /usr/bin/stat "$@"; fi
SH
cat >"$tmp/bin/docker" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
state="$CONTROL_TEST_ROOT/containers.json"
set_state() { jq "$1" "$state" >"$state.tmp" && mv "$state.tmp" "$state"; }
case "$1" in
  ps) jq -r '.[].id' "$state" ;;
  inspect)
    id="${*: -1}"
    if [[ "$3" == '{{.State.Running}}' ]]; then
      jq -er --arg id "$id" '.[] | select(.id == $id) | .running | tostring' "$state"
    else
      jq -ce --arg id "$id" '.[] | select(.id == $id)' "$state"
    fi
    ;;
  stop|start)
    id="${*: -1}"
    printf '%s %s\n' "$1" "$id" >>"$CONTROL_TEST_ROOT/operations"
    if [[ "$1" == stop ]]; then
      set_state "map(if .id == \"$id\" then .running=false | .status=\"exited\" else . end)"
    else
      set_state "map(if .id == \"$id\" then .running=true | .status=\"running\" else . end)"
    fi
    ;;
  compose)
    command=" $* "
    if [[ "$command" == *' config '* ]]; then exit 0; fi
    if [[ "$command" == *' stop mlnode inference '* ]]; then
      set_state 'map(if .service == "mlnode" or .service == "inference" then .running=false | .status="exited" else . end)'
      exit 0
    fi
    if [[ "$command" == *' up '* ]]; then
      if [[ "${CONTROL_TEST_FAIL_LEND_UP:-false}" == true ]]; then
        echo 'injected ML startup failure' >&2
        exit 72
      fi
      replacement="$(printf '%064d' 9)"
      set_state "map(if .service == \"inference\" then .id=\"$replacement\" | .running=true | .status=\"running\" elif .service == \"mlnode\" then .running=true | .status=\"running\" else . end)"
      exit 0
    fi
    echo "unexpected compose invocation: $*" >&2; exit 99
    ;;
  *) echo "unexpected Docker invocation: $*" >&2; exit 99 ;;
esac
SH
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
export CONTROL_TEST_DEPLOY="$tmp/deploy"

printf '%s\n' true >"$tmp/deploy/.local-ml"
printf '%s\n' 'MLNODE_COMPOSE_VARIANT=nvidia' >"$tmp/deploy/.env"
: >"$tmp/deploy/compose.yaml"
: >"$tmp/deploy/compose.ml-local.yaml"
node_id="$(printf '%064d' 1)"
signer_id="$(printf '%064d' 2)"
mlnode_id="$(printf '%064d' 3)"
inference_id="$(printf '%064d' 4)"
jq -n --arg dir "$tmp/deploy" --arg node "$node_id" --arg signer "$signer_id" --arg mlnode "$mlnode_id" --arg inference "$inference_id" '[
  {id:$node,project:"fixture",service:"node",running:true,status:"running"},
  {id:$signer,project:"fixture",service:"tmkms",running:true,status:"running"},
  {id:$mlnode,project:"fixture",service:"mlnode",running:true,status:"running"},
  {id:$inference,project:"fixture",service:"inference",running:true,status:"running"}
] | map(.working_dir=$dir)' >"$tmp/containers.json"
cp "$tmp/containers.json" "$tmp/initial-containers.json"
: >"$tmp/operations"

control() {
  bash "$ROOT/scripts/node-container-control.sh" "$@" >"$tmp/$1.log" 2>&1
}

# A donor without an installed local ML runtime must be refused before the
# controlled stop receipt or any container operation is created.
printf '%s\n' false >"$tmp/deploy/.local-ml"
if control lend fixture parent-alias gpu.example.test fixture-node; then
  echo 'validator without local ML runtime unexpectedly entered lending' >&2
  exit 1
fi
grep -Fqx 'ERROR installed validator has no local ML runtime to lend' "$tmp/lend.log"
[[ ! -e "$tmp/deploy/.node-control/stopped.json" && ! -s "$tmp/operations" ]]
printf '%s\n' true >"$tmp/deploy/.local-ml"

# A dangling ownership record is not an absent record. The real controller
# must reject it before it creates a stop receipt or changes any container.
ln -s /missing/lent-ml.json "$tmp/deploy/.node-control/lent-ml.json"
if control lend fixture parent-alias gpu.example.test fixture-node; then
  echo 'dangling lending record unexpectedly entered lending' >&2
  exit 1
fi
grep -Fqx 'ERROR unsafe lending control record' "$tmp/lend.log"
[[ -L "$tmp/deploy/.node-control/lent-ml.json" ]]
[[ ! -e "$tmp/deploy/.node-control/stopped.json" && ! -s "$tmp/operations" ]]
rm -f "$tmp/deploy/.node-control/lent-ml.json"

control lend fixture parent-alias gpu.example.test fixture-node
jq -e '
  .schema_version == 1 and .kind == "gdc-lent-validator-ml" and
  .parent_alias == "parent-alias" and .endpoint == "gpu.example.test" and .node_id == "fixture-node"
' "$tmp/deploy/.node-control/lent-ml.json" >/dev/null
expected_lending_overlay=$'services:\n  inference:\n    ports:\n      - "0.0.0.0:5000:5000/tcp"'
[[ "$(<"$tmp/deploy/.node-control/lent-ml-port.yaml")" == "$expected_lending_overlay" ]]
jq -e 'all(.[]; if .service == "mlnode" or .service == "inference" then .running else (.running | not) end)' "$tmp/containers.json" >/dev/null

cp "$tmp/operations" "$tmp/before-start"
if control start fixture; then
  echo 'a lent validator unexpectedly started before its parent was detached' >&2
  exit 1
fi
cmp "$tmp/before-start" "$tmp/operations"

control reclaim fixture
[[ ! -e "$tmp/deploy/.node-control/lent-ml.json" && ! -e "$tmp/deploy/.node-control/lent-ml-port.yaml" ]]
jq -e 'all(.[]; .running == false)' "$tmp/containers.json" >/dev/null
control start fixture
jq -e 'all(.[]; .running)' "$tmp/containers.json" >/dev/null
[[ ! -e "$tmp/deploy/.node-control/stopped.json" ]]

# A failure after the controlled stop must retain the stopped donor, without
# claiming that its ML runtime is lent. Repeating lend resumes that same
# receipt-bound transition; it does not reset or recreate validator state.
: >"$tmp/operations"
if CONTROL_TEST_FAIL_LEND_UP=true control lend fixture parent-alias gpu.example.test fixture-node; then
  echo 'injected ML startup failure unexpectedly completed lending' >&2
  exit 1
fi
[[ -f "$tmp/deploy/.node-control/stopped.json" && ! -e "$tmp/deploy/.node-control/lent-ml.json" ]]
jq -e 'all(.[]; .running | not)' "$tmp/containers.json" >/dev/null
# A receipt is not permission to resume after somebody has bypassed the
# controller and started consensus services. Lending must refuse until the
# operator has returned to the same stopped runtime state.
docker start "$node_id"
if control lend fixture parent-alias gpu.example.test fixture-node; then
  echo 'lending resumed after the validator was manually started' >&2
  exit 1
fi
grep -Fqx 'ERROR controlled validator is no longer stopped; refuse lending after an interrupted transition' "$tmp/lend.log"
[[ ! -e "$tmp/deploy/.node-control/lent-ml.json" ]]
docker stop "$node_id"
control lend fixture parent-alias gpu.example.test fixture-node
jq -e 'all(.[]; if .service == "mlnode" or .service == "inference" then .running else (.running | not) end)' "$tmp/containers.json" >/dev/null
# The same receipt cannot authorize reclaim if consensus services were started
# after a completed lend. Keep both the owned ML runtime and lending record
# until the operator restores the stopped validator state.
docker start "$node_id"
if control reclaim fixture; then
  echo 'reclaim continued after the validator was manually started' >&2
  exit 1
fi
grep -Fqx 'ERROR controlled validator is no longer stopped; refuse reclaim while the validator may be signing' "$tmp/reclaim.log"
[[ -e "$tmp/deploy/.node-control/lent-ml.json" && -e "$tmp/deploy/.node-control/lent-ml-port.yaml" ]]
jq -e 'all(.[]; if .service == "mlnode" or .service == "inference" or .service == "node" then .running else (.running | not) end)' "$tmp/containers.json" >/dev/null
docker stop "$node_id"
control reclaim fixture
control start fixture
jq -e 'all(.[]; .running)' "$tmp/containers.json" >/dev/null
[[ ! -e "$tmp/deploy/.node-control/stopped.json" && ! -e "$tmp/deploy/.node-control/lent-ml.json" ]]

# The retained legacy deployment directory is a supported layout too. Lending
# must discover it from Compose labels rather than the SSH alias or flat path.
legacy="$tmp/deploy/legacy-node"
mkdir -p "$legacy"
cp "$tmp/deploy/.local-ml" "$tmp/deploy/.env" "$tmp/deploy/compose.yaml" "$tmp/deploy/compose.ml-local.yaml" "$legacy/"
jq --arg dir "$legacy" 'map(.working_dir = $dir)' "$tmp/initial-containers.json" >"$tmp/containers.json.next"
mv "$tmp/containers.json.next" "$tmp/containers.json"
export CONTROL_TEST_DEPLOY="$legacy"
: >"$tmp/operations"
control lend fixture parent-alias gpu.example.test fixture-node
jq -e '.deployment == $deploy' --arg deploy "$legacy" "$legacy/.node-control/lent-ml.json" >/dev/null
control reclaim fixture
control start fixture
jq -e 'all(.[]; .running)' "$tmp/containers.json" >/dev/null
[[ ! -e "$legacy/.node-control/stopped.json" ]]
printf 'PASS installed validator ML lending retains the stopped validator receipt and requires reclaim before restart\n'
