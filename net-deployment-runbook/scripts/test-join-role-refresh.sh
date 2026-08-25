#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

data_root="$tmp/gdc-data"
state="$data_root/validator-west/state"
mkdir -p "$state" "$tmp/bin"
role="$state/role-inputs/join-validator-west"
mkdir -p "$(dirname "$role")"
cat >"$role" <<'EOF'
GDC_RELEASE_PROFILE=v2026.07.23
GDC_DEPLOYMENT_PROFILE=community-lab
GDC_OPERATOR_SERVICES_PROFILE=gdc-lab
GDC_JOIN_ROLE_INPUT=true
GDC_NODE_ALIASES='gdc-node0 validator-west'
GDC_NODE_PUBLIC_HOSTS='gdc-node0=node0.example.net validator-west=node2.example.net'
GDC_NODE_GPU_PROFILES='gdc-node0=auto validator-west=auto'
GDC_NODE_P2P_PORTS='gdc-node0=5000 validator-west=5000'
GDC_NODE_ML_HOSTS=''
GDC_GENESIS_NODE=gdc-node0
GDC_PUBLIC_EDGE_NODE=gdc-node0
GDC_GATEWAY_NODE=gdc-node0
GDC_JOIN_BOOTSTRAP_URL=https://bootstrap.example.test/join-bootstrap
GDC_JOIN_BOOTSTRAP_MANIFEST_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
printf '%s\n' "$role" >"$state/active-role-config"

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ " $* " == *' -w '* ]]; then
  printf 'fetch-called\n' >>"$GDC_TEST_CURL_LOG"
else
  printf 'prepare-called\n' >>"$GDC_TEST_CURL_LOG"
  for argument in "$@"; do
    [[ "$argument" == https://* ]] && printf 'prepare-url=%s\n' "$argument" >>"$GDC_TEST_CURL_LOG"
  done
fi
exit 22
EOF
chmod +x "$tmp/bin/curl"

cat >"$tmp/bin/getent" <<'EOF'
#!/usr/bin/env bash
printf '192.0.2.10 STREAM bootstrap.example.test\n'
EOF
chmod +x "$tmp/bin/getent"

# run_phase creates a run envelope before phase-join verifies the bootstrap.
# A failure at that pre-dispatch boundary must leave a retry refreshable.
mkdir -p "$data_root/validator-west/runs/pre-dispatch-bootstrap-failure"
# An interrupted marker write may leave a private temporary candidate, but it
# must never become immutable dispatch state before the atomic rename.
printf 'schema_version=1\n' >"$state/.join-bootstrap-dispatched.manifest.sha256.interrupted"

(
  flock 8
  printf 'locked\n' >"$tmp/lock-ready"
  sleep 10
) 8>"$state/.lifecycle.lock" &
lock_pid="$!"
for _ in {1..50}; do
  [[ -s "$tmp/lock-ready" ]] && break
  sleep 0.1
done
[[ -s "$tmp/lock-ready" ]] || { echo 'test could not acquire the lifecycle lock' >&2; exit 1; }
: >"$tmp/curl.log"
if PATH="$tmp/bin:$PATH" GDC_HOME="$data_root" GDC_TEST_CURL_LOG="$tmp/curl.log" \
  "$ROOT/gdc.sh" host join --public-host node2.example.net validator-west \
  >"$tmp/locked.stdout" 2>"$tmp/locked.stderr"; then
  echo 'JOIN prepared shared role state while the lifecycle lock was held' >&2
  exit 1
fi
grep -Fq 'another lifecycle phase is already running for this operator' "$tmp/locked.stderr"
[[ ! -s "$tmp/curl.log" ]]
[[ ! -e "$state/join-bootstrap-dispatched.manifest.sha256" ]]
kill "$lock_pid"
wait "$lock_pid" 2>/dev/null || true

if PATH="$tmp/bin:$PATH" GDC_HOME="$data_root" GDC_TEST_CURL_LOG="$tmp/curl.log" \
  "$ROOT/gdc.sh" host join --public-host node2.example.net validator-west \
  >"$tmp/join.stdout" 2>"$tmp/join.stderr"; then
  echo 'JOIN reused a generated role input without refreshing public bootstrap metadata' >&2
  exit 1
fi

grep -Fxq 'prepare-called' "$tmp/curl.log"
grep -Fxq 'prepare-url=https://bootstrap.example.test/join-bootstrap/manifest.sha256' "$tmp/curl.log"
[[ -d "$data_root/validator-west/runs/pre-dispatch-bootstrap-failure" ]]
[[ -f "$state/.join-bootstrap-dispatched.manifest.sha256.interrupted" ]]

digest='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
role_sha256="$(sha256sum "$role" | awk '{print $1}')"
cat >"$state/join-bootstrap-dispatched.manifest.sha256" <<EOF
schema_version=1
manifest_sha256=$digest
role_sha256=$role_sha256
host_alias=validator-west
public_host=node2.example.net
gpu_alias=
EOF
cp "$state/active-role-config" "$tmp/dispatched-role.env"
: >"$tmp/curl.log"
if PATH="$tmp/bin:$PATH" GDC_HOME="$data_root" GDC_TEST_CURL_LOG="$tmp/curl.log" \
  "$ROOT/gdc.sh" host join --public-host node2.example.net validator-west \
  >"$tmp/dispatched.stdout" 2>"$tmp/dispatched.stderr"; then
  echo 'JOIN phase unexpectedly completed with a mocked bootstrap transport failure' >&2
  exit 1
fi
grep -Fxq 'fetch-called' "$tmp/curl.log" || {
  tail -n 120 "$tmp/dispatched.stderr" >&2
  find "$data_root/validator-west/runs" -name run.log -exec tail -n 120 {} \; >&2
  exit 1
}
! grep -Fxq 'prepare-called' "$tmp/curl.log"
cmp -s "$tmp/dispatched-role.env" "$state/active-role-config"
cmp -s "$role" "$(<"$state/active-role-config")"

: >"$tmp/curl.log"
if PATH="$tmp/bin:$PATH" GDC_HOME="$data_root" GDC_TEST_CURL_LOG="$tmp/curl.log" \
  "$ROOT/gdc.sh" host join --public-host node3.example.net validator-west \
  >"$tmp/changed-topology.stdout" 2>"$tmp/changed-topology.stderr"; then
  echo 'JOIN accepted a public Host change after dispatch' >&2
  exit 1
fi
grep -Fq 'JOIN has already dispatched with a different public Host' "$tmp/changed-topology.stderr"
[[ ! -s "$tmp/curl.log" ]]
cmp -s "$tmp/dispatched-role.env" "$state/active-role-config"

override="$tmp/override-role.env"
sed 's/node2\.example\.net/node3.example.net/; s/GDC_JOIN_ROLE_INPUT=true/GDC_JOIN_ROLE_INPUT=false/' "$role" >"$override"
: >"$tmp/curl.log"
if PATH="$tmp/bin:$PATH" GDC_HOME="$data_root" GDC_ENV="$override" GDC_TEST_CURL_LOG="$tmp/curl.log" \
  "$ROOT/gdc.sh" host join --public-host node2.example.net validator-west \
  >"$tmp/override.stdout" 2>"$tmp/override.stderr"; then
  echo 'JOIN accepted an alternate role input after dispatch' >&2
  exit 1
fi
grep -Fq 'JOIN dispatch binding disagrees with the selected role input' "$tmp/override.stderr"
[[ ! -s "$tmp/curl.log" ]]
cmp -s "$tmp/dispatched-role.env" "$state/active-role-config"
printf 'PASS generated JOIN role input refreshes only before dispatch\n'
