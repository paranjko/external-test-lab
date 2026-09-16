# Run the DevShard v5 release tests

## Docker workflow

From the repository root (containing `feature/` and `gonkactl-test/`):

```sh
make -C gonkactl-test docker-image
mkdir -p build
export RELEASE_TAG=devshard/v5.0.0
export RELEASE_SHA256=ae2d1f90374b54efd4290b4df8b8c0ae339deb0d3b6e5b10936ea9f73155f564
docker run --rm --privileged \
  --mount "type=bind,src=$PWD/feature,dst=/workspace/feature,readonly" \
  --mount "type=bind,src=$PWD/build,dst=/workspace/build" \
  --env RELEASE_TAG --env RELEASE_SHA256 \
  gonkactl-test:local
```

`--privileged` is required for the image's internal Docker daemon. The default
command is `gonkactl-test release`, reading `./feature` and writing
`./build/report`. Each unique `release-v5-*` directory contains
`allure-results/`, the generated Allure Report v3 at
`allure-report/awesomeBDD/index.html`, `report.json`, and retained logs. The
`Allure Report:` path printed by the command is inside the container: replace
`/workspace/` with the checkout directory on the host. For example, open the
newest report:

```sh
xdg-open "$(find build/report -path '*/allure-report/awesomeBDD/index.html' -print | sort | tail -n 1)"
```

The feature mount is read-only; only `build/` is changed. The command verifies
the release archive, checks out the matching source, runs the supported
scenarios in owned Docker fixtures, and cleans up those fixtures. A nonzero
exit means the report contains incomplete coverage or a failed scenario; it
still leaves its evidence and Allure report on the host. `upstream_pass` is
scoped selector evidence, not Gherkin-step or full acceptance evidence. Six
scenarios currently have executable bindings and fourteen are visibly
`not_run`, so the complete command returns nonzero even when all six supported
selectors pass.

To pass CLI options, put the complete command after the image name. For
example, use a different feature directory or output directory:

```sh
docker run --rm --privileged \
  --mount "type=bind,src=$PWD/feature,dst=/workspace/feature,readonly" \
  --mount "type=bind,src=$PWD/build,dst=/workspace/build" \
  --env RELEASE_TAG --env RELEASE_SHA256 \
  gonkactl-test:local gonkactl-test release \
  --features /workspace/feature --data-root /workspace/build/report
```

For offline use, append `--archive PATH --source PATH`; both inputs remain
verified. The image does not publish images or reports.

For development and implementation checks, see [DEVELOP.md](DEVELOP.md).
