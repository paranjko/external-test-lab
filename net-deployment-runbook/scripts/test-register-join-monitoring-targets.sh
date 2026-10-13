#!/usr/bin/env bash
# Monitoring registration runs after a retained JOIN result. Exercise the
# helper through bash with its tracked non-executable mode, using a closed
# registry transport and inspecting the emitted discovery documents.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/captured"
install -m 0644 "$ROOT/scripts/register-join-monitoring-targets.sh" "$tmp/register.sh"

cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == registry-fixture && $# == 2 ]] || exit 41
case "$2" in
  *"/srv/dai/ops/prometheus/targets/join/host"*) ;;
  *"for job in host cadvisor gonka-node; do"*) ;;
  *) exit 42 ;;
esac
printf '%s\n' "$2" >>"$GDC_TEST_SSH_LOG"
EOF
cat >"$tmp/bin/scp" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1" == -q && $# == 5 && "$5" == registry-fixture:/tmp/gdc-monitoring-targets-fixture-node-*/* ]] || exit 51
for source in "$2" "$3" "$4"; do
  cp "$source" "$GDC_TEST_CAPTURE/$(basename "$source")"
done
EOF
chmod 0755 "$tmp/bin/ssh" "$tmp/bin/scp"

PATH="$tmp/bin:$PATH" GDC_TEST_SSH_LOG="$tmp/ssh.log" GDC_TEST_CAPTURE="$tmp/captured" \
  bash "$tmp/register.sh" --registry-host registry-fixture --node fixture-node --public-host fixture.example.test >"$tmp/out"
[[ "$(<"$tmp/out")" == 'PASS registered Prometheus discovery targets node=fixture-node registry=registry-fixture' ]]
[[ -s "$tmp/ssh.log" ]]
jq -e '.[0].targets == ["fixture.example.test:9101"] and .[0].labels.host == "fixture-node"' "$tmp/captured/host.json" >/dev/null
jq -e '.[0].targets == ["fixture.example.test:8088"] and .[0].labels.host == "fixture-node"' "$tmp/captured/cadvisor.json" >/dev/null
jq -e '.[0].targets == ["fixture.example.test:26660"] and .[0].labels.host == "fixture-node"' "$tmp/captured/gonka-node.json" >/dev/null
printf 'PASS post-JOIN monitoring targets are registered through bash without an executable source mode\n'
