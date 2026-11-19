# Community DevNet network history

Every change to the running network: proposals, upgrades, hosts added or retired. One line per change, newest last.

## Genesis

| Chain ID | Genesis SHA-256 | Genesis time |
|---|---|---|
| `gonka-devnet-community` | `7c76efc5…8262e` ([genesis](genesis/7c76efc566f094fad5b221f331596673a206d79af79e5325cec6b40a9f78262e/)) | 2026-10-20 12:06 UTC |

Earlier histories with the same chain ID are not recorded here.

## Changes

| Date (UTC) | Change | Why / link |
|---|---|---|
| 2026-10-20 | Proposal 1: update approved DevShard versions | run v6 from the [lab build](https://github.com/paranjko/external-test-lab/releases/tag/lab-gonka-pr-1792-67230e4dcc0a) of gonka-ai/gonka#1792 |
| 2026-10-20 | Proposal 2: restore genesis guardian host roles and source PoC model field | carry the previous network's values over, [proposal 2](https://node0.gonka-dev.net/chain-api/cosmos/gov/v1/proposals/2) |
| 2026-10-21 | Proposal 3: replace DevShard escrow creator allowlist | only the three stand gateway accounts open escrows, [proposal 3](https://node0.gonka-dev.net/chain-api/cosmos/gov/v1/proposals/3) |
| 2026-10-23 | Proposal 4: update approved DevShard versions | v6 to the official `v6.0.0-rc1` build for the load tests, #282 |
| 2026-10-23 | Proposal 6: raise the DevShard nonce limit to match Mainnet (proposal 5 rejected) | load tests, #282 |
| 2026-10-26 | Proposal 8: disable confirmation PoC (proposal 7 rejected) | load tests, #282 |
| 2026-10-27 | Validators 10 → 5: node3, node5, node6 and node9 become ML nodes of node0, node8, node2 and node10; node7 retired; Qwen3-0.6B removed | not recorded |
| 2026-10-27 | Proposal 9: disable Guardian fallback for DevNet model groups | not recorded, [proposal 9](https://node0.gonka-dev.net/chain-api/cosmos/gov/v1/proposals/9) |
| 2026-10-27 | Proposal 10: four expected confirmation PoCs per epoch | not recorded, [proposal 10](https://node0.gonka-dev.net/chain-api/cosmos/gov/v1/proposals/10) |
| 2026-10-28 | Proposal 11: pause confirmation PoC | not recorded, [proposal 11](https://node0.gonka-dev.net/chain-api/cosmos/gov/v1/proposals/11) |
| 2026-10-28 | Proposal 12: epoch length 15391 blocks | not recorded, [proposal 12](https://node0.gonka-dev.net/chain-api/cosmos/gov/v1/proposals/12) |
| 2026-10-28 | Proposal 13: four confirmation PoCs on the long epoch | not recorded, [proposal 13](https://node0.gonka-dev.net/chain-api/cosmos/gov/v1/proposals/13) |
| 2026-11-02 | node14 replaces node4 as the ops host: monitoring, faucet, public site | node4 kept dropping off at its provider |
| 2026-11-02 | Proposal 14: epoch length 1311 blocks | #299 |
| 2026-11-03 | Proposal 15: approve DevShard v6.0.0 for v6 | #300 |
| 2026-11-03 | DevShard wrapper on every host to v6.0.0 | #298 |
| 2026-11-04 | node12 joins as a Qwen3-4B validator; node11 keeps only 7B | #295 |
| 2026-11-04 | node13 replaces node6 as the ML node of node2; node15 becomes the load host | #302 |
| 2026-11-05 | Proposal 16: restore confirmation PoC | back after the epoch change, #299 |
| 2026-11-05 | Proposal 17: one genesis guardian per model | PoC tie-breaks need a guardian per model after proposal 9, [proposal 17](https://node0.gonka-dev.net/chain-api/cosmos/gov/v1/proposals/17) |
| 2026-11-09 | Proposal 18: genesis guardians move to single-node participants | #308 |
| 2026-11-13 | Proposals 19, 20: delegation `v_min` 0 for one epoch, then back to 2 | #322 |
| 2026-11-14 | node9 runs as a Qwen3-4B validator | #323 |
| 2026-11-16 | node10 retired | #324 |
| 2026-11-18 | MLNode image `4.0.0-sigma3` on all nine ML nodes | #329 |
| 2026-11-19 | Proposal 21: register Qwen3-8B and move the 7B target weight share to it; Qwen2.5-7B stays registered | #336 |
