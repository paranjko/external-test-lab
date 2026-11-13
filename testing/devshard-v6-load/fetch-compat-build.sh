#!/usr/bin/env bash
# Fetch the official 0.2.16 host stack, devshardd v4.2, a v6 devshardd and two gateways, and write the build
# files for the compat scenarios. Usage: fetch-compat-build.sh <empty directory> [v6 lab candidate tag]
set -euo pipefail

dir=${1:?empty output directory}
v6_tag=${2:-lab-gonka-pr-1792-67230e4dcc0a}
here=$(cd "$(dirname "$0")" && pwd)

# Official images, pinned: the node stack of release 0.2.16 (deploy/join on main) and two gateways.
versiond=ghcr.io/product-science/versiond@sha256:e3d84b8807ea668b8e6e0a7a241d6b1ed3d50bfb336d0ffa81c04d8bf82389c3
versiond_router=ghcr.io/product-science/versiond-router@sha256:4084a91f3d805cae1371269673f03a9f12892d9644dffdcad1ffb87e215980cb
gateway_v6_rc1=ghcr.io/gonka-ai/devshard-gateway@sha256:b5b68d93a6b4477eccee07b84584b39b02ae36b2b6e50449da3af385b5566608
gateway_v42=ghcr.io/gonka-ai/devshard-gateway@sha256:00b1870af42a4cd7e04f10c09ccb9d9bb26d87044ee813516c8b149813bc836c
# devshardd v4.2: the binary mainnet and DevNet approve for v4.2.
v42_zip=https://github.com/gonka-ai/gonka/releases/download/devshard%2Fv4.2.0/devshardd.zip
v42_sha256=068599a524d4f456b36c6a208aad05d962b6751752fc0cab5991b24cf5429625

mkdir -p "$dir"
[ -z "$(ls -A "$dir")" ] || { echo "$dir is not empty" >&2; exit 1; }
cd "$dir"

mkdir v42
curl -fsSL -o v42/devshardd.zip "$v42_zip"
echo "$v42_sha256  v42/devshardd.zip" | sha256sum -c --quiet
unzip -q -d v42 v42/devshardd.zip devshardd
v42_binary=$(strings v42/devshardd | grep -o -m1 -E 'main\.BinaryVersion=[^ "]+' | cut -d= -f2 || true)
v42_binary=${v42_binary:-v4.2.0}

# v6 devshardd from the lab candidate; there is no official v6 devshardd yet.
bash "$here/fetch-build.sh" "$v6_tag" "$dir/v6" >/dev/null
v6_binary=$(sed -n 's/^binary_version: //p' v6/build.yaml)

for image in "$versiond" "$versiond_router" "$gateway_v6_rc1" "$gateway_v42"; do
  docker pull -q "$image" >/dev/null
done

# Mainnet today: v4.2 gateway in front of hosts that run v4.2 on the 0.2.16 wrapping.
cat > build-baseline.yaml <<EOF
name: compat-baseline
protocol: v4.2
binary_version: $v42_binary
devshardd: v42/devshardd
images:
  versiond: $versiond
  versiond_router: $versiond_router
  gateway: $gateway_v42
EOF

# Mainnet once v6 is approved: hosts run v6 next to v4.2, the v6 rc1 gateway sends load to v6.
# Peer transport of the DevNet v6 gateway: no HTTP/2 upgrade, no native gRPC.
cat > build-coexist.yaml <<EOF
name: compat-coexist
protocol: v6
binary_version: $v6_binary
devshardd: v6/devshardd
images:
  versiond: $versiond
  versiond_router: $versiond_router
  gateway: $gateway_v6_rc1
versions:
  - {name: v4.2, devshardd: v42/devshardd}
peer_rpc:
  grpc: false
  h2_upgrade: false
EOF
ls build-*.yaml
