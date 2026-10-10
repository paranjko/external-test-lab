# Runbook command dependencies

`make test` is supported on the GitHub-hosted `ubuntu-latest` runner used by
`runbook-contracts`. Its required executable baseline is
[`dependencies/ci-test-commands.txt`](dependencies/ci-test-commands.txt).
`scripts/test-command-dependency-contract.sh` verifies that baseline before
the rest of the contract suite.

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

Before adding an external executable to runbook shell code:

1. Check both manifests and the `runbook-contracts` workflow job.
2. Prefer an existing required command or a Bash builtin.
3. If a new tool is indispensable, declare it in the appropriate manifest,
   provision it in every CI path that executes it, and add a contract test.
4. If it cannot be provisioned consistently, change the implementation rather
   than adding an undeclared dependency.
