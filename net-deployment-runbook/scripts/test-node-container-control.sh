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
case "${*: -1}" in
  *"'stop'") bash "$CONTROL_TEST_ROOT/remote.sh" stop ;;
  *"'start'") bash "$CONTROL_TEST_ROOT/remote.sh" start ;;
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
run() { env -i HOME="$tmp/home" PATH="$PATH" CONTROL_TEST_ROOT="$tmp" GDC_HOME="$tmp/home" bash "$ROOT/gdc.sh" node "$1" fixture >"$tmp/$1.log" 2>&1; }
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
# Flat and legacy deployments work with an unrelated operator SSH alias.
# Shared edge/monitoring projects must never enter the restart receipt.
for deploy in "$tmp/deploy" "$tmp/deploy/old-validator-name"; do
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
  ! grep -q "$unused_id" "$tmp/operations"
  jq -e 'all(.[]; .running)' "$tmp/containers.json" >/dev/null
done
# Two Core deployments are ambiguous even when the alias matches one of them.
jq --arg dir "$tmp/deploy" '. + [.[0] | .id=("b"*64) | .working_dir=$dir | .project="fixture"]' "$tmp/containers.json" >"$tmp/changed"
mv "$tmp/changed" "$tmp/containers.json"
cp "$tmp/operations" "$tmp/before"
if run stop; then echo 'ambiguous deployments unexpectedly stopped' >&2; exit 1; fi
cmp "$tmp/before" "$tmp/operations"
grep -q 'none or multiple found' "$tmp/stop.log"
cp "$tmp/containers.json" "$tmp/ambiguous.json"
ln -s "$tmp/deploy/old-validator-name" "$tmp/deploy/link"
for unsafe in "$tmp/outside" "$tmp/deploy/../other" "$tmp/deploy/link"; do
  jq --arg dir "$unsafe" 'map(select(.project!="fixture")) | map(if .project=="original-project" then .working_dir=$dir else . end)' "$tmp/ambiguous.json" >"$tmp/containers.json"
  if run stop; then echo 'unsafe deployment path unexpectedly accepted' >&2; exit 1; fi
  cmp "$tmp/before" "$tmp/operations"
done
# Re-read runtime state after acquiring the lock, not before a concurrent start.
jq --arg dir "$tmp/deploy/old-validator-name" 'map(select(.project=="original-project")) | map(.working_dir=$dir | .running=false | .status="exited")' "$tmp/ambiguous.json" >"$tmp/containers.json"
: >"$tmp/concurrent-start"
run stop
jq -e 'all(.[]; .running == false)' "$tmp/containers.json" >/dev/null
jq -e 'length == 2' "$tmp/deploy/old-validator-name/.node-control/stopped.json" >/dev/null
run start
cp "$tmp/containers.json" "$tmp/baseline.json"
# Refuse an additional signer, stopped or running, including one created after
# discovery but before lock acquisition. A new application container also
# invalidates the complete stopped inventory instead of being silently ignored.
for timing in before-lock under-lock; do
  for extra in running-signer stopped-signer application; do
    cp "$tmp/baseline.json" "$tmp/containers.json"
    run stop
    cp "$tmp/deploy/old-validator-name/.node-control/stopped.json" "$tmp/receipt-before"
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
    cmp "$tmp/receipt-before" "$tmp/deploy/old-validator-name/.node-control/stopped.json"
    [[ ! -d "$tmp/deploy/old-validator-name/.node-control/lock" ]]
    rm "$tmp/deploy/old-validator-name/.node-control/stopped.json"
  done
done
printf 'PASS SSH-only stop/start preserves exact containers and refuses signer replacement\n'
