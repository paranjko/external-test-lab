# DevShard v6 archive release

Builds `devshardd.zip` for `approved_versions`: a lab candidate, not an official
Gonka release or v6 qualification result. No gateway, versiond, deployment or
governance changes are included.

[`devshard-v6.json`](devshard-v6.json) pins the source commit/tree, protocol,
binary stamp, tag, platform and Docker bases. Updates require manifest review
and a new tag. The binary is Linux amd64, uses `muslc` without test tags and
upstream `BLST_PORTABLE=0`; check target CPU compatibility before rollout.
The runtime must supply musl and `libgcc_s.so.1`; neither is bundled.

## Build locally

Requires Git, Make, Python 3.11+, Go, Docker Buildx, Bash, curl, unzip, zipinfo,
binutils (`nm`, `objdump`) and GNU tools. From an External Test Lab checkout,
fetch into a new directory and build:

```sh
make -C net-deployment-runbook test-devshard-release
DEVSHARD_SOURCE=/absolute/path/to/gonka \
  make -C net-deployment-runbook devshard-release-fetch
DEVSHARD_SOURCE=/absolute/path/to/gonka \
  make -C net-deployment-runbook devshard-release-build
make -C net-deployment-runbook devshard-release-verify
```

Output: `net-deployment-runbook/.data/devshard-release/`. For another build,
set `DEVSHARD_RELEASE_DIR` to a new absolute path on build and verify commands.
Nonempty output directories are rejected; only committed source enters Docker.

Checks cover ZIP layout/mode, ELF architecture, both protocol symbols, build
flags and binary stamp. Version-command smoke runs in isolated Alpine with the
builder's libgcc, not the deployed versiond image; it does not qualify a runtime.

## Publish after merge

```sh
gh workflow run devshard-release.yml \
  --repo paranjko/external-test-lab --ref main
```

Wait for both jobs to pass, then check the
[prerelease](https://github.com/paranjko/external-test-lab/releases).
The build job fetches public source without Git credentials and runs it only
inside Docker, without runner tokens or caches. A separate publisher verifies
the assets without executing the binary, uploads a draft, downloads and compares
all bytes, then publishes. Existing tags are never overwritten. Failed uploads
or readbacks leave a draft: investigate before retrying.

Assets:

- `devshardd.zip`: one root executable, `devshardd`, mode 0755.
- `SHA256SUMS`: checksums of the other four assets.
- `source.json`, `build-info.txt`: source and build metadata.
- `approved-version.json`: one `{name, binary, sha256}` entry.

After publication and checksum verification, review and append the entry;
preserve existing approved versions. Its URL is tag-specific; SHA256 covers
the ZIP, not the executable. Compatibility review and governance approval
remain required before rollout.

## DevShard v6 artifact bundle

After merge, dispatch [DevShard v6 artifact release](../../.github/workflows/devshard-artifacts-release.yml) on `main`, it builds seven v6 images and the separately frozen v4.2 gateway without using local build outputs

The bundle reuses the published v6 ZIP and pins legacy binaries and wrapping images, Core, Cosmovisor, ML and Postgres are not rebuilt

Release assets contain OCI archives, digest-pinned pull references, source identities, checksums and a [coverage map](devshard-v6-coverage.json) for all 42 manual cases

Anonymous GHCR verification must pass, newly created packages may need the owner to make them public, then rerun only the failed publisher job with its retained bundle

This supplies the artifacts for [issue 225](https://github.com/paranjko/external-test-lab/issues/225), it does not deploy gateways, configure HA or qualify inference

With old wrapping, explicitly override `DEVSHARD_RPC_H2_UPGRADE=false` and inspect the resolved Compose configuration, the frozen [Compose source](https://github.com/gonka-ai/gonka/blob/e9d56e2a4e810788ec4be39725026cd892cf1080/deploy/join/docker-compose.versiond.yml#L50-L53) overrides `env_file`, and peer RPC has no automatic [HTTP/1.1 fallback](https://github.com/gonka-ai/gonka/blob/e9d56e2a4e810788ec4be39725026cd892cf1080/devshard/transport/peerconn.go#L984-L991)
