# Gonka release-profile history

This directory distinguishes historical network events from executable runbook
locks. `history.yaml` records the upstream chronology. Only a dated `.lock`
with complete source commits, binary checksums, compatible container tags and
OCI digests can be selected by `gdc.sh`.

## Confirmed network upgrades

| Date profile | Core | Upstream commit | Runbook status |
| --- | --- | --- | --- |
| `v2026.01.08` | `v0.2.7` | `d1816566` | history only |
| `v2026.01.29` | `v0.2.8` | `d61cf37e` | history only |
| `v2026.02.01` | `v0.2.9` | `808247ea` | history only |
| `v2026.02.18` | `v0.2.10` | `faa358de` | history only |
| `v2026.03.20` | `v0.2.11` | `54c09b35` | history only |
| `v2026.04.30` | `v0.2.12` | `1a122bcb` | history only |
| `v2026.05.26` | `v0.2.13` | `c716df26` | history only |
| `v2026.07.23` | `v0.2.14` | `2bfd85c9` | executable baseline |
| `v2026.07.30` | `v0.2.15` | `4d687ed6` | core event; use the later compatible stack |
| `v2026.08.06` | `v0.2.15` plus DAPI post3 and DevShard v4.0.1 lineage | `ce33c851` host-stack snapshot | executable target |
| `v2026.08.13` | `v0.2.15` plus DAPI post5 | `6009b539` DAPI patch | Mainnet-observed executable target |

The dates through 2026-07-30 are execution dates published by
[Gonka Network Updates](https://gonka.ai/docs/network-updates/). The
2026-08-06 identity is the date of the complete
[host-stack snapshot](https://github.com/gonka-ai/gonka/blob/ce33c851282b8f4c0f63d78d46ddd4d8bb248207/docs/host-stack-latest.md),
not the date of the core v0.2.15 governance upgrade.

Historical rows are deliberately not empty or partial `.lock` files. The
Network Updates archive proves their core upgrade event but does not preserve
every compatible image digest and host-stack input required by this runbook.

## Component updates around the current profiles

- 2026-01-05: DAPI `v0.2.6-post12` patch before the v0.2.7 core upgrade
- 2026-08-03: governed DevShard v4.0.1 runtime and DAPI `v0.2.15-post3`
- 2026-08-06: documented compatible host stack used by `v2026.08.06.lock`
- 2026-08-07: main updated the HA Compose overlay from unavailable
  `0.2.14-devshard-v4` images to versiond and versiond-router `0.2.15`
- 2026-08-13: DAPI `v0.2.15-post5` was published to race-releases and later
  observed on both canonical Mainnet seeds while core remained `v0.2.15`

The 2026-08-13 row is a software snapshot, not a protocol snapshot. Mainnet
Genesis and seed identity are verified through Gonka Network Bootstrap;
governed DevShard versions and epoch parameters are read from chain state.

## Observed next release train

[PR #1535](https://github.com/gonka-ai/gonka/pull/1535) is an open draft for
v0.2.16. At the 2026-08-09 observation point it contains an upgrade-handler
scaffold plus accumulated fixes, but its own description says the actual
migration content is still expected later.

It is not a release profile. There is no `release/v0.2.16` tag or published
compatible host-stack snapshot. The branch is behind `main`, requires review,
and its upgrade-rehearsal check is failing. A dated v0.2.16 lock may be created
only after the final tag, checksums, images, DevShard decisions and a passing
upgrade rehearsal are available.
