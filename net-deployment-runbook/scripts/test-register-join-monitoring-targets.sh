#!/usr/bin/env bash
# Exercise monitoring registration with closed transports and inspect discovery documents
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/captured"
install -m 0644 "$ROOT/scripts/register-join-monitoring-targets.sh" "$tmp/register.sh"

cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$*" == '-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=2 '* ]] || exit 40
shift 8
[[ "$1" == registry-fixture && $# == 2 ]] || exit 41
case "$2" in
  'test -d /srv/dai/ops/prometheus/targets && sudo -n test -w /srv/dai/ops/prometheus/targets && curl -fsS --max-time 10 http://127.0.0.1:9099/-/ready >/dev/null') exit "${GDC_TEST_READY_EXIT:-0}" ;;
  *'http://127.0.0.1:9099/api/v1/query')
    if [[ -n "${GDC_TEST_QUERY_RESPONSE:-}" ]]; then
      printf '%s\n' "$GDC_TEST_QUERY_RESPONSE"
    else
      printf '%s\n' '{"status":"success","data":{"result":[{"value":[1,"3"]}]}}'
    fi
    exit 0 ;;
  *"/srv/dai/ops/prometheus/targets/join/host"*) ;;
  *"for job in host cadvisor gonka-node; do"*) ;;
  *) exit 42 ;;
esac
printf '%s\n' "$2" >>"$GDC_TEST_SSH_LOG"
EOF
cat >"$tmp/bin/scp" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$*" == '-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=2 '* ]] || exit 50
shift 8
[[ "$1" == -q && $# == 5 && "$5" == registry-fixture:/tmp/gdc-monitoring-targets-fixture-node-*/* ]] || exit 51
for source in "$2" "$3" "$4"; do
  cp "$source" "$GDC_TEST_CAPTURE/$(basename "$source")"
done
EOF
chmod 0755 "$tmp/bin/ssh" "$tmp/bin/scp"

PATH="$tmp/bin:$PATH" GDC_TEST_SSH_LOG="$tmp/ssh.log" GDC_TEST_CAPTURE="$tmp/captured" \
  bash "$tmp/register.sh" --registry-host registry-fixture --node fixture-node --public-host fixture.example.test >"$tmp/out"
grep -Fxq 'PASS registered Prometheus discovery targets node=fixture-node registry=registry-fixture' "$tmp/out"
grep -Fxq 'PASS Prometheus scrapes JOIN endpoints node=fixture-node registry=registry-fixture' "$tmp/out"
[[ -s "$tmp/ssh.log" ]]
jq -e '.[0].targets == ["fixture.example.test:9101"] and .[0].labels.host == "fixture-node"' "$tmp/captured/host.json" >/dev/null
jq -e '.[0].targets == ["fixture.example.test:8088"] and .[0].labels.host == "fixture-node"' "$tmp/captured/cadvisor.json" >/dev/null
jq -e '.[0].targets == ["fixture.example.test:26660"] and .[0].labels.host == "fixture-node"' "$tmp/captured/gonka-node.json" >/dev/null
printf 'PASS post-JOIN monitoring targets are registered through bash without an executable source mode\n'
PATH="$tmp/bin:$PATH" bash "$tmp/register.sh" --registry-host registry-fixture --check
if PATH="$tmp/bin:$PATH" GDC_TEST_READY_EXIT=1 bash "$tmp/register.sh" --registry-host registry-fixture --check >"$tmp/not-ready" 2>&1; then exit 1; fi
grep -q 'JOIN monitoring collector must provide' "$tmp/not-ready"
sleep() { [[ "$*" == 10 ]]; }
export -f sleep
if PATH="$tmp/bin:$PATH" GDC_TEST_SSH_LOG="$tmp/ssh.log" GDC_TEST_CAPTURE="$tmp/captured" \
  GDC_TEST_QUERY_RESPONSE='{"status":"success","data":{"result":[{"value":[1,"2"]}]}}' \
  bash "$tmp/register.sh" --registry-host registry-fixture --node fixture-node --public-host fixture.example.test >"$tmp/down" 2>&1; then exit 1; fi
grep -q 'retry this command without resetting the Host' "$tmp/down"
printf 'PASS collector readiness and incomplete scrapes fail explicitly without Host mutation\n'
