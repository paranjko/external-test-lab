# Native macOS validation — PR 122

Tested on 2026-09-09 against base `264c79277a7c6e1a7e5c0868b0c8130ee81964b4`
plus the accompanying uncommitted native-operator changes. No remote JOIN,
registration, signer activation or production Host mutation was performed.

| Check | Result and limits |
| --- | --- |
| Real macOS ARM64 launcher `--help` | PASS with Homebrew Bash/GNU dependencies and local Docker/SSH guards |
| Actual macOS Bash 3.2 | PASS: rejected before operational code with exit 2 and dependency guidance |
| Preflight regression | PASS: 9 Python test methods, including Bash boundaries, real platform, simulated Linux/Darwin, missing tools, incompatible flags, child Bash and lock contention/release |
| Mutation checks | PASS: removing required-tool detection or `realpath -m` validation causes its regression test to fail |
| IPv4 resolver | PASS: real loopback, deduplication, stream/IPv4 selection and lookup failure; shared configuration rejects multiple addresses and failed lookup |
| Component selection | PASS with fixtures for Darwin ARM64/AMD64 and Linux; missing Darwin asset refused, Host artifact stays Linux |
| Profile validation | PASS: version, commit, platform and digest binding; canonical profile ID; JSON Schema validates an operator-bearing profile |
| CLI installation boundaries | PASS with fixture binaries: platform mismatch and wrong archive SHA-256 refused |
| Real Darwin ARM64 CLI | PASS: official `0.2.15` archive, tag bound to Core commit, SHA-256 `119db2736fff15286874b987888d08d84d5991d928348f8efd415da959faa5e3`, actual version execution |
| Real keyring operations | PASS: disposable native test-keyring key creation and mnemonic recovery into an isolated file keyring using the production helper |
| Ed25519 | PASS: RFC 8032 known public key derived through OpenSSL during preflight; backup contract also exercises softsign verification |
| Backup/restore contract on Mac | PASS with synthetic test fixtures |
| Mac → Linux → Mac archive round trip | PASS: production archive verifier accepts Mac-created archive in Linux and Linux-repacked archive on Mac; checksum manifest preserved. Uses public synthetic fixture identities and the existing test mnemonic-identity helper, not a live validator backup |
| Focused integration | PASS: component/profile resolution, Host JOIN `--plan` without remote effects, explicit public-host, Genesis config, Host backup context, cleanroom contract |
| ShellCheck | PASS on changed shell code at repository severity (`warning`); source tracing enabled |
| Profile identity across operator platforms | PASS: `profile_id` is computed from the canonical spec with `components.operator_cli` removed, so a Linux operator and a macOS operator produce the same identity for the same Host, observation and release. Retained profiles that predate `operator_cli` keep their existing identity, because deleting an absent key is a no-op. The operator artifact is still bound and verified inside the profile |
| Native `make test` shell and Python suites | PASS: 13 of 13 on macOS ARM64 with the documented PATH and an activated `jsonschema` environment. `test-generate-candidate-binary-sbom.sh` now builds its own stub executable instead of copying `/bin/true`, which does not exist on macOS. The `site-js-check` and `site-host-requirements-check` prerequisites need npm network access and were not part of this run |
| Native broader `runbook-contracts` suite | PARTIAL: `test-host-join-plan.sh` and `test-host-backup-context.sh` fail natively on macOS and pass in CI on Linux. Both compare operator data-home paths literally, while macOS resolves `/var` through a symlink to `/private/var`, so a `mktemp -d` path and its resolved form disagree. This predates the operator changes and is a separate portability scope |
| Linux full `make test` | Pending final run in an isolated Linux ARM64 CI image with zip, unzip and jsonschema |
| Actual Intel Mac | NOT RUN; platform-selection fixtures are not Intel execution |
| Native `host join --plan` against a real Host | PASS on macOS ARM64 against `gdc-node5`: bootstrap validated, seed observation over 5 usable roots, runtime resolved from official artifacts, Join Profile created. The profile binds operator artifact `inferenced-darwin-arm64.zip` (`darwin-arm64`) while the Host artifact stays `inferenced-linux-amd64.zip` (`linux-amd64`) |
| Native live JOIN attempt | Reached remote preflight from macOS, then stopped at `lineage_rpc_quorum_conflict` reading an early checkpoint from `node2.gonka-dev.net`. This is a network-side lineage quorum condition, not an operator-platform failure |
| Completed live-network native JOIN | NOT RUN; follow [controlled manual procedure](NATIVE-MACOS.md#controlled-manual-join) |

`test-native-operator.sh` deliberately tests a fixed published release and
disposable keys; it is not evidence of the live network's selected runtime.
The controlled JOIN must independently verify current observation, lineage,
state acquisition, signer, registration and backup acceptance.

To reproduce focused checks, apply the PATH in `NATIVE-MACOS.md` and run:

```bash
./scripts/test-gdc-preflight.sh
python3 scripts/test-resolve-ipv4.py
./scripts/test-resolve-join-components.sh
./scripts/test-join-profile.sh
./scripts/test-resolve-join-profile.sh
./scripts/test-ensure-inferenced-cli-output.sh
./scripts/test-genesis-role-config.sh
./scripts/test-validator-backup-contract.sh
./scripts/test-native-operator.sh  # opt-in GitHub downloads; no SSH/JOIN
```

For the broader Python suite, install `jsonschema` in a separate virtualenv.
Some existing tests assume Linux filesystem paths; the native operator path
and the portability of the entire developer test suite are separate scopes.
