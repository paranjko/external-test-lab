# Portable runtime for a Host without ADX/BMI2

Published `amd64` images link BLST built for ADX/BMI2. On a CPU without them
(observed on Xeon E5-2697 v2) every `decentralized-api` and `inferenced` call
dies with `Caught SIGILL in blst_cgo_init`. Upstream Dockerfiles accept
`BLST_PORTABLE=1`, but no portable image is published.

The published Core image `inferenced:0.2.15` is also stamped with commit
`4fa6be02…` instead of the tag commit `4d687ed6…` that the network reports, so
the canonical readback refuses it. Building from the tag fixes both.

## Build on the Host

DAPI, tag `release/v0.2.15-post3` (commit `5dbb53dd…`, pinned by the Join Profile):

```bash
git clone --depth 1 --branch release/v0.2.15-post3 https://github.com/gonka-ai/gonka.git
cd gonka
docker build \
  --platform linux/amd64 \
  --build-arg GOOS=linux --build-arg GOARCH=amd64 \
  --build-arg BLST_PORTABLE=1 \
  --build-arg DEVSHARD_VERSION=0.2.15-post3 \
  --build-arg LDFLAGS="-X github.com/cosmos/cosmos-sdk/version.Name=decentralized-api -X github.com/cosmos/cosmos-sdk/version.AppName=decentralized-api -X github.com/cosmos/cosmos-sdk/version.Version=0.2.15-post3 -X github.com/cosmos/cosmos-sdk/version.Commit=5dbb53ddf3ddc42655fc04dc39d96003169bdbb0" \
  -f decentralized-api/Dockerfile \
  -t local/gonka-api:0.2.15-post3-portable \
  .
```

Core, tag `release/v0.2.15`:

```bash
git clone --depth 1 --branch release/v0.2.15 https://github.com/gonka-ai/gonka.git gonka-core
cd gonka-core
docker build \
  --platform linux/amd64 \
  --build-arg GOOS=linux --build-arg GOARCH=amd64 \
  --build-arg BLST_PORTABLE=1 \
  --build-arg GENESIS_OVERRIDES_FILE=inference-chain/prod_genesis_overrides.json \
  --build-arg LDFLAGS="-X github.com/cosmos/cosmos-sdk/version.Name=inference-chain -X github.com/cosmos/cosmos-sdk/version.AppName=inferenced -X github.com/cosmos/cosmos-sdk/version.Version=0.2.15 -X github.com/cosmos/cosmos-sdk/version.Commit=$(git log -1 --format=%H)" \
  -f inference-chain/Dockerfile \
  -t local/gonka-inferenced:0.2.15-portable \
  .
```

## Verify

```bash
docker run --rm --entrypoint /bin/sh local/gonka-api:0.2.15-post3-portable -c \
  'decentralized-api version --long; echo ---; inferenced version'
```

Expect `version: 0.2.15-post3`, `commit: 5dbb53ddf3ddc42655fc04dc39d96003169bdbb0`
and no `blst_cgo_init` line.

## Declare

Both values must be digest-qualified:

```bash
export GDC_PORTABLE_CORE_IMAGE="$(docker image inspect local/gonka-inferenced:0.2.15-portable --format '{{index .RepoDigests 0}}')"
export GDC_PORTABLE_DAPI_IMAGE="$(docker image inspect local/gonka-api:0.2.15-post3-portable --format '{{index .RepoDigests 0}}')"
```

## Limits

The binaries match the pinned version and commit but are not the published
artifacts, so JOIN evidence is not artifact-verified. Test lab only. The upstream
fix is a portable variant in `.github/workflows/docker-build.yml`.
