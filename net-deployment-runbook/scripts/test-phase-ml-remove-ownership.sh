#!/usr/bin/env bash
# Exercise the real removal phase's ownership decision.  A GDC-lent
# validator is returned with host start; only an ML-only Host is detached and
# reset by remove mlnode.
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
remote_root="$tmp/remote"
mkdir -p "$kit/scripts" "$tmp/bin" "$tmp/operator" "$remote_root"
cp "$ROOT/scripts/phase-ml-remove.sh" "$kit/scripts/"

cat >"$kit/scripts/lib.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="${GDC_TEST_KIT:?}"
load_project() {
  ROOT="${GDC_TEST_KIT:?}"
  GDC_DATA_ROOT="${GDC_TEST_OPERATOR:?}"
  GDC_HOME="$GDC_DATA_ROOT"
}
topology_contains_node() { [[ "$1" == parent ]]; }
ssh_ready() {
  [[ "$1" == parent ]]
  printf 'ssh-ready:%s\n' "$1" >>"$GDC_TEST_EVENTS"
}
die() { printf '%s\n' "$*" >&2; exit 1; }
step() { :; }
SH

cat >"$kit/scripts/check-running-network-node.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == parent ]]
printf 'parent-ready:%s\n' "$1" >>"$GDC_TEST_EVENTS"
SH

cat >"$kit/scripts/detach-network-ml-host.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
network=''
ml_host=''
while (($#)); do
  case "$1" in
    --network) network="$2"; shift 2 ;;
    --ml-host) ml_host="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'detach %s %s\n' "$network" "$ml_host" >>"$GDC_TEST_EVENTS"
SH

cat >"$kit/gdc.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$*" == 'host reset ml-only' ]]
printf 'reset ml-only\n' >>"$GDC_TEST_EVENTS"
SH

cat >"$tmp/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == -T ]]
host="$2"
case "$host" in donor|ml-only|dangling) ;; *) exit 99 ;; esac
remote="$GDC_TEST_REMOTE/$host"
script="$(cat)"
# Execute the actual here-document sent to the donor. Map its fixed remote
# deployment root into this closed fake remote filesystem; this catches shell
# semantics such as a dangling link being mistaken for an absent record.
sed "s|/srv/dai/deploy|$remote/srv/dai/deploy|g" <<<"$script" \
  | bash -s -- gdc-lent-ml-record
SH
chmod 0755 "$kit/gdc.sh" "$kit/scripts"/*.sh "$tmp/bin/ssh"

# The closed remote filesystem is created by the test user, while production
# requires a root-owned record. Model that remote metadata without granting
# the test elevated filesystem privileges.
cat >"$tmp/bin/stat" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$#" == 3 && "$1" == -c && "$2" == %u ]]; then printf '0\n'; exit 0; fi
if [[ "$#" == 3 && "$1" == -c && "$2" == %a ]]; then printf '600\n'; exit 0; fi
exec /usr/bin/stat "$@"
SH
chmod 0755 "$tmp/bin/stat"

for host in donor ml-only dangling; do
  mkdir -p "$remote_root/$host/srv/dai/deploy/.node-control"
done
printf '%s\n' '{"schema_version":1,"kind":"gdc-lent-validator-ml","parent_alias":"parent","endpoint":"ml.example.test","node_id":"fixture:parent--donor"}' \
  >"$remote_root/donor/srv/dai/deploy/.node-control/lent-ml.json"
chmod 0600 "$remote_root/donor/srv/dai/deploy/.node-control/lent-ml.json"
ln -s /missing/lent-ml.json "$remote_root/dangling/srv/dai/deploy/.node-control/lent-ml.json"

run_phase() {
  local ml_host="$1" output="$2"
  GDC_TEST_KIT="$kit" \
  GDC_TEST_OPERATOR="$tmp/operator" \
  GDC_TEST_REMOTE="$remote_root" \
  GDC_TEST_EVENTS="$tmp/events" \
  GDC_RUN_ID=fixture \
  PATH="$tmp/bin:$PATH" \
  bash "$kit/scripts/phase-ml-remove.sh" parent "$ml_host" >"$output" 2>&1
}

rc=0
run_phase donor "$tmp/donor.log" || rc=$?
[[ "$rc" == 195 ]]
[[ "$(<"$tmp/donor.log")" == 'OPERATOR ACTION REQUIRED donor is a lent validator; run gdc host start donor to detach it and restore its validator services' ]]
[[ ! -e "$tmp/events" ]]
printf 'PASS remove mlnode refuses to reset a lent validator and directs safe reclaim\n'

run_phase ml-only "$tmp/ml-only.log"
[[ "$(<"$tmp/ml-only.log")" == 'PASS detached and reset ML-only Host ml-only from parent' ]]
[[ "$(<"$tmp/events")" == $'detach parent ml-only\nreset ml-only' ]]
printf 'PASS remove mlnode detaches and resets a confirmed ML-only Host\n'

: >"$tmp/events"
rc=0
run_phase dangling "$tmp/dangling.log" || rc=$?
[[ "$rc" == 195 ]]
[[ "$(<"$tmp/dangling.log")" == 'OPERATOR ACTION REQUIRED cannot determine whether dangling is a lent validator; leave it unchanged and restore SSH access before retrying' ]]
[[ ! -s "$tmp/events" ]]
printf 'PASS dangling donor ownership remains non-mutating and actionable\n'
