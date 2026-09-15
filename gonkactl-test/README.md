# Run the DevShard v5 release tests

1. Open a terminal in the External Test Lab checkout root – the directory
   that contains `feature/` and `gonkactl-test/`. Check that you are there:

   ```sh
   ls feature/*.feature
   ```

2. Install the runner. Ensure `~/.local/bin` is on your `PATH`:

   ```sh
   make -C gonkactl-test install
   export PATH="$HOME/.local/bin:$PATH"
   gonkactl-test --help
   ```

3. Pin the official release archive:

   ```sh
   export RELEASE_TAG=devshard/v5.0.0
   export RELEASE_SHA256=ae2d1f90374b54efd4290b4df8b8c0ae339deb0d3b6e5b10936ea9f73155f564
   ```

4. Start Docker, then run the scenarios:

   ```sh
   docker info >/dev/null
   gonkactl-test release
   ```

   The command reads `./feature` and writes a unique run under
   `./build/report` by default. It downloads and verifies the release archive,
   checks out the matching release source, runs the supported scenarios with
   the pinned executable in owned local Docker fixtures, and cleans up those
   fixtures. It prints the exact `Report:` and `Results:` paths even when a
   run is incomplete.

5. Open the exact `index.html` path printed after `Report:`. The adjacent
   `report.json` contains the archive and executable hashes, each scenario's
   status, retained test logs, and the cleanup receipt. A nonzero command exit
   means the run did not establish complete scenario coverage – inspect the
   report. `upstream_pass` is scoped test evidence, not a Gherkin-step or full
   acceptance verdict. In this revision, six scenarios have executable
   bindings and fourteen remain `not_run`, so the overall command exits
   nonzero even when all six supported checks pass.

To use a different input directory or result root, set `FEATURES` and
`DATA_ROOT`, or pass `--features` and `--data-root`. Both are optional. For an
offline run with already downloaded inputs, add `--archive PATH` and
`--source PATH` to the `gonkactl-test release` command; the archive hash and
source commit are still verified.

For development and implementation checks, see [DEVELOP.md](DEVELOP.md).
