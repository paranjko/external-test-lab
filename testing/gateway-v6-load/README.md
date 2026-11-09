# Gateway v6 local load

`kovec/gateway:v6` and the v6.0.0-rc1 gateway under the same local load, on devshard v6.0.0 hosts. Harness: `devshard/testenv/loadtest` of gonka-ai/gonka#2232 at `751080d9718bd03ce2998c57e8096c9c51f719fe`. The chain and the ML nodes are mocked; escrow rotation is off.

| File | What |
|---|---|
| `build-kovec-v6.yaml` | devshard v6.0.0 hosts with `kovec/gateway:v6` |
| `build-rc1.yaml` | the same hosts with the v6.0.0-rc1 gateway |
| `kovec-smoke.yaml`, `rc1-smoke.yaml` | 2 rps for 30 s |
| `kovec-poc.yaml`, `rc1-poc.yaml` | 8 rps for 8 min, one PoC and one cPoC window |
| `kovec-poc-preserved-load.yaml`, `rc1-poc-preserved-load.yaml` | 32 rps for 16 min, two PoC windows |

Each scenario differs from its source in #2232 only in the name and the `gateway` block.

## Run

Linux with Docker and Go 1.25, nothing heavy beside it.

```bash
L=$PWD/testing/gateway-v6-load
gh release download devshard/v6.0.0 -R gonka-ai/gonka -p devshardd.zip -D "$L"
sha256sum "$L/devshardd.zip"   # 531eb433392a56d009c14c63a74070cac410110f4c761437614af1a4360722e2
unzip -j -o "$L/devshardd.zip" -d "$L/bin" && test -x "$L/bin/devshardd"
for f in "$L"/build-*.yaml; do grep -oE '[a-z0-9./-]+:[a-z0-9.-]+@sha256:[0-9a-f]{64}' "$f"; done | sort -u | xargs -n1 docker pull
git clone https://github.com/gonka-ai/gonka.git && git -C gonka checkout 751080d9718bd03ce2998c57e8096c9c51f719fe
cd gonka/devshard/testenv
printf 'hosts:\n  - id: versiond-0\n  - id: versiond-1\n  - id: versiond-2\nescrows:\n  - id: 1\n    model_id: test-model\nmock_openai:\n  http_port: 18088\n' > config/config.yaml
go run ./cmd/loadtest -scenario "$L/kovec-smoke.yaml" -build "$L/build-kovec-v6.yaml" -output "$L/results/kovec-smoke"
```

For rc1, use `rc1-*.yaml` with `build-rc1.yaml`. Each run writes `report.md` to its output directory.

`config/config.yaml` keeps the harness defaults and moves the mock ML nodes from 8088 to 18088–18092: cAdvisor holds 8088 on the load host.
