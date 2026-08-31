#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cp "$ROOT/.env.example" "$tmp/inventory.env"
{
  printf '%s\n' \
    'SITE_HOST=gonka-dev.net' \
    'API_HOST=api.gonka-dev.net' \
    'GRAFANA_HOST=grafana.gonka-dev.net' \
    'MONITORING_CIDR=192.0.2.10/32' \
    'PUBLIC_EDGE_CIDR=192.0.2.20/32'
} >>"$tmp/inventory.env"

GDC_RELEASE_PROFILE=v2026.08.06 \
  "$ROOT/04-ops/edge-node/render-env.sh" \
    --inventory "$tmp/inventory.env" --node-name validator-e --output "$tmp/stable.env"
stable_contract="$(sed -n 's/^GDC_GATEWAY_ADMISSION_PROTOCOLS_JSON=//p' "$tmp/stable.env")"
jq -e 'keys == ["v3"]' <<<"$stable_contract" >/dev/null
grep -Fxq 'GDC_GATEWAY_ADMISSION_STATUS_URL=https://validator-a.example.net/ops-gateway-admission-state' "$tmp/stable.env"
if grep -Fq 'GDC_GATEWAY_ADMISSION_STATUS_BEARER_TOKEN=' "$tmp/stable.env"; then
  echo 'rendered public edge environment contains an observer credential' >&2
  exit 1
fi

GDC_COMPOSITION=core-v2026.08.06+devshard-v2026.08.27-rc.0 \
  "$ROOT/04-ops/edge-node/render-env.sh" \
    --inventory "$tmp/inventory.env" --node-name validator-e --output "$tmp/candidate.env"
candidate_contract="$(sed -n 's/^GDC_GATEWAY_ADMISSION_PROTOCOLS_JSON=//p' "$tmp/candidate.env")"
jq -e 'keys == ["v3", "v5"] and (has("v4") | not)' <<<"$candidate_contract" >/dev/null
grep -Fxq 'GDC_GATEWAY_ADMISSION_STATUS_URL=https://validator-a.example.net/ops-gateway-admission-state' "$tmp/candidate.env"

# Each renderer loads profiles in its own process. A parent export cannot be
# trusted to survive that reload, so prove that an explicit v4 selection
# produces the independent pinned v4 contract at the actual child boundary.
GDC_COMPOSITION=core-v2026.08.06+devshard-v2026.08.30-rc.0 \
GDC_GATEWAY_VERSION=v4 \
  "$ROOT/04-ops/edge-node/render-env.sh" \
    --inventory "$tmp/inventory.env" --node-name validator-e --output "$tmp/v4.env"
v4_contract="$(sed -n 's/^GDC_GATEWAY_ADMISSION_PROTOCOLS_JSON=//p' "$tmp/v4.env")"
jq -e \
  --arg binary 'https://github.com/gonka-ai/gonka/releases/download/release%2Fv0.2.15-devshard-v4.0.1/devshardd.zip' \
  --arg sha256 'c80d098941fd18caf0159910c1b6c23140fce871f7ce903ceaad134cfe626b25' \
  'keys == ["v4"] and .v4 == {binary:$binary,sha256:$sha256}' \
  <<<"$v4_contract" >/dev/null

sed 's/^GDC_PUBLIC_EDGE_NODE=.*/GDC_PUBLIC_EDGE_NODE=validator-a/' "$tmp/inventory.env" >"$tmp/colocated-inventory.env"
GDC_RELEASE_PROFILE=v2026.08.06 \
  "$ROOT/04-ops/edge-node/render-env.sh" \
    --inventory "$tmp/colocated-inventory.env" --node-name validator-a --output "$tmp/colocated.env"
grep -Fxq 'PUBLIC_EDGE=true' "$tmp/colocated.env"
grep -Fxq 'GDC_GATEWAY_ADMISSION_STATUS_URL=http://127.0.0.1:18084/v1/status' "$tmp/colocated.env"

grep -Fq 'env_file: [./gateway-admission.env]' "$ROOT/04-ops/edge-node/compose.yaml"
grep -Fq 'install-gateway-admission.sh' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'deploy_gateway_admission' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'gateway admission environment differs after deployment' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'gateway admission environment has an invalid protocol contract' "$ROOT/04-ops/edge-node/install-gateway-admission.sh"
grep -Fq 'gateway admission environment has an invalid status credential' "$ROOT/04-ops/edge-node/install-gateway-admission.sh"
grep -Fq 'GDC_GATEWAY_ADMISSION_STATUS_BEARER_TOKEN=%s' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'gateway.admission-observer-key' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'gateway-admission-observer.env' "$ROOT/04-ops/install-ops.sh"
grep -Fq 'gateway-admission-observer.py' "$ROOT/04-ops/install-ops.sh"
if grep -Fq 'ops-gateway-admission-state' "$ROOT/04-ops/Caddyfile"; then
  echo 'internal OPS Caddy must not publish the observer route' >&2
  exit 1
fi
grep -Fq '@gateway_admission_observer_from_public_edge' "$ROOT/04-ops/edge-node/Caddyfile"
grep -Fq '@gateway_admission_observer_from_public_edge' "$ROOT/04-ops/edge-node/PublicCaddyfile"
grep -Fq 'remote_ip {$PUBLIC_EDGE_CIDR} 127.0.0.0/8 ::1' "$ROOT/04-ops/edge-node/Caddyfile"
grep -Fq 'remote_ip {$PUBLIC_EDGE_CIDR} 127.0.0.0/8 ::1' "$ROOT/04-ops/edge-node/PublicCaddyfile"
grep -Fq 'reverse_proxy 127.0.0.1:18084' "$ROOT/04-ops/edge-node/Caddyfile"
grep -Fq 'reverse_proxy 127.0.0.1:18084' "$ROOT/04-ops/edge-node/PublicCaddyfile"
grep -Fq 'handle /ops-gateway-admission-state' "$ROOT/04-ops/edge-node/Caddyfile"
grep -Fq 'handle /ops-gateway-admission-state' "$ROOT/04-ops/edge-node/PublicCaddyfile"
grep -Fq 'http://127.0.0.1:18084/v1/status' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'GDC_GATEWAY_ADMISSION_STATUS_BEARER_TOKEN' "$ROOT/scripts/phase-ops.sh"
grep -Fq '.capacity.models | type ==' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'suspend-gateway-admission.sh' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'trap cleanup_failed_admission EXIT' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'docker compose stop gateway-admission' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'reconcile_gateway_observer_route' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'authenticated gateway observer TLS route is reachable from the managed public edge' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'existing public admission cannot be suspended before its observer TLS route is proven' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'probe_env="$(mktemp)"' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'trap '\''rm -f "$probe_env"'\'' EXIT' "$ROOT/scripts/phase-ops.sh"
grep -Fq '. /dev/stdin' "$ROOT/scripts/phase-ops.sh"
if grep -Fq 'gateway-observer-probe.env"' "$ROOT/scripts/phase-ops.sh"; then
  printf 'gateway observer credentials must not be copied to a remote file\n' >&2
  exit 1
fi
grep -Fq 'could not determine gateway admission observer state before runtime replacement' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'could not determine public admission state before runtime replacement' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'wait_gateway_admission_observer_ready' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'ltrimstr("v")' "$ROOT/scripts/phase-ops.sh"
grep -Fq 'reason=protocol-or-capacity-transitioning' "$ROOT/scripts/phase-ops.sh"

deploy_block="$(awk '
  /^deploy_gateway_admission\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$ROOT/scripts/phase-ops.sh")"
digest_line="$(grep -nF '[[ "$remote_sha" == "$expected_sha" ]]' <<<"$deploy_block" | cut -d: -f1)"
start_line="$(grep -nF 'docker compose up -d --force-recreate gateway-admission' <<<"$deploy_block" | cut -d: -f1)"
(( digest_line < start_line ))

observer_line="$(grep -nF "step 'Verify the sanitized read-only admission observer'" "$ROOT/scripts/phase-ops.sh" | cut -d: -f1)"
deploy_line="$(grep -nF "step 'Deploy the matching public admission contract'" "$ROOT/scripts/phase-ops.sh" | cut -d: -f1)"
suspend_line="$(grep -nF "step 'Suspend public admission before replacing the gateway runtime'" "$ROOT/scripts/phase-ops.sh" | cut -d: -f1)"
route_line="$(grep -nF "step 'Reconcile the authenticated gateway observer TLS route before runtime replacement'" "$ROOT/scripts/phase-ops.sh" | cut -d: -f1)"
install_line="$(grep -nF 'WAIT  start %s operations component' "$ROOT/scripts/phase-ops.sh" | cut -d: -f1)"
(( route_line < suspend_line && suspend_line < install_line && observer_line < deploy_line ))
[[ "$(grep -Fc "step 'Deploy the matching public admission contract'" "$ROOT/scripts/phase-ops.sh")" == 1 ]]
if awk '/deploy_gateway_admission\(\)/,/^}/' "$ROOT/scripts/phase-ops.sh" | grep -Fq 'gateway.admin-key'; then
  echo 'public admission deployment must not receive the gateway admin key' >&2
  exit 1
fi

grafana_reconcile="$(awk '
  /^reconcile_public_grafana\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$ROOT/scripts/phase-ops.sh")"
if grep -Fq 'gateway-admission' <<<"$grafana_reconcile"; then
  echo 'public Grafana reconciliation must not replace gateway admission' >&2
  exit 1
fi
grep -Fq 'if [[ ! -e "$DEST/gateway-admission.env" ]]; then' "$ROOT/04-ops/edge-node/install-edge.sh"
[[ "$(grep -Fc 'install -m 0600 /dev/null "$DEST/gateway-admission.env"' "$ROOT/04-ops/edge-node/install-edge.sh")" == 1 ]]
if grep -Fq 'gateway-admission-proxy.py' "$ROOT/04-ops/edge-node/install-edge.sh"; then
  echo 'ordinary edge installation must not replace gateway admission code' >&2
  exit 1
fi

# Execute the production route functions with bounded transport doubles. This
# proves that a running admission is never suspended behind an unknown observer
# or Docker state and that the probe credential travels through SSH stdin only.
route_functions="$tmp/route-functions.sh"
awk '
  /^reconcile_gateway_observer_route\(\)/ { capture_brace=1 }
  /^wait_gateway_admission_observer_ready\(\)/ { capture_brace=1 }
  capture_brace { print }
  capture_brace && /^}/ { capture_brace=0; next }
  /^probe_gateway_observer_tls_route\(\)/ { capture_subshell=1 }
  capture_subshell { print }
  capture_subshell && /^\)$/ { capture_subshell=0 }
' "$ROOT/scripts/phase-ops.sh" >"$route_functions"
# shellcheck disable=SC1090
source "$route_functions"

mkdir -p "$tmp/bin" "$tmp/generated/edge" "$tmp/secrets" "$tmp/route-root/04-ops/edge-node"
printf '%s\n' 'test-observer-token-1234567890' >"$tmp/secrets/gateway.admission-observer-key"
chmod 0600 "$tmp/secrets/gateway.admission-observer-key"
cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
command_line="$*"
if [[ "$command_line" == *'gateway-admission-observer.env'* ]]; then
  count=0
  [[ ! -s "${GDC_TEST_READINESS_COUNT:-}" ]] || count="$(<"$GDC_TEST_READINESS_COUNT")"
  count=$((count + 1))
  [[ -z "${GDC_TEST_READINESS_COUNT:-}" ]] || printf '%s\n' "$count" >"$GDC_TEST_READINESS_COUNT"
  [[ "${GDC_TEST_READINESS_MODE:-transition}" != unavailable ]] || exit 255
  active=true
  phase=active
  if (( count <= ${GDC_TEST_READINESS_FAILURES_BEFORE_PASS:-0} )); then
    active=false
    phase=finalizing
  fi
  printf '{"capacity":{"models":{"Qwen/Qwen3-0.6B":{"current_weight":100,"routable":true,"total_weight":100}}},"devshards":[{"active":%s,"protocol_version":"%s","runtime":{"session_version":"v5","phase":"%s","chain_phase":"Inference","requests_blocked":false}}]}\n' \
    "$active" "${GDC_TEST_PROTOCOL_VERSION:-5}" "$phase"
elif [[ "$command_line" == *'systemctl show gdc-gateway-admission-observer.service'* ]]; then
  case "${GDC_TEST_OBSERVER_STATE:-active}" in
    active) printf 'active\n' ;;
    absent) printf 'absent\n' ;;
    error) exit 255 ;;
  esac
elif [[ "$command_line" == *'docker compose ps -aq gateway-admission'* ]]; then
  case "${GDC_TEST_ADMISSION_STATE:-absent}" in
    running|restarting|paused|created|exited) printf 'container-id\n' ;;
    absent) : ;;
    error) exit 255 ;;
  esac
elif [[ "$command_line" == *'. /dev/stdin'* ]]; then
  cat >"$GDC_TEST_PROBE_STDIN"
  printf 'probe\n' >>"$GDC_TEST_ROUTE_LOG"
  count=0
  [[ ! -s "${GDC_TEST_PROBE_COUNT:-}" ]] || count="$(<"$GDC_TEST_PROBE_COUNT")"
  count=$((count + 1))
  [[ -z "${GDC_TEST_PROBE_COUNT:-}" ]] || printf '%s\n' "$count" >"$GDC_TEST_PROBE_COUNT"
  (( count > ${GDC_TEST_PROBE_FAILURES_BEFORE_PASS:-0} ))
else
  printf 'ssh %s\n' "$command_line" >>"$GDC_TEST_ROUTE_LOG"
fi
EOF
cat >"$tmp/bin/rsync" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'rsync %s\n' "$*" >>"$GDC_TEST_ROUTE_LOG"
EOF
cat >"$tmp/bin/scp" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'scp %s\n' "$*" >>"$GDC_TEST_ROUTE_LOG"
EOF
chmod 0755 "$tmp/bin/ssh" "$tmp/bin/rsync" "$tmp/bin/scp"
cat >"$tmp/route-root/04-ops/edge-node/render-env.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output="${!#}"
node=''
while (($#)); do
  case "$1" in
    --node-name) node="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$(dirname "$output")"
public_edge=false
[[ "$node" != "$PUBLIC_EDGE_NODE" ]] || public_edge=true
printf 'PUBLIC_EDGE=%s\n' "$public_edge" >"$output"
EOF
chmod 0755 "$tmp/route-root/04-ops/edge-node/render-env.sh"

write_env() {
  local output="$1"
  shift
  printf '%s\n' "$@" >"$output"
}
die() { printf 'ERROR %s\n' "$*" >&2; exit 1; }
node_public_host() { printf 'validator-a.example.net\n'; }

export PATH="$tmp/bin:$PATH"
export GDC_TEST_ROUTE_LOG="$tmp/route.log"
export GDC_TEST_PROBE_STDIN="$tmp/probe.stdin"
export GDC_TEST_PROBE_COUNT="$tmp/probe.count"
export GDC_TEST_READINESS_COUNT="$tmp/readiness.count"
export GDC_RELEASE_PROFILE=v2026.08.06
export GDC_GATEWAY_OBSERVER_ROUTE_INTERVAL_SECONDS=0
ROOT="$tmp/route-root"
export INVENTORY="$tmp/inventory.env"
export GENERATED="$tmp/generated"
export SECRETS="$tmp/secrets"
export REMOTE=/tmp/gdc-test-route
export GATEWAY_NODE=validator-a
export PUBLIC_EDGE_NODE=validator-e

: >"$GDC_TEST_ROUTE_LOG"
: >"$GDC_TEST_PROBE_COUNT"
export GDC_GATEWAY_OBSERVER_ROUTE_ATTEMPTS=3
export GDC_TEST_OBSERVER_STATE=active
export GDC_TEST_PROBE_FAILURES_BEFORE_PASS=2
reconcile_gateway_observer_route
[[ "$(<"$GDC_TEST_PROBE_COUNT")" == 3 ]]
grep -Fq 'GDC_GATEWAY_ADMISSION_STATUS_BEARER_TOKEN=test-observer-token-1234567890' "$GDC_TEST_PROBE_STDIN"
if grep -Fq 'test-observer-token-1234567890' "$GDC_TEST_ROUTE_LOG"; then
  echo 'observer credential leaked into route command log' >&2
  exit 1
fi
route_install_line="$(grep -nF 'docker compose up -d --force-recreate caddy' "$GDC_TEST_ROUTE_LOG" | head -1 | cut -d: -f1)"
probe_line="$(grep -nFx 'probe' "$GDC_TEST_ROUTE_LOG" | head -1 | cut -d: -f1)"
(( route_install_line < probe_line ))

# The supported colocated topology selects PublicCaddyfile and reaches the
# observer through host-network loopback, never through an uncertain public
# source address.
export PUBLIC_EDGE_NODE=validator-a
: >"$GDC_TEST_ROUTE_LOG"
: >"$GDC_TEST_PROBE_COUNT"
export GDC_GATEWAY_OBSERVER_ROUTE_ATTEMPTS=2
export GDC_TEST_PROBE_FAILURES_BEFORE_PASS=1
reconcile_gateway_observer_route
grep -Fxq 'PUBLIC_EDGE=true' "$GENERATED/edge/validator-a.env"
grep -Fq 'GDC_GATEWAY_ADMISSION_STATUS_URL=http://127.0.0.1:18084/v1/status' "$GDC_TEST_PROBE_STDIN"
route_install_line="$(grep -nF 'docker compose up -d --force-recreate caddy' "$GDC_TEST_ROUTE_LOG" | head -1 | cut -d: -f1)"
probe_line="$(grep -nFx 'probe' "$GDC_TEST_ROUTE_LOG" | head -1 | cut -d: -f1)"
(( route_install_line < probe_line ))
export PUBLIC_EDGE_NODE=validator-e

export GDC_TEST_OBSERVER_STATE=error
if (reconcile_gateway_observer_route) >"$tmp/observer.out" 2>"$tmp/observer.err"; then
  echo 'unknown observer state was accepted' >&2
  exit 1
fi
grep -Fq 'could not determine gateway admission observer state' "$tmp/observer.err"
for state in running restarting paused created exited error; do
  export GDC_TEST_OBSERVER_STATE=absent
  export GDC_TEST_ADMISSION_STATE="$state"
  if (reconcile_gateway_observer_route) >"$tmp/admission-$state.out" 2>"$tmp/admission-$state.err"; then
    echo "unsafe admission state was accepted: $state" >&2
    exit 1
  fi
done
grep -Fq 'existing public admission cannot be suspended' "$tmp/admission-running.err"
grep -Fq 'could not determine public admission state' "$tmp/admission-error.err"
: >"$GDC_TEST_PROBE_COUNT"
export GDC_GATEWAY_OBSERVER_ROUTE_ATTEMPTS=2
export GDC_TEST_OBSERVER_STATE=active
export GDC_TEST_PROBE_FAILURES_BEFORE_PASS=2
if (reconcile_gateway_observer_route) >"$tmp/probe.out" 2>"$tmp/probe.err"; then
  echo 'failed authenticated observer probe was accepted' >&2
  exit 1
fi
grep -Fq 'did not become ready after 2 attempts' "$tmp/probe.err"

# The gateway can rotate between the local runtime check and the sanitized
# observer readback. The production predicate must wait through that bounded
# transition and accept the observer wire value "5" for selected protocol v5.
: >"$GDC_TEST_READINESS_COUNT"
export GDC_GATEWAY_VERSION=v5
export GDC_GATEWAY_OBSERVER_READY_ATTEMPTS=3
export GDC_GATEWAY_OBSERVER_READY_INTERVAL_SECONDS=0
export GDC_TEST_READINESS_MODE=transition
export GDC_TEST_READINESS_FAILURES_BEFORE_PASS=2
export GDC_TEST_PROTOCOL_VERSION=5
wait_gateway_admission_observer_ready >"$tmp/readiness.out"
[[ "$(<"$GDC_TEST_READINESS_COUNT")" == 3 ]]
grep -Fq 'reason=protocol-or-capacity-transitioning protocol=v5' "$tmp/readiness.out"
grep -Fq 'READY gateway admission observer exposes v5 with positive capacity' "$tmp/readiness.out"

# A different active protocol never satisfies the selected-profile contract.
: >"$GDC_TEST_READINESS_COUNT"
export GDC_GATEWAY_OBSERVER_READY_ATTEMPTS=2
export GDC_TEST_READINESS_FAILURES_BEFORE_PASS=0
export GDC_TEST_PROTOCOL_VERSION=4
if (wait_gateway_admission_observer_ready) >"$tmp/wrong-protocol.out" 2>"$tmp/wrong-protocol.err"; then
  echo 'observer readiness accepted the wrong protocol' >&2
  exit 1
fi
[[ "$(<"$GDC_TEST_READINESS_COUNT")" == 2 ]]
grep -Fq 'did not expose v5 with positive capacity after 2 attempts' "$tmp/wrong-protocol.err"

# Transport failures remain fail-closed and report their final reason.
: >"$GDC_TEST_READINESS_COUNT"
export GDC_GATEWAY_OBSERVER_READY_ATTEMPTS=2
export GDC_TEST_READINESS_MODE=unavailable
if (wait_gateway_admission_observer_ready) >"$tmp/readiness-unavailable.out" 2>"$tmp/readiness-unavailable.err"; then
  echo 'unavailable observer was accepted as ready' >&2
  exit 1
fi
grep -Fq 'last_reason=observer-unavailable' "$tmp/readiness-unavailable.err"

printf 'PASS gateway admission follows only the selected gateway profile\n'
