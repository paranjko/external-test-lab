# gonkactl-test 1.0.0-alpha.1

https://gonka-dev.net/test/

The first packaged alpha of the Gonka component test and evidence CLI.

- Run owned fixtures locally or on a profile-bound test stand.
- Validate environment profiles and composition digests before execution.
- Retain structured test evidence and render Allure reports with history.
- Check rendered reports in Chrome and exercise isolated report storage.
- Install checksum-verified binaries for Linux and macOS, or download the Windows ZIP.
- Inspect the release version with `--version` and source/build metadata with `build-info`.

This alpha includes reviewed DevShard v5 bindings. Unsupported scenarios remain
`not_run`; fixture results are evidence for their declared scope, not a
network-wide readiness claim. Cross-compilation is not native runtime
qualification on every platform.

HTML rendering requires Node.js 24–26 and npm; run `gonkactl-test setup-report`
to install the pinned renderer. Browser checks require Chrome. DevShard release
fixtures additionally require Docker with Compose, Go 1.27, Git, Bash and the
reviewed feature inputs from the source checkout. Windows fixture execution
requires a Linux Docker engine, such as Docker Desktop with WSL2.

`build.json` records the source commit, build time and platform targets.
`checksums.txt` covers all five archives. Checksums detect corruption, but are
not an independent signature of the release publisher.
