# DevShard v6 load scenarios

Scenarios for the load harness of `gonka-ai/gonka` (`devshard/testenv/loadtest`, gonka-ai/gonka#1989). Each file asks one question.

| Scenario | Question |
|---|---|
| `remote-512.yaml` | `remote-long-load` of gonka-ai/gonka#2009 for a live gateway, with 512 output tokens (DevNet models have a 4096-token context); run with `cmd/remote-loadtest` |
