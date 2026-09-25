# Runbook command dependencies

`make test` is supported on the GitHub-hosted `ubuntu-latest` runner used by
`runbook-contracts`. Its required executable baseline is
[`dependencies/ci-test-commands.txt`](dependencies/ci-test-commands.txt).
`scripts/test-command-dependency-contract.sh` verifies that baseline before
the rest of the contract suite.

[`dependencies/optional-commands.txt`](dependencies/optional-commands.txt)
lists tools detected at runtime. They are not prerequisites of `make test`.
Each optional use must have a supported fallback or a clear fail-closed
operator diagnostic.

`rg` is deliberately not a runbook dependency. Shell code must use `grep`
when the portable baseline is sufficient.

`flock` is required by the preview lifecycle controller and is declared in the
CI command baseline.

Before adding an external executable to runbook shell code:

1. Check both manifests and the `runbook-contracts` workflow job.
2. Prefer an existing required command or a Bash builtin.
3. If a new tool is indispensable, declare it in the appropriate manifest,
   provision it in every CI path that executes it, and add a contract test.
4. If it cannot be provisioned consistently, change the implementation rather
   than adding an undeclared dependency.
