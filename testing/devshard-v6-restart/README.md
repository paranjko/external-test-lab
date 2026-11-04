# DevShard v6 host restart test

`host_restart_slots_test.go` checks that a host keeps all its slots of an open escrow after a restart. It runs inside the `gonka-ai/gonka` tree and needs no stand.

```bash
git clone --depth 1 --branch release/devshard/v6.0.0-rc1 https://github.com/gonka-ai/gonka.git
cp testing/devshard-v6-restart/host_restart_slots_test.go gonka/devshard/cmd/devshardd/session/
docker run --rm -v "$PWD/gonka":/src -w /src/devshard -e CGO_ENABLED=0 golang:1.25.9 \
  go test ./cmd/devshardd/session/ -run '^TestHostRestartKeepsAllSlots$' -count=1 -v
```

Expected on `release/devshard/v6.0.0-rc1`: `cold-key-journal-replay` and `warm-key-no-inference-before-restart` pass. The three other `warm-key-*` cases fail: the host keeps slot 8, and slots 9, 13 and 0 answer `not_executor`.

Expected on `release/devshard/v4.2.0`: all five cases pass.
