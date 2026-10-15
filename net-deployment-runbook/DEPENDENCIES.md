# Runbook command dependencies

`make test` is supported on the GitHub-hosted `ubuntu-latest` runner used by
`runbook-checks`. Its required executable baseline is
[`dependencies/ci-test-commands.txt`](dependencies/ci-test-commands.txt).
`scripts/test-command-dependency-contract.sh` verifies that baseline before
the rest of the contract suite.

CI selects checks from the changed paths on both pull requests and pushes.
Release-only changes run release checks; static site changes run bootstrap,
core and site groups plus edge integration, because those tests also consume
site assets. Documentation retains its test coverage but skips ShellCheck and
Host upgrade containers. Unrelated paths do not expand a narrow route. Shared
or unknown runbook inputs run the full suite; manual dispatch always runs it.
Renames include both paths. Missing push history falls back to the full suite;
a failed PR file lookup fails the required gate. The routing step summarizes
the selected jobs and groups. Draft PRs use the same selection as ready PRs.

CI runs `test-ci-bootstrap`, `test-ci-core`, `test-ci-site`,
`test-ci-join` and `test-ci-gateways` in independent checkouts, plus `test-host-lifecycle`
and a separate Host upgrade job. Tests within each group remain sequential: some fixtures use fixed
loopback ports or write generated site files. Do not run groups concurrently
in the same checkout. `make test` still runs the complete original local
suite, including the shared Host tests, and `make test test-host-lifecycle` adds the
remaining Host checks without rerunning shared targets.

The `host-lifecycle` job checks JOIN, stop/start, ML lending/reclaim and safe refusal of retired deployment and identity layouts without changing ML record schema compatibility

`make test-ci-layout` checks that the CI groups cover the local suite and do
not duplicate test entrypoints (apart from each group's dependency check).
ShellCheck runs once across two CI shards, retaining the pinned version and
external-source analysis. `make shellcheck` checks every script locally;
`make shellcheck shellcheck_shard=0 shellcheck_shards=2` reproduces one shard.
The `runbook-checks` result requires all test, lint, ownership, upstream
and edge jobs selected by routing to succeed; failed, cancelled, missing or
unexpectedly skipped required jobs fail the gate. A failed routing job cannot
produce a successful aggregate.

Ordinary tests and the site do not require Gonka sources. Release auditing is
separate: `make verify-upstream-profiles upstream_source=/path/to/gonka`
requires a checkout with release tags. CI runs it in the `upstream-profiles`
job. Gateway source builds fetch their own cache under `.data/upstream/gonka`
only when needed.

[`dependencies/optional-commands.txt`](dependencies/optional-commands.txt)
lists tools detected at runtime. They are not prerequisites of `make test`.
Each optional use must have a supported fallback or a clear fail-closed
operator diagnostic.

`rg` is deliberately not a runbook dependency. Shell code must use `grep`
when the portable baseline is sufficient.

`host upgrade` and its tests are Bash-based. The operator path uses the existing
curl/jq bootstrap validator and SSH; the Host needs Bash, jq, GNU coreutils,
Docker and Compose, but no Python. `test-host-upgrade` mocks every SSH and curl
call and rejects unexpected destinations. `test-host-upgrade-lifecycle` uses a
fresh privileged Docker-in-Docker container with no host socket, keys or data
mounts; it pulls digest-pinned BusyBox and Alpine fixtures from Docker Hub and
tests actual container replacement and rollback only in `/srv/dai/deploy`.
`host upgrade` rejects every other deployment directory before acquiring a
lock, writing receipts, pulling an image or changing containers. Legacy
`/srv/dai/node` and nested deployment directories are not supported or migrated.
CI and local tests run the same single lifecycle scenario, with rejection
checks for unsupported paths rather than upgrade scenarios for those layouts.
The synthetic sleep services use a one-second stop grace period, avoiding
Docker's default ten-second waits without changing production shutdown policy.

The standalone `install_inferenced.sh` requires `curl`, `unzip`, `awk`, `jq`,
and either `sha256sum` or `shasum`. `jq` validates the selected official
release and its asset digest; it is already in the CI baseline. DevNet callers
pass their profile version explicitly, while generic no-argument installation
retains newest-published-release selection. See
[`inferenced-installer.md`](../broker-ops/inferenced-installer.md).

`flock` is required by the preview lifecycle controller and is declared in the
CI command baseline.

Bootstrap publication uses Python 3 with `jsonschema==4.23.0`, OpenSSH, and
`rsync` on the GitHub-hosted Ubuntu runner. The named
`bootstrap-publication-dependencies` target installs the validator and checks
the transport tools. The destination requires Python 3 (standard library only)
and rsync. One-time root setup additionally uses the existing Docker Compose
installation and the system's `getent` and `runuser`; delivery never uses sudo
on the destination server.
The publication tests replace SSH and rsync with local fixtures.
The bootstrap monitor uses the public gonkactl installer and the installed
Go CLI, not Python/jsonschema. Its Ubuntu composite Action uses the existing
Bash, Make, curl, jq, tar and SHA-256 command baseline for installation and
GitHub/Telegram transport. Native Go tests cover validation; Action transport
tests mock external writes and are part of `make -C gonkactl check`.
The separate `test-bootstrap-publisher-ownership` target requires Linux root
and the standard `nobody` account. GitHub-hosted CI invokes it with sudo; local
checks can run in a disposable root container. It uses only Python's standard
library, temporary directories, and a child process with a different UID/GID;
it never writes to `/srv` or connects to a server.

`make test-tmkms-recovery-boundary` builds an isolated test image from the pinned
TMKMS image. Its extra packages are declared in
[`scripts/tmkms-boundary-packages.txt`](scripts/tmkms-boundary-packages.txt).
They provide JSON assertions and the Unix-socket protocol transport; they are
not operator or Host dependencies. The build checks that the TMKMS executable
is unchanged, and the test runs without network access or Host mounts.

Python contract dependencies are pinned in
[`dependencies/python-test-requirements.txt`](dependencies/python-test-requirements.txt).
The CI workflow provisions them through the named
`install-python-test-dependencies` Make target before `make test`; local
operators run the same target when their Python environment lacks a declared
module.

DevShard [archive builds](releases/README.md) require Python 3.11+, Docker
Buildx, Go, binutils, `od` and `zipinfo`; publication also needs `gh`.
`devshard-release.yml` installs Go/binutils and uses Ubuntu's unzip/GNU tools.
`make test-devshard-release` mocks external commands; it neither builds nor
publishes artifacts.

The v6 OCI bundle contract tests also run with Python's standard library and
mock all external operations. Actual image builds need Git, GNU tar, Docker
Buildx with the `docker-container` driver, and public HTTPS access to the
frozen Gonka commit and ZIP; they use an empty Docker config and never receive
the publication token. The separate trusted publisher needs `gh`, `skopeo`,
and contents-write/packages-write permissions. `skopeo` is declared in
`dependencies/optional-commands.txt` and provisioned only in the publication
job. It verifies existing archives and publishes their OCI bytes to GHCR
without executing candidate source.

Before adding an external executable to runbook shell code:

1. Check both manifests and the `runbook-checks` workflow job.
2. Prefer an existing required command or a Bash builtin.
3. If a new tool is indispensable, declare it in the appropriate manifest,
   provision it in every CI path that executes it, and add a contract test.
4. If it cannot be provisioned consistently, change the implementation rather
   than adding an undeclared dependency.
