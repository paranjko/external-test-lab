#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/check-monitoring-inventory-drift.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

mkdir -p "$tmp/data/node-a/state/joined" "$tmp/data/node-c/state/joined"
: >"$tmp/data/node-a/state/joined/node-a"
: >"$tmp/data/node-c/state/joined/node-c"
cat >"$tmp/inventory.env" <<'EOF'
GDC_NODE_ALIASES='node-a node-b'
EOF
cat >"$tmp/targets.json" <<'EOF'
{"status":"success","data":{"activeTargets":[
  {"labels":{"job":"gonka-node","host":"node-a"},"health":"up","lastError":""},
  {"labels":{"job":"gonka-node","host":"node-b"},"health":"down","lastError":"server returned HTTP status 404"}
]}}
EOF

set +e
"$CHECK" --inventory "$tmp/inventory.env" --gdc-data-root "$tmp/data" --targets "$tmp/targets.json" --output "$tmp/drift.json" >/dev/null 2>&1
drift_rc=$?
set -e
[[ "$drift_rc" == 1 ]]
jq -e '
  .status == "drift" and
  .nodes == [
    {node:"node-a",status:"ready"},
    {node:"node-b",status:"endpoint_absent"},
    {node:"node-c",status:"inventory_missing"}
  ]
' "$tmp/drift.json" >/dev/null
[[ "$(stat -c %a "$tmp/drift.json")" == 600 ]]

mkdir -p "$tmp/data/node-b/state/joined"
: >"$tmp/data/node-b/state/joined/node-b"
rm -f "$tmp/data/node-c/state/joined/node-c" "$tmp/drift.json"
cat >"$tmp/targets-ready.json" <<'EOF'
{"status":"success","data":{"activeTargets":[
  {"labels":{"job":"gonka-node","host":"node-a"},"health":"up","lastError":""},
  {"labels":{"job":"gonka-node","host":"node-b"},"health":"up","lastError":""}
]}}
EOF
"$CHECK" --inventory "$tmp/inventory.env" --gdc-data-root "$tmp/data" --targets "$tmp/targets-ready.json" --output "$tmp/ready.json" >/dev/null
jq -e '.status == "pass" and .nodes == [{node:"node-a",status:"ready"},{node:"node-b",status:"ready"}]' "$tmp/ready.json" >/dev/null

# A configured Host omitted from the deployed Prometheus target list is a
# stale deployment, while a present target with a non-404 scrape error is a
# reachable configuration whose scraper is down. Keep those dispositions
# separate so OPS does not mistake either one for a missing inventory alias.
rm -f "$tmp/ready.json"
cat >"$tmp/targets-missing.json" <<'EOF'
{"status":"success","data":{"activeTargets":[
  {"labels":{"job":"gonka-node","host":"node-a"},"health":"up","lastError":""}
]}}
EOF
set +e
"$CHECK" --inventory "$tmp/inventory.env" --gdc-data-root "$tmp/data" --targets "$tmp/targets-missing.json" --output "$tmp/missing.json" >/dev/null 2>&1
missing_rc=$?
set -e
[[ "$missing_rc" == 1 ]]
jq -e '.nodes == [{node:"node-a",status:"ready"},{node:"node-b",status:"deployed_target_missing"}]' "$tmp/missing.json" >/dev/null

cat >"$tmp/targets-down.json" <<'EOF'
{"status":"success","data":{"activeTargets":[
  {"labels":{"job":"gonka-node","host":"node-a"},"health":"up","lastError":""},
  {"labels":{"job":"gonka-node","host":"node-b"},"health":"down","lastError":"dial tcp: i/o timeout"}
]}}
EOF
set +e
"$CHECK" --inventory "$tmp/inventory.env" --gdc-data-root "$tmp/data" --targets "$tmp/targets-down.json" --output "$tmp/down.json" >/dev/null 2>&1
down_rc=$?
set -e
[[ "$down_rc" == 1 ]]
jq -e '.nodes == [{node:"node-a",status:"ready"},{node:"node-b",status:"scrape_down"}]' "$tmp/down.json" >/dev/null

# Exercise the OPS phase itself with a retained JOIN-marker handoff.  The
# phase may observe the gateway's Prometheus API once, but it must not turn a
# drift check into a deployment or touch any Host transport.
phase_home="$tmp/phase-home"
phase_data="$tmp/phase-data"
phase_bin="$tmp/phase-bin"
mkdir -p "$phase_home" "$phase_data/node-a/state/joined" "$phase_data/node-c/state/joined" "$phase_bin"
: >"$phase_data/node-a/state/joined/node-a"
: >"$phase_data/node-c/state/joined/node-c"
cat >"$phase_home/role.env" <<'EOF'
GDC_NODE_ALIASES='node-a node-b'
GDC_NODE_PUBLIC_HOSTS='node-a=192.0.2.10 node-b=192.0.2.11'
GDC_NODE_P2P_PORTS='node-a=5000 node-b=5001'
GDC_GENESIS_NODE=node-a
GDC_PUBLIC_EDGE_NODE=node-a
GDC_GATEWAY_NODE=node-a
GDC_TELEGRAM_BOT_HOST=node-a
GDC_DEPLOYMENT_PROFILE=community-lab
GDC_OPERATOR_SERVICES_PROFILE=gdc-lab
EOF
cat >"$phase_bin/getent" <<'EOF'
#!/usr/bin/env bash
printf '192.0.2.10 STREAM fixture\n'
EOF
cat >"$phase_bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${GDC_MONITORING_TEST_SSH_LOG:?}"
case "$*" in
  *'http://127.0.0.1:9099/api/v1/targets?state=active'*)
    printf '%s\n' '{"status":"success","data":{"activeTargets":[{"labels":{"job":"gonka-node","host":"node-a"},"health":"up","lastError":""},{"labels":{"job":"gonka-node","host":"node-b"},"health":"down","lastError":"server returned HTTP status 404"}]}}'
    ;;
  *)
    printf 'unexpected monitoring SSH command\n' >&2
    exit 99
    ;;
esac
EOF
chmod 0755 "$phase_bin/getent" "$phase_bin/ssh"

set +e
PATH="$phase_bin:$PATH" GDC_HOME="$phase_home" GDC_INTERNAL_DATA_ROOT="$phase_data" GDC_DATA_ROOT="$phase_data" GDC_ENV="$phase_home/role.env" \
  GDC_RUN_ID=fixture-monitoring GDC_MONITORING_TEST_SSH_LOG="$tmp/phase-ssh.log" \
  "$ROOT/scripts/phase-monitoring-check.sh" >"$tmp/phase.out" 2>"$tmp/phase.err"
phase_rc=$?
set -e
[[ "$phase_rc" == 1 ]]
phase_receipt="$phase_home/runs/fixture-monitoring/monitoring-check/monitoring-inventory-drift.v1.json"
[[ -f "$phase_receipt" && ! -L "$phase_receipt" && "$(stat -c %a "$phase_receipt")" == 600 ]]
jq -e '
  .status == "drift" and
  .nodes == [
    {node:"node-a",status:"ready"},
    {node:"node-b",status:"endpoint_absent"},
    {node:"node-c",status:"inventory_missing"}
  ]
' "$phase_receipt" >/dev/null
awk '
  /http:\/\/127\.0\.0\.1:9099\/api\/v1\/targets\?state=active/ { target_reads++ }
  /docker|compose|scp|rsync/ { mutation_transport=1 }
  END { exit !(target_reads == 1 && !mutation_transport) }
' "$tmp/phase-ssh.log"

printf 'test-monitoring-inventory-drift: PASS\n'
