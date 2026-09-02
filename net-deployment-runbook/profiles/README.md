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

## Community DevNet Host requirements

[`devnet-hadware.json`](devnet-hadware.json) is the machine-readable source
for the minimum Host requirements shown on the Community DevNet site. It keeps
display text beside structured values for operating system, GPU, driver, CUDA,
CPU, memory, storage, network, ingress, and uptime.

The profile is informational and does not currently accept or reject a Host.
Its `automated_host_compliance` field remains `false` until a separate checker
implements and verifies that behavior.

## Dated release snapshots

Profile names use the UTC date on which the compatible release snapshot became
available. They are immutable: a later hotfix, image, runtime or documentation
snapshot receives a new dated profile rather than changing an existing lock.
The complete upstream chronology and observed next release train are recorded
in [releases/HISTORY.md](releases/HISTORY.md) and
[releases/history.yaml](releases/history.yaml). History entries without a
complete lock are not accepted by `gdc.sh`.

| Runbook release snapshot | Upstream ref | Commit | Basis |
| --- | --- | --- |
| v2026.07.23 | release/v0.2.14 | 2bfd85c958732992c7a9c5be1d796affe29f3ab4 | v0.2.14 executed on mainnet |
| v2026.08.06 | release/v0.2.15 | 4d687ed6782bcea3931d2d9135bf322f84e190ab | latest upstream host-stack snapshot |
| v2026.08.13 | release/v0.2.15 | 4d687ed6782bcea3931d2d9135bf322f84e190ab | Mainnet-observed core plus DAPI post5 |

`v2026.08.06` additionally pins
[host-stack snapshot `ce33c851`](https://github.com/gonka-ai/gonka/blob/ce33c851282b8f4c0f63d78d46ddd4d8bb248207/docs/host-stack-latest.md): DAPI
`release/v0.2.15-post3` and the `0.2.15` bridge image. The snapshot document
and upstream Compose file are hash-bound in the release lock.

`v2026.08.13` preserves that compatible container stack and pins the later
[DAPI `release/v0.2.15-post5`](https://github.com/gonka-ai/gonka/tree/6009b539a36b83169835ebbf1dcbbbe1b7eb1ec7)
Cosmovisor binary published by the upstream
[race-releases repository](https://github.com/product-science/race-releases/releases/tag/release/v0.2.15-post5).
Both canonical Mainnet seeds reported core `v0.2.15` at `4d687ed6` and DAPI
`v0.2.15-post5` at `6009b539` when this profile was verified on 2026-09-01.
No post5 API container or replacement full-stack snapshot was published, so
the profile does not invent either one.

A release profile describes a reproducible software target. It does not own
the chain ID, Genesis, seeds, governed DevShard allowlist, epoch settings or
other protocol state. Those values come from the network Bootstrap, live chain
state and the selected deployment profile. MLNode versions observed across
Mainnet are heterogeneous; the lock keeps the documented compatible MLNode
baseline and does not claim that every operator runs the same ML image.

## Verification findings

The dated snapshots preserve three baseline corrections:

- v2026.07.23 pins the commit of release/v0.2.14 rather than a later
  testnet/main snapshot;
- its TMKMS now uses upstream 0.2.14 instead of 0.2.11-testnet; and
- its ordinary MLNode now uses upstream 3.0.14-post2 instead of 3.0.12-post4.

The v2026.08.06 chain remains pinned to its core tag. Its host stack follows
the later upstream snapshot: DAPI `0.2.15-post3` (container and Cosmovisor
asset) and bridge `0.2.15`, each pinned by digest.
The v2026.08.13 profile records the subsequent Mainnet DAPI-only rollout. Its
container stays at post3 while the executed DAPI binary is post5, matching the
upstream Cosmovisor deployment model and the public Mainnet version readback.
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
