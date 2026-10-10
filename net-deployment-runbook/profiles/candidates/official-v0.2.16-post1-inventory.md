# Official v0.2.16-post1 profile inputs

Collected 2026-10-08. Metadata inventory only; qualification belongs on the
test stand. No deployment or runtime compatibility claim is made here.
Published checksums below are release metadata, not a claim of local archive
verification. Downloading every platform archive is not a preparation gate.

## Sources and scope

- [Official upgrade proposal](https://github.com/gonka-ai/gonka/blob/136041c81ea8ff38e7620d76af66a7c7fe7eec50/proposals/governance-artifacts/update-v0.2.16/README.md)
- [Release assets](https://github.com/gonka-ai/gonka/releases/tag/release/v0.2.16-post1)
- [Release metadata API](https://api.github.com/repos/gonka-ai/gonka/releases/tags/release%2Fv0.2.16-post1)
- [JOIN containers](https://github.com/gonka-ai/gonka/blob/136041c81ea8ff38e7620d76af66a7c7fe7eec50/deploy/join/docker-compose.yml)
- [JOIN ML containers](https://github.com/gonka-ai/gonka/blob/136041c81ea8ff38e7620d76af66a7c7fe7eec50/deploy/join/docker-compose.mlnode.yml)

Source tag: `release/v0.2.16-post1`; resolved commit:
`136041c81ea8ff38e7620d76af66a7c7fe7eec50`; commit time:
`2026-10-06T01:41:24Z`. This is the core source date, not yet the name of a
complete Host composition: other components have separate source identities.

The official upgrade replaces chain/API binaries without requiring replacement
of their existing container envelopes. DevShard versions remain governed by
the separate approval catalogue. Do not equate a 0.2.15 envelope image with
an executing 0.2.15 binary after upgrade. New JOIN and existing-host upgrade
are distinct profile targets.

## Official binary inputs

Each filename below is relative to this exact URL prefix:
`https://github.com/gonka-ai/gonka/releases/download/release%2Fv0.2.16-post1/`.

| Asset | Published SHA256 |
|---|---|
| inferenced-amd64.zip | d2ef13374fb15518a02ae5fac83d139d66fb79a8c93d97f4e78b43ce30e14f98 |
| decentralized-api-amd64.zip | f64b9433cd27d9ee433f1aede89d6be910f6deb8df644d55e2dfe30b8f873802 |
| edge-api-amd64.zip | 274c110a82b480cf91ad113f3e7a94b2602ed2b1429732b4ef7c9e580395a51d |
| inferenced-linux-amd64.zip | 50b333ea4680a05f18a69f30f284357b173c9d68b193e9028b603c67c1d5697f |
| inferenced-linux-arm64.zip | 7e0a21c5b1336ec941dd7d73d00c8971ca6a6ce592cd77386c102d00d0dea0c2 |
| inferenced-darwin-amd64.zip | 9f798af8cb74852d1c4cb283362d5f9dc2b7b72e204f0e09c2139341f7d19912 |
| inferenced-darwin-arm64.zip | 38a8b9b9cc6fa6743dc3de91dd95bf6d68c9765296efab8362c100bbe710d370 |

Map the first two to `INFERENCED_UPGRADE_*` and `DAPI_UPGRADE_*`; map the
four operator assets to `INFERENCED_OPERATOR_URL_*` and
`INFERENCED_OPERATOR_SHA256_*`. The edge archive is published, but its
presence alone does not mean the chain upgrade installs it automatically.

## Container inputs

Unless stated otherwise, images use the `ghcr.io/product-science/` namespace.
Unchanged digests are inherited metadata from `profiles/releases/v2026.08.06.lock`,
not a fresh registry verification. Their tags match the pinned JOIN source.

| Component | Source tag | Digest or missing input |
|---|---|---|
| TMKMS | tmkms-softsign-with-keygen:0.2.15 | sha256:c3b6c4aaa73e93944dda4f08db8edd1a48544ad35d740cfca2dd8f3d9835aa21 |
| Chain envelope | inferenced:0.2.15 | sha256:b9ef3af7b89cae7c5c5dd28dc207e5cdff9db6cfeb2cb33cd7bd2d73893bb112 |
| API envelope | api:0.2.15-post3 | sha256:3f81b7a9dfac66690e4a934a916662b248f20838dd8f7b47f1863fd3c5c5cd9c |
| Edge API | edge-api:0.2.15 | sha256:4f98b337ea837d711bdd7e0d0e3172a0034f37a5f7fb9764251b7155bb727025 |
| Bridge | bridge:0.2.15 | sha256:ac01165eb8eb60dbafe5d1e060a11b474efb44146b12f308bef6153b55a2c22d |
| Versiond | versiond:0.2.15-devshard-v5 | Registry lookup returned not found |
| Proxy policy | proxy:0.2.15-devshard-v5 | Registry lookup returned not found |
| Proxy router | proxy-router:0.2.15-devshard-v5 | Registry lookup returned HTTP 403; availability unresolved |
| Optional TLS proxy | proxy-ssl:0.2.15 | sha256:2e2a296481bd957a74193f12a2867bf969efd8a6bd7cdde51ba561a4e86d838c (registry metadata) |
| MLNode | ghcr.io/gonka-ai/mlnode:3.0.16 | sha256:1b9b7ce55feecab837f1d7ce974fc5f377ae0a04a4fb403eeeb50130e7728ee1 (pinned directly in JOIN source) |
| ML proxy | nginx:1.28.0 | sha256:552e7481ca93ffccd046aa658dbbed22caefbc09c66fa7cd247cbb90b8a5c609 (base profile) |

Explorer and observability services belong to the operator-services profile,
not the network release lock. Optional DevShard gateway/storage layouts must
be inventoried separately if selected; the table is not their inventory.

## DevShard approval metadata

The mainnet catalogue observed during this collection named:

| Protocol | Published binary URL | SHA256 |
|---|---|---|
| v4.1 | https://github.com/gonka-ai/gonka/releases/download/release%2Fdevshard%2Fv4.1.0/devshardd.zip | 69e58e6b6c124fc218d3ed1e38d7853c0a8ce20df660d348fc28ccd249a1ccf1 |
| v5 | https://github.com/gonka-ai/gonka/releases/download/devshard%2Fv5.0.2/devshardd.zip | fa9f30775abfc14c40ac8d8a9bae7159f6193cd820f3dfac06a60170cd8b48a1 |

Read the destination network's own approval catalogue when assembling its
profile. Mainnet approval is not devnet governance authorization.

## Remaining data before a complete lock

1. Obtain the published identities/digests for the three unresolved
   versiond/proxy images, or an explicit upstream replacement. Do not silently
   substitute old images or lab builds.
2. Bind source commits/timestamps and target platforms for all selected images,
   including inherited components. Use the newest component source UTC date
   to name a complete composition; do not use the collection date.
3. Select the intended deployment layout, model profile and any hardware-specific
   ML variant. Keep defaults unchanged until the profile is explicitly selected.
4. Assemble the immutable candidate lock from these inputs. Perform artifact
   download, installation, inference and PoC/cPoC qualification on the stand,
   retaining verdicts separately from this metadata inventory.

## Selected existing-host target

The later [v2026.10.06 lock](../releases/v2026.10.06.lock) records the selected existing-host target, including explicit `gonka-ai` namespace images for versiond and the proxy services, the earlier lookup failures above describe the original `product-science` inventory

The target pins Core and DAPI upgrade archives for `v0.2.16-post1`, the governance plan remains `v0.2.16`, and MLNode is pinned to the `3.0.16` image declared in the official JOIN source linked above

This is an existing-host recovery input, not a default-profile change or a ready-to-apply fresh JOIN composition, the current image envelopes still require the pinned upgraded binaries and the proxy router requires its policy services

The separate [v2026.09.13 lock](../releases/v2026.09.13.lock) identifies DevShard `v5.0.0`, it neither selects the Core/DAPI/MLNode stack nor authorizes replacing the destination network's governed DevShard catalogue

Run `make test` from `net-deployment-runbook` to check both named profile contracts, these checks validate the recorded inputs and loader behavior, not live deployment, inference or PoC admission
