#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/host.env" <<'EOF'
ROLE=ml-only
SSH_PORT=22
MONITORING_CIDR=198.51.100.10/32
ML_CLIENT_CIDR=198.51.100.20/32
GATEWAY_SERVICES=true
PUBLIC_EDGE_CIDR=198.51.100.30/32
EOF
cat >"$tmp/bin/ip" <<'EOF'
#!/usr/bin/env sh
printf 'default via 192.0.2.1 dev eth0\n'
EOF
cat >"$tmp/bin/iptables" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' "$*" >>"$GDC_FIREWALL_LOG"
case " $* " in *' -C '*) exit 1;; esac
EOF
cp "$tmp/bin/iptables" "$tmp/bin/ip6tables"
chmod 0755 "$tmp/bin/ip" "$tmp/bin/iptables" "$tmp/bin/ip6tables"

run_policy() {
  PATH="$tmp/bin:$PATH" GONKA_HOST_ENV="$tmp/host.env" \
    GDC_FIREWALL_LOG="$tmp/rules.$1" bash "$ROOT/00-host-prep/gonka-firewall.sh"
}
run_policy first
run_policy second

for log in "$tmp/rules.first" "$tmp/rules.second"; do
  grep -Fq -- '-s 198.51.100.10/32 -p tcp -m multiport --dports 26660,8088,9101 -j ACCEPT' "$log"
  grep -Fq -- '-s 198.51.100.20/32 -p tcp -m multiport --dports 5000,8080 -j ACCEPT' "$log"
  grep -Fq -- '-s 198.51.100.30/32 -p tcp -m multiport --dports 9099,18080 -j ACCEPT' "$log"
  ! grep -Fq -- '--dports 3000,8000,8081,8082,18080' "$log"
  grep -Fq -- '-A GONKA_INGRESS -j DROP' "$log"
done

# This fixture models the historical parent-chain DROP after the managed jump:
# an ACCEPT verdict ends traversal before that foreign rule, while an
# unauthorized external packet reaches the managed terminal DROP.
decision() {
  local source="$1" port="$2"
  if [[ "$source" == 198.51.100.10/32 && "$port" == 9101 ]] || \
     [[ "$source" == 198.51.100.20/32 && "$port" == 5000 ]] || \
     [[ "$source" == 198.51.100.30/32 && "$port" == 18080 ]]; then
    printf 'ACCEPT\n'
  else
    printf 'DROP\n'
  fi
}
[[ "$(decision 198.51.100.10/32 9101)" == ACCEPT ]]
[[ "$(decision 198.51.100.20/32 5000)" == ACCEPT ]]
[[ "$(decision 198.51.100.30/32 18080)" == ACCEPT ]]
[[ "$(decision 203.0.113.44/32 18080)" == DROP ]]
[[ "$(decision 203.0.113.44/32 9101)" == DROP ]]
cmp "$tmp/rules.first" "$tmp/rules.second"
printf 'PASS firewall policy fixture: explicit allows are terminal, unauthorized sources remain denied, repeated apply is stable\n'
