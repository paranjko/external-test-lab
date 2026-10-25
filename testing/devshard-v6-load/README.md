# DevShard v6 load scenarios

Scenarios for the load harness of `gonka-ai/gonka` (`devshard/testenv/loadtest`, gonka-ai/gonka#1989). Each file asks one question.

| Scenario | Question |
|---|---|
| `remote-512.yaml` | `remote-long-load` of gonka-ai/gonka#2009 for a live gateway, with 512 output tokens (DevNet models have a 4096-token context); run with `cmd/remote-loadtest` |
| `remote-ladder.sh` | Where does a live gateway degrade? One `cmd/remote-loadtest` run per step of workers (`TOOL=wrap-load`: `cmd/wrap-load` of `ilyar/gonka-devshard-contrib`, unique requests past the response cache), stop at errors above 2 %, p95 doubled or throughput flat; `remote-ladder-table.py` makes the table |
| `remote-soak.sh` | Does a live gateway hold a steady load for an hour? `cmd/wrap-load` between PoC windows; a PoC or cPoC stops the run, which starts again after it; `remote-ladder-table.py --windows 300` makes the table |
| `remote-node-sampler.sh`, `remote-preflight.sh` | Read-only: host CPU, memory and GPU and gateway containers during a run; idle check, versions and escrow before and after |
| `cap-dataset.py` | Fits a captured request dataset to a 4096-token context: drops long prompts, caps `max_tokens` |
