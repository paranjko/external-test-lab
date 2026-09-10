.PHONY: test-contracts test-bindings test-stand test-report test-storage check

DATA_ROOT := $(abspath ../build/gonkactl-test)
PERSISTENT_DIRS := $(DATA_ROOT)/go-cache $(DATA_ROOT)/go-mod-cache $(DATA_ROOT)/go-tmp $(DATA_ROOT)/tmp $(DATA_ROOT)/npm-cache $(DATA_ROOT)/xdg-cache $(DATA_ROOT)/xdg-config $(DATA_ROOT)/browser-cache $(DATA_ROOT)/child-home
PERSISTENT_ENV := GOCACHE=$(DATA_ROOT)/go-cache GOMODCACHE=$(DATA_ROOT)/go-mod-cache GOTMPDIR=$(DATA_ROOT)/go-tmp TMPDIR=$(DATA_ROOT)/tmp TMP=$(DATA_ROOT)/tmp TEMP=$(DATA_ROOT)/tmp NPM_CONFIG_CACHE=$(DATA_ROOT)/npm-cache XDG_CACHE_HOME=$(DATA_ROOT)/xdg-cache XDG_CONFIG_HOME=$(DATA_ROOT)/xdg-config PLAYWRIGHT_BROWSERS_PATH=$(DATA_ROOT)/browser-cache HOME=$(DATA_ROOT)/child-home JAVA_TOOL_OPTIONS=-Djava.io.tmpdir=$(DATA_ROOT)/tmp

test-contracts:
	mkdir -p $(PERSISTENT_DIRS)
	env $(PERSISTENT_ENV) go test ./contracts

test-bindings:
	mkdir -p $(PERSISTENT_DIRS) $(DATA_ROOT)/terminal-receipts
	@set +e; command='env $(PERSISTENT_ENV) GONKACTL_TEST_DATA_ROOT=$(DATA_ROOT) go test -race -count=1 ./bindings'; log='$(DATA_ROOT)/terminal-receipts/test-bindings.log'; receipt='$(DATA_ROOT)/terminal-receipts/test-bindings.receipt'; manifest='$(DATA_ROOT)/terminal-receipts/test-bindings-upstream.manifest'; env $(PERSISTENT_ENV) GONKACTL_TEST_DATA_ROOT=$(DATA_ROOT) go test -race -count=1 ./bindings >"$$log" 2>&1; status=$$?; cat "$$log"; { printf 'target=test-bindings\ncommand=%s\nexit_code=%s\nhead=%s\ntree=%s\nlog=%s\nupstream_manifest=%s\n' "$$command" "$$status" "$$(git rev-parse HEAD)" "$$(git rev-parse 'HEAD^{tree}')" "$$log" "$$manifest"; } >"$$receipt"; { for f in $(DATA_ROOT)/process-receipts/*.json; do test -f "$$f" || continue; exit_code=$$(sed -n 's/^[[:space:]]*"exit_code": \(-\{0,1\}[0-9][0-9]*\).*/\1/p' "$$f"); interrupted=$$(sed -n 's/^[[:space:]]*"interrupted": \(true\|false\).*/\1/p' "$$f"); if test "$$interrupted" = true; then outcome=interruption; elif test "$$exit_code" = 0; then outcome=pass; else outcome=fail; fi; printf '%s outcome=%s exit_code=%s interrupted=%s\n' "$$f" "$$outcome" "$$exit_code" "$$interrupted"; done; for f in $(DATA_ROOT)/actual-child-env/child-environment-receipts/*.json $(DATA_ROOT)/runtime-path-receipts/*.json $(DATA_ROOT)/runner-archive/*/validation-receipt.json; do test -f "$$f" || continue; printf '%s\n' "$$f"; done; } >"$$manifest"; printf 'test-bindings receipt: %s\n' "$$receipt"; exit "$$status"

test-stand:
	mkdir -p $(PERSISTENT_DIRS)
	env $(PERSISTENT_ENV) go test ./stand

test-report:
	mkdir -p $(PERSISTENT_DIRS) $(DATA_ROOT)/history/m0-v4/receipts $(DATA_ROOT)/terminal-receipts
	env $(PERSISTENT_ENV) go test ./report
	@set +e; cd report && env $(PERSISTENT_ENV) npm ci --ignore-scripts --offline; status=$$?; cd ..; printf 'target=test-report\nstage=npm-ci-offline\nexit_code=%s\nlog_dir=%s\n' "$$status" '$(DATA_ROOT)/npm-cache/_logs' >$(DATA_ROOT)/terminal-receipts/test-report-npm.receipt; exit "$$status"
	cd report && env $(PERSISTENT_ENV) node --test history-append.test.mjs
	if test ! -f $(DATA_ROOT)/history/m0-v4/receipts/m0-timed-run-1; then if test ! -f $(DATA_ROOT)/report/results/m0-timed-run-1/pilot-events.jsonl; then env $(PERSISTENT_ENV) GONKACTL_TEST_RUN_ID=m0-timed-run-1 go run ./cmd/m0report; fi; cd report && env $(PERSISTENT_ENV) bash render-transaction.sh $(DATA_ROOT) m0-timed-run-1; fi
	if test ! -f $(DATA_ROOT)/history/m0-v4/receipts/m0-timed-run-2; then if test ! -f $(DATA_ROOT)/report/results/m0-timed-run-2/pilot-events.jsonl; then env $(PERSISTENT_ENV) GONKACTL_TEST_RUN_ID=m0-timed-run-2 go run ./cmd/m0report; fi; cd report && env $(PERSISTENT_ENV) bash render-transaction.sh $(DATA_ROOT) m0-timed-run-2; fi
	cd report && env $(PERSISTENT_ENV) GONKACTL_TEST_REPORT_OUTPUT=$(DATA_ROOT)/report/render/rerender-run-2 GONKACTL_TEST_HISTORY_PATH=$(DATA_ROOT)/history/m0-v4/history.jsonl GONKACTL_TEST_APPEND_HISTORY=false ./node_modules/.bin/allure generate --config allurerc.mjs $(DATA_ROOT)/report/results/m0-timed-run-2
	test "$$(wc -l < $(DATA_ROOT)/history/m0-v4/history.jsonl)" -eq 2
	env $(PERSISTENT_ENV) bash report/browser-smoke.sh $(DATA_ROOT)

test-storage:
	mkdir -p $(PERSISTENT_DIRS) $(DATA_ROOT)/storage-prefix
	@set +e; env $(PERSISTENT_ENV) GONKACTL_TEST_STORAGE_INTEGRATION=1 GONKACTL_TEST_STORAGE_DATA_ROOT=$(DATA_ROOT)/storage-prefix GONKACTL_TEST_ALLURE_BUNDLE=$(DATA_ROOT)/report/render/rerender-run-2/awesomeBDD go test ./report -run '^TestStoragePrefixIntegration$$' -count=1 -v >$(DATA_ROOT)/storage-prefix/test-storage.log 2>&1; status=$$?; cat $(DATA_ROOT)/storage-prefix/test-storage.log; printf 'target=test-storage\nexit_code=%s\nlog=%s\nbundle=%s\n' "$$status" '$(DATA_ROOT)/storage-prefix/test-storage.log' '$(DATA_ROOT)/report/render/rerender-run-2/awesomeBDD' >$(DATA_ROOT)/storage-prefix/test-storage.receipt; exit "$$status"

check: test-contracts test-bindings test-stand test-report
