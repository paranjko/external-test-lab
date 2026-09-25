# Development

## Runner image

Build the Docker-in-Docker runner from the repository root using the named
local target:

```sh
make -C gonkactl-test docker-image DOCKER_IMAGE=gonkactl-test:local
```

The multi-stage image compiles the CLI with Go 1.27, installs the pinned
Allure v3 renderer, then adds Docker daemon and CLI support, Git, and Bash.
Runtime workdir is `/workspace`; mount the repository's `feature/` read-only
and `build/` read-write directories there. The container requires
`--privileged` so its internal daemon can create release fixture containers.
The entrypoint waits for the daemon and terminates it after the CLI exits. Keep
changes focused on this contract: do not push or publish the image. Source-image
checks are Dockerfile syntax/build, entrypoint shell syntax, and a bounded
container CLI probe; release fixtures and broad CI suites are outside this
development check.

Run the bundled Gherkin scenarios from `testdata/feature`:

```sh
make test-report
```

The command executes `pilot.feature` and the expected-failure
`failure.feature`, renders the Allure report, and writes receipts under
`../build/gonkactl-test/`.

Run the complete local quality gate, including browser and Storage checks:

```sh
make qa
```
