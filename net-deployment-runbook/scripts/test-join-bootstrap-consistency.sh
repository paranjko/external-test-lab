#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fixture="$tmp/bootstrap"
paths=(genesis/genesis.json genesis/genesis.sha256 genesis/genesis-seeds.txt profile/genesis.env topology.env gateway/join-client-key)
for path in "${paths[@]}"; do
  mkdir -p "$fixture/$(dirname "$path")"
  printf 'fixture:%s\n' "$path" >"$fixture/$path"
done
printf 'release_profile=v2026.07.23\njoin_bootstrap_format=1\n' >"$fixture/profile/genesis.env"
printf '%s\n' \
  'GDC_NODE_ALIASES=gdc-node0 validator-west' \
  'GDC_NODE_PUBLIC_HOSTS=gdc-node0=node0.example.test validator-west=validator.example.test' \
  'GDC_NODE_P2P_PORTS=gdc-node0=5000 validator-west=5000' \
  'GDC_NODE_ML_HOSTS=' \
  'GDC_GENESIS_NODE=gdc-node0' \
  'GDC_PUBLIC_EDGE_NODE=gdc-node0' \
  'GDC_GATEWAY_NODE=gdc-node0' >"$fixture/topology.env"
for path in "${paths[@]}"; do
  printf '%s  ./%s\n' "$(sha256sum "$fixture/$path" | awk '{print $1}')" "$path"
done >"$fixture/manifest.sha256"

mkdir -p "$tmp/bin"
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output=''
url=''
while (($#)); do
  case "$1" in
    -o) output="$2"; shift 2 ;;
    -w) shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
path="${url#*join-bootstrap/}"
cp "$JOIN_FIXTURE/$path" "$output"
printf '200'
EOF
cat >"$tmp/bin/getent" <<'EOF'
#!/usr/bin/env bash
printf '192.0.2.10 STREAM example.test\n'
EOF
chmod +x "$tmp/bin/curl" "$tmp/bin/getent"

role="$tmp/join.env"
cat >"$role" <<'EOF'
GDC_RELEASE_PROFILE=v2026.07.23
GDC_DEPLOYMENT_PROFILE=community-lab
GDC_OPERATOR_SERVICES_PROFILE=gdc-lab
GDC_NODE_ALIASES='gdc-node0 validator-west'
GDC_NODE_PUBLIC_HOSTS='gdc-node0=node0.example.test validator-west=validator.example.test'
GDC_NODE_P2P_PORTS='gdc-node0=5000 validator-west=5000'
GDC_NODE_ML_HOSTS=''
GDC_GENESIS_NODE=gdc-node0
GDC_PUBLIC_EDGE_NODE=gdc-node0
GDC_GATEWAY_NODE=gdc-node0
GDC_JOIN_BOOTSTRAP_URL=https://bootstrap.example.test/join-bootstrap
GDC_JOIN_BOOTSTRAP_MANIFEST_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF

if PATH="$tmp/bin:$PATH" JOIN_FIXTURE="$fixture" GDC_HOME="$tmp/home" GDC_ENV="$role" \
  "$ROOT/scripts/fetch-join-bootstrap.sh" >"$tmp/fetch.out" 2>"$tmp/fetch.err"; then
  echo 'JOIN bootstrap accepted a manifest that differs from the prepared role topology' >&2
  exit 1
fi
grep -Fq 'public JOIN bootstrap changed after its role topology was prepared' "$tmp/fetch.err"
[[ ! -e "$tmp/home/genesis/genesis.json" ]]

mkdir -p "$tmp/home/state"
printf 'schema_version=1\n' >"$tmp/home/state/join-bootstrap-dispatched.manifest.sha256"
if PATH="$tmp/bin:$PATH" JOIN_FIXTURE="$fixture" GDC_HOME="$tmp/home" GDC_ENV="$role" \
  "$ROOT/scripts/fetch-join-bootstrap.sh" >"$tmp/dispatched-fetch.out" 2>"$tmp/dispatched-fetch.err"; then
  echo 'JOIN bootstrap accepted a manifest that differs after dispatch binding' >&2
  exit 1
fi
grep -Fq 'public JOIN bootstrap changed after dispatch binding; preserve the current state and use the separately validated diagnosis or recovery workflow' "$tmp/dispatched-fetch.err"
! grep -Fq 'no Host mutation was made' "$tmp/dispatched-fetch.err"
[[ ! -e "$tmp/home/genesis/genesis.json" ]]
printf 'PASS JOIN bootstrap preserves one prepared manifest identity before Host mutation\n'
