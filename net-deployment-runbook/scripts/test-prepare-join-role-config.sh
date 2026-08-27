#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fixture="$tmp/bootstrap"
mkdir -p "$fixture/profile" "$tmp/bin"
printf '%s\n' 'join_bootstrap_format=1' >"$fixture/profile/genesis.env"
printf '%s\n' \
  'GDC_NODE_ALIASES=gdc-node0' \
  'GDC_NODE_PUBLIC_HOSTS=gdc-node0=node0.example.net' \
  'GDC_NODE_P2P_PORTS=gdc-node0=5000' \
  'GDC_NODE_ML_HOSTS=' \
  'GDC_GENESIS_NODE=gdc-node0' \
  'GDC_PUBLIC_EDGE_NODE=gdc-node0' \
  'GDC_GATEWAY_NODE=gdc-node0' >"$fixture/topology.env"
(cd "$fixture" && sha256sum topology.env profile/genesis.env >manifest.sha256)
sed -i 's#  topology.env#  ./topology.env#; s#  profile/genesis.env#  ./profile/genesis.env#' "$fixture/manifest.sha256"

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
out=''
url=''
while (($#)); do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  */manifest.sha256) source="$JOIN_FIXTURE/manifest.sha256" ;;
  */topology.env) source="$JOIN_FIXTURE/topology.env" ;;
  */profile/genesis.env) source="$JOIN_FIXTURE/profile/genesis.env" ;;
  *) exit 2 ;;
esac
cp "$source" "$out"
EOF
chmod +x "$tmp/bin/curl"

cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'hostname node2.example.net\n'
EOF
chmod +x "$tmp/bin/ssh"
cat >"$tmp/bin/getent" <<'EOF'
#!/usr/bin/env bash
printf '192.0.2.2 STREAM node2.example.net\n'
EOF
chmod +x "$tmp/bin/getent"

env -u JOIN_BOOTSTRAP_FORMAT \
  PATH="$tmp/bin:$PATH" JOIN_FIXTURE="$fixture" \
  GDC_RELEASE_PROFILE=v2026.07.23 \
  "$ROOT/scripts/prepare-join-role-config.sh" \
  --output "$tmp/join.env" --ssh-alias gdc-node2 --public-host node2.example.net \
  --bootstrap-url https://bootstrap.example.net/join-bootstrap

source "$tmp/join.env"
[[ "$GDC_GENESIS_NODE" == gdc-node0 ]]
[[ "$GDC_NODE_PUBLIC_HOSTS" == *'gdc-node2=node2.example.net'* ]]
[[ "$GDC_JOIN_BOOTSTRAP_MANIFEST_SHA256" == "$(sha256sum "$fixture/manifest.sha256" | awk '{print $1}')" ]]

PATH="$tmp/bin:$PATH" JOIN_FIXTURE="$fixture" GDC_RELEASE_PROFILE=v2026.07.23 \
  "$ROOT/scripts/prepare-join-role-config.sh" \
  --output "$tmp/arbitrary.env" --ssh-alias validator-west --public-host node2.example.net \
  --bootstrap-url https://bootstrap.example.net/join-bootstrap
source "$tmp/arbitrary.env"
[[ "$GDC_NODE_ALIASES" == *'validator-west'* ]]

if PATH="$tmp/bin:$PATH" JOIN_FIXTURE="$fixture" GDC_RELEASE_PROFILE=v2026.07.23 \
  "$ROOT/scripts/prepare-join-role-config.sh" \
  --output "$tmp/invalid-alias.env" --ssh-alias Validator.West --public-host node2.example.net \
  --bootstrap-url https://bootstrap.example.net/join-bootstrap >"$tmp/invalid-alias.stdout" 2>"$tmp/invalid-alias.stderr"; then
  echo 'JOIN role preparation accepted a Compose-unsafe SSH alias' >&2
  exit 1
fi
grep -Fq 'invalid JOIN SSH alias' "$tmp/invalid-alias.stderr"

printf '<html>not a manifest</html>\n' >"$fixture/manifest.sha256"
if PATH="$tmp/bin:$PATH" JOIN_FIXTURE="$fixture" GDC_RELEASE_PROFILE=v2026.07.23 \
  "$ROOT/scripts/prepare-join-role-config.sh" \
  --output "$tmp/invalid.env" --ssh-alias gdc-node2 --public-host node2.example.net \
  --bootstrap-url https://bootstrap.example.net/join-bootstrap >"$tmp/invalid.stdout" 2>"$tmp/invalid.stderr"; then
  echo 'JOIN role preparation accepted a non-manifest bootstrap response' >&2
  exit 1
fi
grep -Fq 'public JOIN bootstrap manifest lacks topology/profile checksum entries' "$tmp/invalid.stderr"

(cd "$fixture" && sha256sum topology.env profile/genesis.env >manifest.sha256)
sed -i 's#  topology.env#  ./topology.env#; s#  profile/genesis.env#  ./profile/genesis.env#' "$fixture/manifest.sha256"
printf '%s\n' 'GDC_NODE_ALIASES=gdc-node0 gdc-node1' >"$fixture/topology.env"
if PATH="$tmp/bin:$PATH" JOIN_FIXTURE="$fixture" GDC_RELEASE_PROFILE=v2026.07.23 \
  "$ROOT/scripts/prepare-join-role-config.sh" \
  --output "$tmp/mismatch.env" --ssh-alias gdc-node2 --public-host node2.example.net \
  --bootstrap-url https://bootstrap.example.net/join-bootstrap >"$tmp/mismatch.stdout" 2>"$tmp/mismatch.stderr"; then
  echo 'JOIN role preparation accepted a checksum mismatch' >&2
  exit 1
fi
grep -Fq 'public JOIN bootstrap checksum mismatch bootstrap_url=https://bootstrap.example.net/join-bootstrap file=./topology.env expected_sha256=' "$tmp/mismatch.stderr"
grep -Fq 'actual_sha256=' "$tmp/mismatch.stderr"
grep -Fq -- '--retry-all-errors' "$ROOT/scripts/prepare-join-role-config.sh"
grep -Fq -- '--retry-all-errors' "$ROOT/scripts/fetch-join-bootstrap.sh"
printf 'PASS JOIN role configuration loads its release compatibility profile\n'
