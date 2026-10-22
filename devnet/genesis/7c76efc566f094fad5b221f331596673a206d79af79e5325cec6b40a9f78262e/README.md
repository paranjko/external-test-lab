# Gonka Community DevNet Genesis

This directory contains the Genesis document for the new Community DevNet
history. It deliberately retains the network chain ID
`gonka-devnet-community`; operators should distinguish this history by the
Genesis hash, not by expecting a new chain ID. The configured Genesis time is
`2026-10-20T12:06:15Z`.

The Genesis document declares application version `0.2.16`. The associated
runtime profile targets Core and decentralized API `0.2.16-post1`, TMKMS
`0.2.15`, and MLNode `3.0.16`.

The configured inference models are:

- `Qwen/Qwen2.5-7B-Instruct`
- `Qwen/Qwen3-4B-Instruct-2507`
- `Qwen/Qwen3-0.6B`

The Genesis also carries approved DevShard releases `v4.1`, `v4.2`, and `v6`.

Key starting parameters:

- Epoch length: 1,500 blocks; epoch shift: 200 blocks.
- Initial model: `Qwen/Qwen2.5-7B-Instruct`; delegation `v_min`: 2.
- Expected confirmation PoCs per epoch: 1.
- DevShard requests enabled; auto-seal interval: 0 (runtime default).
- Inference seal grace: 160 nonces and 3,600 seconds.
- Governance voting period: 120 seconds; minimum deposit: 25,000,000 `ngonka`.

This is the immutable starting configuration, not a live parameter snapshot.
It starts with one genesis guardian; later governance changes and model-group
activation are not reflected in this file. Listing a model in Genesis does
not establish that its group is active or serving inference.

`genesis.sha256` verifies the exact bytes of `genesis.json`. The raw file SHA-256
is `7c76efc566f094fad5b221f331596673a206d79af79e5325cec6b40a9f78262e`. The
canonical chain Genesis SHA-256, accounting for normal CometBFT RPC
serialization, is `ebf3d1b022c54ccedc81b1d1215b0acbcf4916677ab69825b6e1eb91ee3ebd9b`.

The pinned `inferenced download-genesis` command emits an equivalent RPC
serialization with raw SHA-256
`30a1bb1732543d54ba418ed50e5bd47bd36c2e162fa44217c323c53eb8399bb2`.
Bootstrap's `genesis.sha256` uses this download hash. It must not use the
artifact hash or canonical identity in place of the expected download bytes.
