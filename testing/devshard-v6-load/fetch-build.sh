#!/usr/bin/env bash
# Fetch a DevShard lab candidate release and write build.yaml for `go run ./cmd/loadtest -build`.
# Usage: fetch-build.sh <release tag> <empty directory>
set -euo pipefail

tag=${1:?release tag, e.g. lab-gonka-pr-1792-67230e4dcc0a}
dir=${2:?empty output directory}
repo=${BUILD_REPO:-paranjko/external-test-lab}
base="https://github.com/$repo/releases/download/$tag"

mkdir -p "$dir"
[ -z "$(ls -A "$dir")" ] || { echo "$dir is not empty" >&2; exit 1; }
cd "$dir"
for asset in SHA256SUMS approved-version.json artifacts.json source.json build-info.txt devshardd.zip; do
  curl -fsSL -o "$asset" "$base/$asset"
done
for asset in approved-version.json artifacts.json source.json build-info.txt devshardd.zip; do
  grep -q "  $asset\$" SHA256SUMS || { echo "$asset is not in SHA256SUMS" >&2; exit 1; }
done
sha256sum -c --ignore-missing --quiet SHA256SUMS

python3 - "$tag" <<'EOF' > build.vars
import json, sys
approved = json.load(open("approved-version.json"))
artifacts = json.load(open("artifacts.json"))["artifacts"]
zip_sha = [l.split()[0] for l in open("SHA256SUMS") if l.split()[1] == "devshardd.zip"][0]
if approved["sha256"] != zip_sha:
    sys.exit("approved-version.json sha256 differs from devshardd.zip")
binary = [l.split("main.BinaryVersion=")[1].split()[0] for l in open("build-info.txt") if "main.BinaryVersion=" in l][0]
print(f"protocol={approved['name']}")
print(f"binary_version={binary}")
for name in ("versiond", "versiond-router", "devshard-gateway"):
    print(f"{name.replace('-', '_')}={artifacts[name]['ghcr_digest_reference']}")
EOF
. ./build.vars

unzip -q devshardd.zip devshardd
for image in "$versiond" "$versiond_router" "$devshard_gateway"; do
  docker pull -q "$image" >/dev/null
done

cat > build.yaml <<EOF
name: $tag
protocol: $protocol
binary_version: $binary_version
devshardd: devshardd
images:
  versiond: $versiond
  versiond_router: $versiond_router
  gateway: $devshard_gateway
EOF
cat build.yaml
