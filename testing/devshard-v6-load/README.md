# DevShard v6 load scenarios

Scenarios for the load harness of `gonka-ai/gonka` (`devshard/testenv/loadtest`, gonka-ai/gonka#1989). Each file asks one question.

| Scenario | Question |
|---|---|
| `ladder-high.yaml` | Where does the gateway break between 32 and 100 rps? |
| `ladder-high-n20k.yaml` | The same with the DevNet `max_nonce` of 20,000 |
| `ladder-high-w400.yaml` | The same with mock model servers of 400 workers; run with `-profiles-dir <this directory>/profiles` |
| `ladder-200.yaml` | Where does the gateway itself degrade up to 200 rps? Mock model servers of 800 workers; run with `-profiles-dir <this directory>/profiles` |
| `soak-60m.yaml` | Do memory, goroutines and rotation errors grow over one hour? |
| `group-16.yaml` | Does a group of 16 participants hold 24 rps? |
| `storm.yaml` | Does the end state stay correct after several faults at a peak? |
| `host-flapping.yaml` | Does a host that pauses every minute get back to work? |
| `long-pause.yaml` | Does a host catch up after a 25-minute pause? |
| `slow-hosts.yaml` | Do slow but alive hosts get penalized? |
| `slow-host-1.yaml` | Does one slow host recover once its CPU limit is lifted? |
| `slow-host-1-pool16.yaml`, `slow-hosts-pool16.yaml` | The same with 16 Postgres connections per host instead of 4 |
| `remote-512.yaml` | `remote-long-load` of gonka-ai/gonka#2009 for a live gateway, with 512 output tokens (DevNet models have a 4096-token context); run with `cmd/remote-loadtest` |
| `remote-ladder.sh` | Where does a live gateway degrade? One `cmd/remote-loadtest` run per step of workers (`TOOL=wrap-load`: `cmd/wrap-load` of `ilyar/gonka-devshard-contrib`, unique requests past the response cache), stop at errors above 2 %, p95 doubled or throughput flat; `remote-ladder-table.py` makes the table |
| `remote-node-sampler.sh`, `remote-preflight.sh` | Read-only: host CPU, memory and GPU and gateway containers during a run; idle check, versions and escrow before and after |
| `cap-dataset.py` | Fits a captured request dataset to a 4096-token context: drops long prompts, caps `max_tokens` |
| `faults-host-prod.yaml` | `faults-host` without its two trip-file faults, for a release build of devshardd |
| `fetch-compat-build.sh` | Builds for `load-ladder` on the official 0.2.16 host stack: `build-baseline.yaml` (v4.2 gateway, v4.2 hosts: mainnet today), `build-coexist.yaml` (v6 rc1 gateway, hosts run v6 next to v4.2: mainnet once v6 is approved) |

Run from `devshard/testenv` of a `gonka-ai/gonka` checkout that has the harness:

```bash
go run ./cmd/loadtest -scenario <path to this directory>/<name>.yaml -profiles-dir loadtest/profiles -output <dir>
```

To run a prebuilt build instead of building from the checkout (needs the `-build` option of the harness):

```bash
./fetch-build.sh lab-gonka-pr-1792-67230e4dcc0a /path/to/empty/dir
go run ./cmd/loadtest -build /path/to/empty/dir/build.yaml -scenario <path to this directory>/<name>.yaml -profiles-dir loadtest/profiles -output <dir>
```
