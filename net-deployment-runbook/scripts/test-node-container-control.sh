#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/deploy" "$tmp/home"
export CONTROL_TEST_ROOT="$tmp"
cat >"$tmp/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
# The production script is executed unchanged except for its fixed Host paths.
sed "s@/srv/dai/deploy@$CONTROL_TEST_ROOT/deploy@g; s@/srv/dai@$CONTROL_TEST_ROOT@g" >"$CONTROL_TEST_ROOT/remote.sh"
remote_command="${*: -1}"
node_alias="${remote_command##* }"
node_alias="${node_alias//\'/}"
case "$remote_command" in
  *gdc-lent-ml-record*) exit 0 ;;
  *"'stop'"*) bash "$CONTROL_TEST_ROOT/remote.sh" stop '' '' '' "$node_alias" ;;
  *"'start'"*) bash "$CONTROL_TEST_ROOT/remote.sh" start '' '' '' "$node_alias" ;;
  *) exit 99 ;;
esac
SH
cat >"$tmp/bin/stat" <<'SH'
#!/usr/bin/env bash
if [[ "$1 $2" == '-c %u' ]]; then echo 0; else /usr/bin/stat "$@"; fi
SH
cat >"$tmp/bin/mkdir" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${*: -1}" == */.node-control/lock && -f "$CONTROL_TEST_ROOT/concurrent-start" ]]; then
  jq 'map(.running=true | .status="running")' "$CONTROL_TEST_ROOT/containers.json" >"$CONTROL_TEST_ROOT/concurrent.json"
  mv "$CONTROL_TEST_ROOT/concurrent.json" "$CONTROL_TEST_ROOT/containers.json"
  rm "$CONTROL_TEST_ROOT/concurrent-start"
fi
if [[ "${*: -1}" == */.node-control/lock && -f "$CONTROL_TEST_ROOT/concurrent-add" ]]; then
  jq --slurpfile extra "$CONTROL_TEST_ROOT/concurrent-add" '. + $extra' "$CONTROL_TEST_ROOT/containers.json" >"$CONTROL_TEST_ROOT/concurrent.json"
  mv "$CONTROL_TEST_ROOT/concurrent.json" "$CONTROL_TEST_ROOT/containers.json"
  rm "$CONTROL_TEST_ROOT/concurrent-add"
fi
exec /usr/bin/mkdir "$@"
SH
cat >"$tmp/bin/docker" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
state="$CONTROL_TEST_ROOT/containers.json"
case "$1" in
  ps) jq -r '.[].id' "$state" ;;
  inspect)
    id="${*: -1}"
    if [[ "$3" == '{{.State.Running}}' ]]; then
      jq -er --arg id "$id" '.[] | select(.id == $id) | .running | tostring' "$state"
    else
      jq -ce --arg id "$id" '.[] | select(.id == $id)' "$state"
    fi ;;
  stop|start)
    id="${*: -1}"
    printf '%s %s\n' "$1" "$id" >>"$CONTROL_TEST_ROOT/operations"
    running=false; status=exited
    [[ "$1" != start ]] || { running=true; status=running; }
    jq --arg id "$id" --argjson running "$running" --arg status "$status" \
      'map(if .id == $id then .running=$running | .status=$status else . end)' "$state" >"$state.tmp"
    mv "$state.tmp" "$state" ;;
  *) echo "unexpected Docker mutation: $*" >&2; exit 99 ;;
esac
SH
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH"
node_id="$(printf '%064d' 1)"; signer_id="$(printf '%064d' 2)"; unused_id="$(printf '%064d' 3)"
jq -n --arg dir "$tmp/deploy" --arg node "$node_id" --arg signer "$signer_id" --arg unused "$unused_id" '[
 {id:$node,project:"fixture",service:"node",running:true,status:"running"},
 {id:$signer,project:"fixture",service:"tmkms",running:true,status:"running"},
 {id:$unused,project:"fixture",service:"inference",running:false,status:"created"}
] | map(.working_dir=$dir)' >"$tmp/containers.json"
# Exercise the operator-facing aliases. `host stop/start` must dispatch to the
# same receipt-bound controller rather than retaining a second lifecycle path
# behind the public CLI.
run_for() {
  local action="$1" alias="$2" log="$tmp/$1.log"
  [[ "$alias" == fixture ]] || log="$tmp/$1-$alias.log"
  env -i PATH="$PATH" CONTROL_TEST_ROOT="$tmp" GDC_HOME="$tmp/operator" \
    bash "$ROOT/gdc.sh" host "$action" "$alias" >"$log" 2>&1
}
run() { run_for "$1" fixture; }
run stop
[[ "$(head -1 "$tmp/operations")" == "stop $signer_id" ]]
jq -e 'all(.[]; .running == false)' "$tmp/containers.json" >/dev/null
cp "$tmp/deploy/.node-control/stopped.json" "$tmp/receipt.json"
run stop
cmp "$tmp/receipt.json" "$tmp/deploy/.node-control/stopped.json"
run start
jq -e 'all(.[]; if .service == "inference" then .running == false else .running end)' "$tmp/containers.json" >/dev/null
[[ "$(tail -1 "$tmp/operations")" == "start $signer_id" ]]
[[ ! -e "$tmp/home/fixture/state/active-run-id" ]]
run start
run stop
jq 'map(if .service == "tmkms" then .id=("a" * 64) else . end)' "$tmp/containers.json" >"$tmp/changed"
mv "$tmp/changed" "$tmp/containers.json"
cp "$tmp/operations" "$tmp/before"
if run start; then echo 'replacement signer unexpectedly started' >&2; exit 1; fi
cmp "$tmp/before" "$tmp/operations"
grep -q 'containers changed since stop' "$tmp/start.log"
# A signer fenced before stop is not enabled by the subsequent start.
rm "$tmp/deploy/.node-control/stopped.json"
jq 'map(if .service == "node" then .running=true | .status="running" else .running=false | .status="exited" end)' "$tmp/containers.json" >"$tmp/changed"
mv "$tmp/changed" "$tmp/containers.json"
run stop
run start
jq -e 'all(.[]; if .service == "node" then .running else .running == false end)' "$tmp/containers.json" >/dev/null
cp "$tmp/operations" "$tmp/before"
if run start; then echo 'missing restart authority unexpectedly accepted' >&2; exit 1; fi
cmp "$tmp/before" "$tmp/operations"
# Canonical deployments work with an unrelated operator SSH alias
# Shared edge/monitoring projects must never enter the restart receipt.
deploy="$tmp/deploy"
mkdir -p "$deploy"
jq -n --arg dir "$deploy" --arg node "$node_id" --arg signer "$signer_id" --arg foreign "$unused_id" '[
  {id:$node,project:"original-project",working_dir:$dir,service:"node",running:true,status:"running"},
  {id:$signer,project:"original-project",working_dir:$dir,service:"tmkms",running:true,status:"running"},
  {id:$foreign,project:"edge",working_dir:($dir+"/edge"),service:"caddy",running:true,status:"running"}
]' >"$tmp/containers.json"
: >"$tmp/operations"
run stop
jq -e --arg id "$unused_id" '.[] | select(.id==$id) | .running' "$tmp/containers.json" >/dev/null
run start
if grep -q "$unused_id" "$tmp/operations"; then exit 1; fi
jq -e 'all(.[]; .running)' "$tmp/containers.json" >/dev/null
# A retired validator must also be refused alongside a canonical deployment
cp "$tmp/containers.json" "$tmp/canonical.json"
cp "$tmp/operations" "$tmp/before"
jq --arg dir "$tmp/deploy/retired" '. + [.[0] | .id=("d"*64) | .working_dir=$dir | .project="retired"]' "$tmp/canonical.json" >"$tmp/containers.json"
if run stop; then echo 'mixed layouts unexpectedly stopped' >&2; exit 1; fi
cmp "$tmp/before" "$tmp/operations"
grep -Fq 'unsupported or mixed validator deployment directories' "$tmp/stop.log"
cp "$tmp/canonical.json" "$tmp/containers.json"
# Two Core deployments are ambiguous even when the alias matches one of them.
jq --arg dir "$tmp/deploy" '. + [.[0] | .id=("b"*64) | .working_dir=$dir | .project="fixture"]' "$tmp/containers.json" >"$tmp/changed"
mv "$tmp/changed" "$tmp/containers.json"
cp "$tmp/operations" "$tmp/before"
if run stop; then echo 'ambiguous deployments unexpectedly stopped' >&2; exit 1; fi
cmp "$tmp/before" "$tmp/operations"
grep -q 'none or multiple found' "$tmp/stop.log"
cp "$tmp/containers.json" "$tmp/ambiguous.json"
ln -s "$tmp/deploy" "$tmp/deploy/link"
for unsafe in "$tmp/node" "$tmp/deploy/old-validator-name" "$tmp/outside" "$tmp/deploy/../other" "$tmp/deploy/link"; do
  jq --arg dir "$unsafe" 'map(select(.project!="fixture")) | map(if .project=="original-project" then .working_dir=$dir else . end)' "$tmp/ambiguous.json" >"$tmp/containers.json"
  if run stop; then echo 'unsafe deployment path unexpectedly accepted' >&2; exit 1; fi
  cmp "$tmp/before" "$tmp/operations"
done
# Re-read runtime state after acquiring the lock, not before a concurrent start.
jq --arg dir "$tmp/deploy" 'map(select(.project=="original-project")) | map(.working_dir=$dir | .running=false | .status="exited")' "$tmp/ambiguous.json" >"$tmp/containers.json"
: >"$tmp/concurrent-start"
run stop
jq -e 'all(.[]; .running == false)' "$tmp/containers.json" >/dev/null
jq -e 'length == 2' "$tmp/deploy/.node-control/stopped.json" >/dev/null
run start
cp "$tmp/containers.json" "$tmp/baseline.json"
# Refuse an additional signer, stopped or running, including one created after
# discovery but before lock acquisition. A new application container also
# invalidates the complete stopped inventory instead of being silently ignored.
for timing in before-lock under-lock; do
  for extra in running-signer stopped-signer application; do
    cp "$tmp/baseline.json" "$tmp/containers.json"
    run stop
    cp "$tmp/deploy/.node-control/stopped.json" "$tmp/receipt-before"
    jq --arg extra "$extra" '.[0] | .id=("c"*64) |
      .service=(if $extra=="application" then "api" else "tmkms" end) |
      .running=($extra!="stopped-signer") |
      .status=(if .running then "running" else "exited" end)' "$tmp/baseline.json" >"$tmp/extra.json"
    if [[ "$timing" == under-lock ]]; then
      cp "$tmp/extra.json" "$tmp/concurrent-add"
    else
      jq --slurpfile extra "$tmp/extra.json" '. + $extra' "$tmp/containers.json" >"$tmp/changed"
      mv "$tmp/changed" "$tmp/containers.json"
    fi
    cp "$tmp/operations" "$tmp/before"
    if run start; then echo "additional container accepted: $timing $extra" >&2; exit 1; fi
    cmp "$tmp/before" "$tmp/operations"
    cmp "$tmp/receipt-before" "$tmp/deploy/.node-control/stopped.json"
    [[ ! -d "$tmp/deploy/.node-control/lock" ]]
    rm "$tmp/deploy/.node-control/stopped.json"
  done
done
# The node4 legacy layout is supported only when the exact alias path is
# bound to a Compose project with the same alias. Independent edge, broker,
# faucet and OPS projects must remain outside the controller receipt.
legacy_alias=gdc-node4
legacy_deploy="$tmp/deploy/$legacy_alias"
mkdir -p "$legacy_deploy"
legacy_node_id="$(printf '%064d' 11)"
legacy_signer_id="$(printf '%064d' 12)"
legacy_api_id="$(printf '%064d' 13)"
edge_id="$(printf '%064d' 14)"
broker_id="$(printf '%064d' 15)"
faucet_id="$(printf '%064d' 16)"
ops_id="$(printf '%064d' 17)"
jq -n --arg dir "$legacy_deploy" --arg node "$legacy_node_id" \
  --arg signer "$legacy_signer_id" --arg api "$legacy_api_id" \
  --arg edge "$edge_id" --arg broker "$broker_id" \
  --arg faucet "$faucet_id" --arg ops "$ops_id" '([
    {id:$node,project:"gdc-node4",working_dir:$dir,service:"node",running:true,status:"running"},
    {id:$signer,project:"gdc-node4",working_dir:$dir,service:"tmkms",running:true,status:"running"},
    {id:$api,project:"gdc-node4",working_dir:$dir,service:"api",running:true,status:"running"},
    {id:$edge,project:"gdc-edge",working_dir:"/srv/dai/edge",service:"caddy",running:true,status:"running"},
    {id:$broker,project:"gdc-v6-b",working_dir:"/srv/broker/b",service:"gateway",running:true,status:"running"},
    {id:$faucet,project:"gdc-faucet",working_dir:"/srv/faucet",service:"faucet",running:true,status:"running"},
    {id:$ops,project:"gdc-ops",working_dir:"/srv/dai/ops",service:"prometheus",running:true,status:"running"}
  ])' >"$tmp/containers.json"
: >"$tmp/operations"
run_for stop "$legacy_alias"
grep -Fq "READY discovered node deployment=$legacy_deploy" "$tmp/stop-$legacy_alias.log"
jq -e --arg alias "$legacy_alias" --arg dir "$legacy_deploy" '
  length == 3 and all(.[]; .project == $alias and .working_dir == $dir)
' "$legacy_deploy/.node-control/stopped.json" >/dev/null
for id in "$edge_id" "$broker_id" "$faucet_id" "$ops_id"; do
  jq -e --arg id "$id" '.[] | select(.id == $id) | .running' "$tmp/containers.json" >/dev/null
  if grep -q "$id" "$tmp/operations"; then exit 1; fi
done
run_for start "$legacy_alias"
jq -e 'all(.[]; .running)' "$tmp/containers.json" >/dev/null
for id in "$edge_id" "$broker_id" "$faucet_id" "$ops_id"; do
  if grep -q "$id" "$tmp/operations"; then exit 1; fi
done

# A correctly named path with the wrong Compose project is not enough to
# establish ownership, and a nested child path is never treated as legacy.
cp "$tmp/containers.json" "$tmp/legacy-clean.json"
jq --arg node "$legacy_node_id" '.[] |= (if .id == $node then .project="other-project" else . end)' \
  "$tmp/legacy-clean.json" >"$tmp/containers.json"
cp "$tmp/operations" "$tmp/before"
if run_for stop "$legacy_alias"; then echo 'legacy project mismatch unexpectedly accepted' >&2; exit 1; fi
cmp "$tmp/before" "$tmp/operations"
grep -Fq 'legacy Host deployment project must match its SSH alias' "$tmp/stop-$legacy_alias.log"
jq --arg node "$legacy_node_id" --arg dir "$legacy_deploy/child" \
  '.[] |= (if .id == $node then .working_dir=$dir else . end)' \
  "$tmp/legacy-clean.json" >"$tmp/containers.json"
if run_for stop "$legacy_alias"; then echo 'nested legacy path unexpectedly accepted' >&2; exit 1; fi
cmp "$tmp/before" "$tmp/operations"
grep -Fq 'unsupported or mixed validator deployment directories' "$tmp/stop-$legacy_alias.log"

printf 'PASS SSH-only stop/start preserves exact containers and refuses signer replacement\n'
