# Development

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
