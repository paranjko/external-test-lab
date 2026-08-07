# Profile boundaries and upstream verification

The runbook deliberately keeps four independent profile classes:

| Profile | Owns | Does not claim |
| --- | --- | --- |
| releases | Gonka core binaries plus an explicitly pinned upstream host-stack snapshot when post-release components differ | Lab timings, hardware exceptions or observability versions |
| deployments | Community Test Lab chain parameters, storage dependencies, hardware compatibility and governed DevShard overlays | That these inputs belong to the core Gonka tag |
| models | Model identity, revision and PoC/runtime parameters | A Gonka software release |
| operator-services | Caddy, Prometheus, Grafana, Alertmanager and exporters | Consensus, inference or protocol compatibility |

The network profile hash covers release + deployment + model. Operator-service
software has a separate hash, so updating Grafana cannot silently change the
identity of the network release under test.

## Verified upstream refs

| Runbook release | Upstream ref | Commit |
| --- | --- | --- |
| testnet-0.2.14 | release/v0.2.14 | 2bfd85c958732992c7a9c5be1d796affe29f3ab4 |
| testnet-0.2.15 | release/v0.2.15 | 4d687ed6782bcea3931d2d9135bf322f84e190ab |

`testnet-0.2.15` additionally pins
[host-stack snapshot `ce33c851`](https://github.com/gonka-ai/gonka/blob/ce33c851282b8f4c0f63d78d46ddd4d8bb248207/docs/host-stack-latest.md): DAPI
`release/v0.2.15-post3` and the `0.2.15` bridge image. The snapshot document
and upstream Compose file are hash-bound in the release lock.

## Verification findings

The 2026-08-06 comparison corrected three baseline drifts:

- testnet-0.2.14 now pins the commit of release/v0.2.14 rather than a later
  testnet/main snapshot;
- its TMKMS now uses upstream 0.2.14 instead of 0.2.11-testnet; and
- its ordinary MLNode now uses upstream 3.0.14-post2 instead of 3.0.12-post4.

The testnet-0.2.15 chain remains pinned to its core tag. Its host stack follows
the later upstream snapshot: DAPI `0.2.15-post3` (container and Cosmovisor
asset) and bridge `0.2.15`, each pinned by digest.
Registry verification also exposed that upstream Explorer latest had moved.
Explorer therefore remains digest-pinned as operator software and does not
participate in the network release hash.

Run:

    make verify-upstream-profiles
    ./scripts/verify-release-profiles.sh --registry

The verifier reads the local code/gonka tags and pinned host-stack commit. It
compares the core tag, snapshot hashes, DAPI source commit, and active images
for tmkms, node, API, edge-api where present, versiond,
proxy, explorer, bridge, MLNode and its inference proxy.

Digest pins remain stricter runbook inputs layered on top of the image
name/tag found in upstream Compose.
The optional registry form additionally compares every pinned digest with the
published manifest behind that upstream tag.

## Explicit non-release inputs

- PostgreSQL is a runbook-provided DAPI payload-store dependency.
- The Blackwell MLNode image is a hardware compatibility override for the
  split ML host.
- DevShard v3/v4 binaries and the locally built gateway come from their own
  governed DevShard release refs.
- Caddy and the monitoring stack are operator-owned support software.
- Explorer is operator-facing software. Upstream declares it as mutable
  `latest`; the lab keeps a separately qualified digest outside the network
  release hash.
- The inferenced operator CLI is derived from the selected network
  INFERENCED_IMAGE and cannot drift independently.
- Upstream proxy-ssl is not deployed: the lab terminates TLS with its
  operator-owned Caddy edge.
