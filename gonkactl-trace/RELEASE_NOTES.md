# gonkactl-trace 1.0.0-beta.1

The first packaged beta of the read-only Gonka investigation CLI.

- Collect bounded on-chain history from mainnet, devnet, testnet or an explicit RPC.
- Inspect consensus membership, voting power, signatures and available application evidence in a standalone HTML report.
- Rebuild reports offline from retained inputs, with provenance and explicit coverage gaps.
- Export native Perfetto traces or OTLP for further investigation.
- Install checksum-verified binaries for Linux and macOS, or download the Windows ZIP.
- Inspect release version, source commit and build date with `--version`.

This beta supports incident triage and inspection of E2E test runs. Collection
is a bounded snapshot, not a continuous observer. Signature fields are not
cryptographically verified; application interpretation remains experimental.
Generated evidence is private by default and must be reviewed before sharing.
The optional full Perfetto viewer is not bundled; HTML reports and native trace
exports work without it.

Archives are reproducible with the same source commit and Go toolchain.
`build.json` records both; `SHA256SUMS` covers all five archives. Checksums detect
corruption, but are not an independent signature of the release publisher.
