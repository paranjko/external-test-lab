#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT

python3 - "$temporary/bootstrap.json" <<'PY'
import base64, hashlib, json, sys
raw=b'{"chain_id":"gonka-fixture"}\n'
json.dump({
  "$schema":"https://gonka-dev.net/v1.bootstrap.schema.json",
  "chain_id":"gonka-fixture",
  "genesis":{"encoding":"base64","sha256":hashlib.sha256(raw).hexdigest(),"data":base64.b64encode(raw).decode()},
  "seeds":[{"node_id":"0123456789abcdef0123456789abcdef01234567","host":"seed.example.net","port":5000}]
}, open(sys.argv[1], "w"))
PY

"$ROOT/scripts/prepare-join-role-config.sh" \
  --output "$temporary/mitch-demo.env" --ssh-alias mitch-demo \
  --public-host host.example.net --p2p-port 5200 \
  --gpu-ssh-alias mitch-ml --bootstrap-file "$temporary/bootstrap.json"

source "$temporary/mitch-demo.env"
[[ "$GDC_NODE_ALIASES" == mitch-demo ]]
[[ "$GDC_NODE_PUBLIC_HOSTS" == mitch-demo=host.example.net ]]
[[ "$GDC_NODE_P2P_PORTS" == mitch-demo=5200 ]]
[[ "$GDC_NODE_ML_HOSTS" == mitch-demo=mitch-ml ]]
[[ "$GDC_JOIN_NETWORK_HOST" == seed.example.net ]]
[[ "$GDC_JOIN_BOOTSTRAP_SCHEMA" == https://gonka-dev.net/v1.bootstrap.schema.json ]]
! grep -Rq 'JOIN_BOOTSTRAP_FORMAT\|join-bootstrap\|topology.env\|profile/genesis.env' "$ROOT/scripts/prepare-join-role-config.sh"

if "$ROOT/scripts/prepare-join-role-config.sh" --output "$temporary/invalid.env" \
  --ssh-alias Mitch --public-host host.example.net --bootstrap-file "$temporary/bootstrap.json" \
  >"$temporary/invalid.out" 2>"$temporary/invalid.err"; then
  echo 'JOIN role preparation accepted an unsafe alias' >&2
  exit 1
fi
grep -Fq 'invalid JOIN SSH alias' "$temporary/invalid.err"
printf 'PASS one-file JOIN role preparation accepts arbitrary local aliases without topology import\n'
