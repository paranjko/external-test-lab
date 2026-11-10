# gonkactl-test 1.0.0-alpha.1

Run and verify Gonka fixtures, validate environment profiles and composition
digests, and produce test evidence and Allure reports. This alpha has reviewed
DevShard v5 bindings; unsupported scenarios remain `not_run`.

Install from https://gonka-dev.net/test or unpack the archive for your platform.
`gonkactl-test --version` prints `1.0.0-alpha.1`; `build-info` prints source and
build metadata. Linux and macOS archives contain `gonkactl-test`; Windows
contains `gonkactl-test.exe` (the shell installer runs in Git Bash/MSYS).

```sh
gonkactl-test --help
gonkactl-test setup-report
gonkactl-test run --help
gonkactl-test release --help
```

The CLI binary needs no Go installation for help, profile validation or report
processing. Rendering requires Node.js 24–26 and npm: `setup-report` installs
the bundled dependency lock in the user's cache. Browser checks also require
Chrome. Executing DevShard release fixtures requires Docker with Compose, Go
1.27, Git, Bash and the reviewed `feature/` inputs from the source checkout.
On Windows, use a Linux Docker engine (for example Docker Desktop with WSL2).
Cross-compilation alone does not establish that every external fixture works
on every platform.

Release tags are tool-scoped: `gonkactl-test-v1.0.0-alpha.1`. Verify downloads
against `checksums.txt` from the same release before unpacking. Checksums detect
corruption; they do not replace trust in the GitHub release publisher and HTTPS.

## Release maintenance

Build dependencies: Go 1.27, Python 3.11+ (standard library), Git and Make.
Tests additionally use Node.js 24, npm, POSIX sh, curl/wget, tar/unzip and a
SHA-256 utility; the clean-container smoke uses Docker.

```sh
make -C gonkactl-test release-build
make -C gonkactl-test release-verify
```

Builds use CGO_ENABLED=0 and inject version, source commit and commit time.
The five archives have normalized metadata and a SHA-256 manifest. Use an
empty output directory for each candidate (`RELEASE_OUTPUT=/absolute/path`).
The workflow publishes only from an existing tag that matches the tested
source. It creates a draft with the checked-in release notes and marks it public
only after all assets have uploaded. An existing release is never overwritten.
