#!/usr/bin/env bash
# Exercise the real detach helper through an allowlisted SSH/SCP transport.
# It proves that DAPI readback and persistent configuration removal happen
# before the donor ownership record may be released.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
cleanup() {
  if [[ -n "${GDC_TEST_KEEP_TMP:-}" ]]; then
    printf 'retained fixture: %s\n' "$tmp" >&2
    return
  fi
  rm -rf -- "$tmp"
}
trap cleanup EXIT
kit="$tmp/kit"
mkdir -p "$kit/scripts" "$kit/02-node" "$tmp/bin" "$tmp/operator/parent/state/ml-attached" "$tmp/operator/donor/state"
cp "$ROOT/scripts/detach-network-ml-host.sh" "$ROOT/scripts/remove-network-ml-endpoint.sh" \
  "$ROOT/scripts/wait-dapi-worker-removal.sh" "$kit/scripts/"
cat >"$kit/scripts/check-running-network-node.sh" <<'SH'
#!/usr/bin/env bash
[[ "$1" == parent ]] || exit 2
printf 'network-ready:%s\n' "$1" >>"$GDC_TEST_EVENTS"
SH
printf '#!/usr/bin/env bash\nexit 0\n' >"$kit/02-node/sync-node-config.sh"
chmod 0755 "$kit/scripts"/*.sh "$kit/02-node/sync-node-config.sh"

config="$tmp/node-config.initial.json"
remote_config="$tmp/node-config.remote.json"
staged_config="$tmp/node-config.staged.json"
link="$tmp/gdc-ml-link.json"
donor_record="$tmp/operator/donor/state/ml-parent.json"
printf '%s\n' '[{"id":"qwen:parent","host":"inference","inference_port":5000,"poc_port":5000},{"id":"qwen:parent--donor","host":"gpu.example.test","inference_port":5000,"poc_port":5000}]' >"$config"
cp "$config" "$remote_config"
printf '%s\n' '{"schema_version":2,"validator_alias":"parent","ml_hosts":[{"ssh_alias":"other","endpoint":"other.example.test","node_id":"qwen:parent--other"},{"ssh_alias":"donor","endpoint":"gpu.example.test","node_id":"qwen:parent--donor","ownership":"lent_validator"}]}' >"$link"
printf '%s\n' '{"schema_version":1,"kind":"gdc-ml-parent","network_alias":"parent","ml_alias":"donor","endpoint":"gpu.example.test","node_id":"qwen:parent--donor"}' >"$donor_record"

cat >"$tmp/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
args="$*"
host=''
for arg in "$@"; do [[ "$arg" == parent ]] && { host=parent; break; }; done
[[ "$host" == parent ]] || exit 91
printf '%s\n' "$args" >>"$GDC_TEST_SSH_LOG"
if [[ "$args" == *' true' ]]; then
  exit 0
elif [[ "$args" == *'cat /srv/dai/deploy/node-config.json'* ]]; then
  cat "$GDC_TEST_REMOTE_CONFIG"
elif [[ "$args" == *'cat /srv/dai/deploy/gdc-ml-link.json'* ]]; then
  [[ "${GDC_TEST_LINK_AVAILABLE:-true}" == true ]] || exit 1
  cat "$GDC_TEST_LINK"
elif [[ "$args" == *'node-config.json.tmp'* ]]; then
  # The real remote body installs next_config, then lets the bounded helper
  # remove and read back the worker before it syncs the parent configuration.
  cp "$GDC_TEST_STAGED_CONFIG" "$GDC_TEST_REMOTE_CONFIG"
  case "${GDC_TEST_DAPI_REMOVE:-remove}" in
    remove) printf 'detached\n' >"$GDC_TEST_DAPI_STATE" ;;
    retain) exit 195 ;;
    timeout) exit 195 ;;
  esac
elif [[ "$args" == *'admin/v1/nodes'* ]]; then
  if [[ "$(<"$GDC_TEST_DAPI_STATE")" == attached ]]; then
    printf '[{"node":{"id":"qwen:parent--donor","host":"gpu.example.test"}}]\n'
  else
    printf '[]\n'
  fi
elif [[ "$args" == *'rm -rf'*'gdc-ml-remove-'* ]]; then
  exit 0
else
  echo "unexpected ssh: $args" >&2
  exit 92
fi
SH
cat >"$tmp/bin/scp" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$GDC_TEST_SCP_LOG"
[[ "$1" == -q && "$#" == 3 && "$3" == parent:/tmp/gdc-ml-remove-* ]]
if [[ "$2" == *node-config.*.json ]]; then
  cp "$2" "$GDC_TEST_STAGED_CONFIG"
fi
if [[ "$2" == *gdc-ml-link.next.json ]]; then
  cp "$2" "$GDC_TEST_WRITTEN_LINK"
fi
SH
chmod 0755 "$tmp/bin/ssh" "$tmp/bin/scp"

run_detach() {
  local removal_mode="${1:-remove}" donor_binding="${2:-managed}"
  local -a binding_args=()
  if [[ "$donor_binding" == retained ]]; then
    binding_args=(--expected-endpoint gpu.example.test --expected-node-id qwen:parent--donor)
  fi
  env PATH="$tmp/bin:$PATH" GDC_TEST_EVENTS="$tmp/events" GDC_TEST_CONFIG="$config" GDC_TEST_LINK="$link" \
    GDC_TEST_DAPI_STATE="$tmp/dapi-state" GDC_TEST_SSH_LOG="$tmp/ssh.log" GDC_TEST_SCP_LOG="$tmp/scp.log" \
    GDC_TEST_WRITTEN_LINK="$tmp/written-link.json" GDC_TEST_REMOTE_CONFIG="$remote_config" \
    GDC_TEST_STAGED_CONFIG="$staged_config" GDC_TEST_DAPI_REMOVE="$removal_mode" GDC_RUN_ID=fixture \
    GDC_TEST_LINK_AVAILABLE="${GDC_TEST_LINK_AVAILABLE:-true}" \
    bash "$kit/scripts/detach-network-ml-host.sh" --network parent --ml-host donor \
      --data-root "$tmp/operator" --run-dir "$tmp/run" "${binding_args[@]}"
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

printf 'attached\n' >"$tmp/dapi-state"
: >"$tmp/events"; : >"$tmp/ssh.log"; : >"$tmp/scp.log"
run_detach >"$tmp/success.out"
has_text "$tmp/success.out" 'READY removed ML endpoint node_id=qwen:parent--donor host=donor from parent'
[[ "$(<"$tmp/dapi-state")" == detached ]]
if has_text "$tmp/ssh.log" '-o BatchMode=yes'; then
  echo 'detach repeated a standalone parent SSH reachability probe' >&2
  exit 1
fi
jq -e '.ml_hosts == [{ssh_alias:"other",endpoint:"other.example.test",node_id:"qwen:parent--other"}]' "$tmp/written-link.json" >/dev/null
jq -e '.ml_hosts | length == 1 and .[0].ssh_alias == "other"' "$tmp/operator/parent/state/ml-attached/parent.json" >/dev/null
[[ ! -e "$donor_record" ]]
first_text_line "$tmp/ssh.log" 'wait-dapi-worker-removal.sh' >/dev/null

# Parent persistence can be stale after an interrupted synchronization: the
# retained donor binding still names the worker, while node-config already
# lacks it. Reclaim must use the active DAPI registry to release that worker
# and leave the unrelated persistent endpoint unchanged.
printf '%s\n' '[{"id":"qwen:parent","host":"inference","inference_port":5000,"poc_port":5000}]' >"$config"
cp "$config" "$remote_config"
printf '%s\n' '{"schema_version":1,"kind":"gdc-ml-parent","network_alias":"parent","ml_alias":"donor","endpoint":"gpu.example.test","node_id":"qwen:parent--donor"}' >"$donor_record"
printf 'attached\n' >"$tmp/dapi-state"
: >"$tmp/events"; : >"$tmp/ssh.log"; : >"$tmp/scp.log"
run_detach remove >"$tmp/stale-config.out"
has_text "$tmp/stale-config.out" 'READY removed ML endpoint node_id=qwen:parent--donor host=donor from parent'
[[ "$(<"$tmp/dapi-state")" == detached ]]
[[ "$(<"$remote_config")" == "$(<"$config")" ]]
jq -e '.ml_hosts == [{ssh_alias:"other",endpoint:"other.example.test",node_id:"qwen:parent--other"}]' "$tmp/written-link.json" >/dev/null
[[ ! -e "$donor_record" ]]

# If DAPI retains the removed endpoint, ownership evidence remains and the
# caller cannot reclaim/start the donor through this helper.
printf '%s\n' '{"schema_version":1,"kind":"gdc-ml-parent","network_alias":"parent","ml_alias":"donor","endpoint":"gpu.example.test","node_id":"qwen:parent--donor"}' >"$donor_record"
cp "$config" "$remote_config"
printf 'attached\n' >"$tmp/dapi-state"
: >"$tmp/events"; : >"$tmp/ssh.log"; : >"$tmp/scp.log"
if run_detach retain >"$tmp/retain.out" 2>&1; then
  echo 'DAPI endpoint retention unexpectedly released the donor' >&2
  exit 1
fi
has_text "$tmp/retain.out" 'OPERATOR ACTION REQUIRED parent did not confirm removal of donor'
[[ -s "$donor_record" ]]

# A bounded DELETE can lose the client response after DAPI accepted the work.
# The helper must not restore the endpoint and race that removal. It leaves the
# donor relationship in place; a later readback can finish the same release.
printf '%s\n' '{"schema_version":1,"kind":"gdc-ml-parent","network_alias":"parent","ml_alias":"donor","endpoint":"gpu.example.test","node_id":"qwen:parent--donor"}' >"$donor_record"
cp "$config" "$remote_config"
printf 'attached\n' >"$tmp/dapi-state"
: >"$tmp/events"; : >"$tmp/ssh.log"; : >"$tmp/scp.log"
if run_detach timeout >"$tmp/timeout.out" 2>&1; then
  echo 'uncertain DAPI DELETE unexpectedly released the donor' >&2
  exit 1
fi
[[ "$(<"$tmp/timeout.out")" == 'OPERATOR ACTION REQUIRED parent did not confirm removal of donor; leave the donor stopped and rerun gdc host start donor after parent DAPI readback succeeds' ]]
[[ -s "$donor_record" ]]
jq -e 'all(.[]; .id != "qwen:parent--donor")' "$remote_config" >/dev/null
if has_text "$tmp/scp.log" 'node-config.before.json'; then
  echo 'uncertain DAPI DELETE restored the prior parent configuration' >&2
  exit 1
fi

# The server can finish after the client deadline. A fresh readback sees the
# endpoint gone and completes cleanup without restarting or re-lending donor.
printf 'detached\n' >"$tmp/dapi-state"
: >"$tmp/events"; : >"$tmp/ssh.log"; : >"$tmp/scp.log"
run_detach remove >"$tmp/retry.out"
has_text "$tmp/retry.out" 'READY removed ML endpoint node_id=qwen:parent--donor host=donor from parent'
[[ ! -e "$donor_record" ]]

# An interruption immediately after lend has the donor's durable record but
# no parent association yet. The retained donor binding permits a no-op parent
# readback and release; it must not invent, overwrite or delete a parent link.
printf '%s\n' '[{"id":"qwen:parent","host":"inference","inference_port":5000,"poc_port":5000}]' >"$config"
cp "$config" "$remote_config"
rm -f "$tmp/operator/parent/state/ml-attached/parent.json"
printf '%s\n' '{"schema_version":1,"kind":"gdc-ml-parent","network_alias":"parent","ml_alias":"donor","endpoint":"gpu.example.test","node_id":"qwen:parent--donor"}' >"$donor_record"
printf 'detached\n' >"$tmp/dapi-state"
: >"$tmp/events"; : >"$tmp/ssh.log"; : >"$tmp/scp.log"
GDC_TEST_LINK_AVAILABLE=false run_detach remove retained >"$tmp/pre-attach.out"
has_text "$tmp/pre-attach.out" 'READY use retained donor binding for unfinished ML lending on parent'
[[ ! -e "$donor_record" ]]
[[ "$(<"$remote_config")" == "$(<"$config")" ]]
if has_text "$tmp/scp.log" 'gdc-ml-link.next.json'; then
  echo 'pre-attach donor release modified an absent parent association' >&2
  exit 1
fi

# A malformed retained donor association cannot authorize a DAPI removal or a
# validator reclaim. The helper returns the bounded continuation code before
# it writes remote parent configuration or touches the active registry.
printf '%s\n' '[{"id":"qwen:parent","host":"inference","inference_port":5000,"poc_port":5000},{"id":"qwen:parent--donor","host":"gpu.example.test","inference_port":5000,"poc_port":5000}]' >"$config"
cp "$config" "$remote_config"
printf '%s\n' '{}' >"$donor_record"
printf 'attached\n' >"$tmp/dapi-state"
: >"$tmp/events"; : >"$tmp/ssh.log"; : >"$tmp/scp.log"
association_rc=0
run_detach remove >"$tmp/invalid-association.out" 2>&1 || association_rc=$?
[[ "$association_rc" -eq 195 ]]
has_text "$tmp/invalid-association.out" 'OPERATOR ACTION REQUIRED cannot validate the retained ML association for donor on parent; leave it unchanged and repair the association before retrying'
if has_text "$tmp/ssh.log" 'admin/v1/nodes'; then
  echo 'invalid association unexpectedly reached the active DAPI registry' >&2
  exit 1
fi
[[ ! -s "$tmp/scp.log" ]]

printf 'PASS detach removes the configured endpoint only after DAPI readback and retains donor ownership across an uncertain DELETE\n'
