.PHONY: test-contracts test-bindings test-stand test-report test-storage check

DATA_ROOT := $(abspath ../build/gonkactl-test)

test-contracts:
	mkdir -p $(DATA_ROOT)/go-cache $(DATA_ROOT)/go-mod-cache $(DATA_ROOT)/go-tmp $(DATA_ROOT)/tmp
	env GOCACHE=$(DATA_ROOT)/go-cache GOMODCACHE=$(DATA_ROOT)/go-mod-cache GOTMPDIR=$(DATA_ROOT)/go-tmp TMPDIR=$(DATA_ROOT)/tmp TMP=$(DATA_ROOT)/tmp TEMP=$(DATA_ROOT)/tmp go test ./contracts

test-bindings:
	mkdir -p $(DATA_ROOT)/go-cache $(DATA_ROOT)/go-mod-cache $(DATA_ROOT)/go-tmp $(DATA_ROOT)/tmp $(DATA_ROOT)/npm-cache $(DATA_ROOT)/xdg-cache $(DATA_ROOT)/browser-cache
	env GONKACTL_TEST_DATA_ROOT=$(DATA_ROOT) GOCACHE=$(DATA_ROOT)/go-cache GOMODCACHE=$(DATA_ROOT)/go-mod-cache GOTMPDIR=$(DATA_ROOT)/go-tmp TMPDIR=$(DATA_ROOT)/tmp TMP=$(DATA_ROOT)/tmp TEMP=$(DATA_ROOT)/tmp NPM_CONFIG_CACHE=$(DATA_ROOT)/npm-cache XDG_CACHE_HOME=$(DATA_ROOT)/xdg-cache PLAYWRIGHT_BROWSERS_PATH=$(DATA_ROOT)/browser-cache go test -race -count=1 ./bindings

test-stand:
	mkdir -p $(DATA_ROOT)/go-cache $(DATA_ROOT)/go-mod-cache $(DATA_ROOT)/go-tmp $(DATA_ROOT)/tmp
	env GOCACHE=$(DATA_ROOT)/go-cache GOMODCACHE=$(DATA_ROOT)/go-mod-cache GOTMPDIR=$(DATA_ROOT)/go-tmp TMPDIR=$(DATA_ROOT)/tmp TMP=$(DATA_ROOT)/tmp TEMP=$(DATA_ROOT)/tmp go test ./stand

test-report:
	mkdir -p $(DATA_ROOT)/go-cache $(DATA_ROOT)/go-mod-cache $(DATA_ROOT)/go-tmp $(DATA_ROOT)/tmp $(DATA_ROOT)/history/m0-v2/receipts
	env GOCACHE=$(DATA_ROOT)/go-cache GOMODCACHE=$(DATA_ROOT)/go-mod-cache GOTMPDIR=$(DATA_ROOT)/go-tmp TMPDIR=$(DATA_ROOT)/tmp TMP=$(DATA_ROOT)/tmp TEMP=$(DATA_ROOT)/tmp go test ./report
	cd report && npm ci --ignore-scripts --offline
	if test ! -f $(DATA_ROOT)/history/m0-v2/receipts/m0-run-1; then env GOCACHE=$(DATA_ROOT)/go-cache GOMODCACHE=$(DATA_ROOT)/go-mod-cache GOTMPDIR=$(DATA_ROOT)/go-tmp TMPDIR=$(DATA_ROOT)/tmp TMP=$(DATA_ROOT)/tmp TEMP=$(DATA_ROOT)/tmp GONKACTL_TEST_RUN_ID=m0-run-1 go run ./cmd/m0report && cd report && GONKACTL_TEST_REPORT_OUTPUT=$(DATA_ROOT)/report/render/run-1 GONKACTL_TEST_HISTORY_PATH=$(DATA_ROOT)/history/m0-v2/history.jsonl GONKACTL_TEST_APPEND_HISTORY=true ./node_modules/.bin/allure generate --config allurerc.mjs $(DATA_ROOT)/report/results/m0-run-1 && touch $(DATA_ROOT)/history/m0-v2/receipts/m0-run-1; fi
	if test ! -f $(DATA_ROOT)/history/m0-v2/receipts/m0-run-2; then env GOCACHE=$(DATA_ROOT)/go-cache GOMODCACHE=$(DATA_ROOT)/go-mod-cache GOTMPDIR=$(DATA_ROOT)/go-tmp TMPDIR=$(DATA_ROOT)/tmp TMP=$(DATA_ROOT)/tmp TEMP=$(DATA_ROOT)/tmp GONKACTL_TEST_RUN_ID=m0-run-2 go run ./cmd/m0report && cd report && GONKACTL_TEST_REPORT_OUTPUT=$(DATA_ROOT)/report/render/run-2 GONKACTL_TEST_HISTORY_PATH=$(DATA_ROOT)/history/m0-v2/history.jsonl GONKACTL_TEST_APPEND_HISTORY=true ./node_modules/.bin/allure generate --config allurerc.mjs $(DATA_ROOT)/report/results/m0-run-2 && touch $(DATA_ROOT)/history/m0-v2/receipts/m0-run-2; fi
	cd report && GONKACTL_TEST_REPORT_OUTPUT=$(DATA_ROOT)/report/render/rerender-run-2 GONKACTL_TEST_HISTORY_PATH=$(DATA_ROOT)/history/m0-v2/history.jsonl GONKACTL_TEST_APPEND_HISTORY=false ./node_modules/.bin/allure generate --config allurerc.mjs $(DATA_ROOT)/report/results/m0-run-2
	test "$$(wc -l < $(DATA_ROOT)/history/m0-v2/history.jsonl)" -eq 2
	bash report/browser-smoke.sh $(DATA_ROOT)

test-storage:
	mkdir -p $(DATA_ROOT)/go-cache $(DATA_ROOT)/go-mod-cache $(DATA_ROOT)/go-tmp $(DATA_ROOT)/tmp $(DATA_ROOT)/storage-prefix
	env GOCACHE=$(DATA_ROOT)/go-cache GOMODCACHE=$(DATA_ROOT)/go-mod-cache GOTMPDIR=$(DATA_ROOT)/go-tmp TMPDIR=$(DATA_ROOT)/tmp TMP=$(DATA_ROOT)/tmp TEMP=$(DATA_ROOT)/tmp GONKACTL_TEST_STORAGE_INTEGRATION=1 GONKACTL_TEST_STORAGE_DATA_ROOT=$(DATA_ROOT)/storage-prefix go test ./report -run '^TestStoragePrefixIntegration$$' -count=1 -v

check: test-contracts test-bindings test-stand test-report
