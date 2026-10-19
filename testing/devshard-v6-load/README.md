# DevShard v6 load scenarios

Scenarios for the load harness of `gonka-ai/gonka` (`devshard/testenv/loadtest`, gonka-ai/gonka#1989). Each file asks one question.

| Scenario | Question |
|---|---|
| `ladder-high.yaml` | Where does the gateway break between 32 and 100 rps? |
| `ladder-high-n20k.yaml` | The same with the DevNet `max_nonce` of 20,000 |
| `ladder-high-w400.yaml` | The same with mock model servers of 400 workers; run with `-profiles-dir <this directory>/profiles` |
| `soak-60m.yaml` | Do memory, goroutines and rotation errors grow over one hour? |
| `group-16.yaml` | Does a group of 16 participants hold 24 rps? |
| `storm.yaml` | Does the end state stay correct after several faults at a peak? |
| `host-flapping.yaml` | Does a host that pauses every minute get back to work? |
| `long-pause.yaml` | Does a host catch up after a 25-minute pause? |
| `slow-hosts.yaml` | Do slow but alive hosts get penalized? |
| `slow-host-1.yaml` | Does one slow host recover once its CPU limit is lifted? |

Run from `devshard/testenv` of a `gonka-ai/gonka` checkout that has the harness:

```bash
go run ./cmd/loadtest -scenario <path to this directory>/<name>.yaml -profiles-dir loadtest/profiles -output <dir>
```
