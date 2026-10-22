#!/usr/bin/env bash
# Fetch the official v4.2 host stack, the v6 rc1 gateway and a v6 devshardd, and write three build files
# for the compat-v42 scenarios. Usage: fetch-compat-build.sh <empty directory> [v6 lab candidate tag]
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
v42_binary=${v42_binary:-devshard-v4.2.0}

bash "$here/fetch-build.sh" "$v6_tag" "$dir/v6" >/dev/null

for image in "$versiond" "$versiond_router" "$gateway_v6_rc1" "$gateway_v42"; do
  docker pull -q "$image" >/dev/null
done

# Peer transport of the DevNet v6 gateway: no HTTP/2 upgrade, no native gRPC.
peer_rpc='peer_rpc:\n  grpc: false\n  h2_upgrade: false\n'

write() {
  cat > "$1" <<EOF
name: $2
protocol: v4.2
binary_version: $v42_binary
devshardd: v42/devshardd
images:
  versiond: $versiond
  versiond_router: $versiond_router
  gateway: $3
EOF
}
# Mainnet today: v4.2 gateway in front of v4.2 hosts.
write build-baseline.yaml compat-v42-baseline "$gateway_v42"
# Only the gateway moves to v6 rc1; it keeps serving v4.2 routes.
write build-all.yaml compat-v42-all "$gateway_v6_rc1"
printf 'gateway:\n  route_prefix: /devshard/v4.2\n  escrow_route_prefix: /devshard/v4.2\n' >> build-all.yaml
printf "$peer_rpc" >> build-all.yaml
# The same with the gateway's height-seed gate off: does only the gate stop v4.2 escrows?
awk '{ sub(/^name: compat-v42-all$/, "name: compat-v42-all-noseed"); print }
  /^  escrow_route_prefix:/ { print "  env:"; print "    DEVSHARD_REQUIRE_HEIGHT_SEED: \"false\"" }' build-all.yaml > build-all-noseed.yaml
# Rollout: hosts also run v6; starting escrows stay on v4.2, the gateway creates new ones on v6.
write build-rollover.yaml compat-v42-rollover "$gateway_v6_rc1"
printf 'versions:\n  - {name: v6, devshardd: v6/devshardd}\ngateway:\n  route_prefix: /devshard/v6\n  escrow_route_prefix: /devshard/v4.2\n' >> build-rollover.yaml
printf "$peer_rpc" >> build-rollover.yaml
ls build-*.yaml
