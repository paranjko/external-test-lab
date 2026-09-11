.PHONY: test-contracts test-bindings test-stand test-browser-probe test-report test-storage check

DATA_ROOT := $(abspath ../build/gonkactl-test)
QUALIFICATION_RUN_ID := m0-qualification-$(shell date -u +%Y%m%dT%H%M%SZ)-$(shell printf '%s' "$(MAKELEVEL)-$(PPID)" | sha256sum | cut -c1-8)
QUALIFICATION_RUN_ID_2 := $(QUALIFICATION_RUN_ID)-rerun
QUALIFICATION_HISTORY_SCOPE := $(DATA_ROOT)/history/$(QUALIFICATION_RUN_ID)
QUALIFICATION_RERENDER_ROOT := $(DATA_ROOT)/report/render/$(QUALIFICATION_RUN_ID_2)-final
PERSISTENT_DIRS := $(DATA_ROOT)/go-cache $(DATA_ROOT)/go-mod-cache $(DATA_ROOT)/go-tmp $(DATA_ROOT)/tmp $(DATA_ROOT)/npm-cache $(DATA_ROOT)/xdg-cache $(DATA_ROOT)/xdg-config $(DATA_ROOT)/xdg-runtime $(DATA_ROOT)/browser-cache $(DATA_ROOT)/child-home
PERSISTENT_ENV := GOCACHE=$(DATA_ROOT)/go-cache GOMODCACHE=$(DATA_ROOT)/go-mod-cache GOTMPDIR=$(DATA_ROOT)/go-tmp TMPDIR=$(DATA_ROOT)/tmp TMP=$(DATA_ROOT)/tmp TEMP=$(DATA_ROOT)/tmp NPM_CONFIG_CACHE=$(DATA_ROOT)/npm-cache XDG_CACHE_HOME=$(DATA_ROOT)/xdg-cache XDG_CONFIG_HOME=$(DATA_ROOT)/xdg-config PLAYWRIGHT_BROWSERS_PATH=$(DATA_ROOT)/browser-cache HOME=$(DATA_ROOT)/child-home JAVA_TOOL_OPTIONS=-Djava.io.tmpdir=$(DATA_ROOT)/tmp
BROWSER_RUNTIME_DIR := $(or $(XDG_RUNTIME_DIR),/run/user/$(shell id -u))
BROWSER_ENV := HOME=$(DATA_ROOT)/child-home PATH=$(PATH) TMPDIR=$(DATA_ROOT)/tmp XDG_RUNTIME_DIR=$(BROWSER_RUNTIME_DIR)

test-contracts:
	mkdir -p $(PERSISTENT_DIRS)
	env $(PERSISTENT_ENV) go test ./contracts

test-bindings:
	mkdir -p $(PERSISTENT_DIRS) $(DATA_ROOT)/terminal-receipts
	@set +e; command='env $(PERSISTENT_ENV) GONKACTL_TEST_DATA_ROOT=$(DATA_ROOT) go test -race -count=1 ./bindings'; log='$(DATA_ROOT)/terminal-receipts/test-bindings.log'; receipt='$(DATA_ROOT)/terminal-receipts/test-bindings.receipt'; manifest='$(DATA_ROOT)/terminal-receipts/test-bindings-upstream.manifest'; env $(PERSISTENT_ENV) GONKACTL_TEST_DATA_ROOT=$(DATA_ROOT) go test -race -count=1 ./bindings >"$$log" 2>&1; status=$$?; cat "$$log"; { printf 'target=test-bindings\ncommand=%s\nexit_code=%s\nhead=%s\ntree=%s\nlog=%s\nupstream_manifest=%s\n' "$$command" "$$status" "$$(git rev-parse HEAD)" "$$(git rev-parse 'HEAD^{tree}')" "$$log" "$$manifest"; } >"$$receipt"; { for f in $(DATA_ROOT)/process-receipts/*.json; do test -f "$$f" || continue; exit_code=$$(sed -n 's/^[[:space:]]*"exit_code": \(-\{0,1\}[0-9][0-9]*\).*/\1/p' "$$f"); interrupted=$$(sed -n 's/^[[:space:]]*"interrupted": \(true\|false\).*/\1/p' "$$f"); if test "$$interrupted" = true; then outcome=interruption; elif test "$$exit_code" = 0; then outcome=pass; else outcome=fail; fi; printf '%s outcome=%s exit_code=%s interrupted=%s\n' "$$f" "$$outcome" "$$exit_code" "$$interrupted"; done; for f in $(DATA_ROOT)/actual-child-env/child-environment-receipts/*.json $(DATA_ROOT)/runtime-path-receipts/*.json $(DATA_ROOT)/runner-archive/*/validation-receipt.json; do test -f "$$f" || continue; printf '%s\n' "$$f"; done; } >"$$manifest"; printf 'test-bindings receipt: %s\n' "$$receipt"; exit "$$status"

test-stand:
	mkdir -p $(PERSISTENT_DIRS)
	env $(PERSISTENT_ENV) go test ./stand

test-browser-probe:
	mkdir -p $(PERSISTENT_DIRS) $(DATA_ROOT)/report/browser-probe
	chmod 700 $(DATA_ROOT)/child-home
	@set +e; env -u XDG_CACHE_HOME -u XDG_CONFIG_HOME -u TMP -u TEMP $(BROWSER_ENV) bash report/browser-probe.sh $(DATA_ROOT); status=$$?; cat $(DATA_ROOT)/report/browser-probe/receipt.txt; exit "$$status"

test-report:
	mkdir -p $(PERSISTENT_DIRS) $(QUALIFICATION_HISTORY_SCOPE)/receipts $(DATA_ROOT)/terminal-receipts
	chmod 700 $(DATA_ROOT)/child-home
	@set +e; command='env $(PERSISTENT_ENV) go test ./report'; env $(PERSISTENT_ENV) go test ./report; status=$$?; printf 'target=test-report\nstage=go-test\ncommand=%s\nexit_code=%s\nhead=%s\ntree=%s\n' "$$command" "$$status" "$$(git rev-parse HEAD)" "$$(git rev-parse 'HEAD^{tree}')" >$(DATA_ROOT)/terminal-receipts/test-report-go.receipt; test $$status -eq 0
	@set +e; cd report && env $(PERSISTENT_ENV) npm ci --ignore-scripts --offline; status=$$?; cd ..; printf 'target=test-report\nstage=npm-ci-offline\nexit_code=%s\nlog_dir=%s\n' "$$status" '$(DATA_ROOT)/npm-cache/_logs' >$(DATA_ROOT)/terminal-receipts/test-report-npm.receipt; exit "$$status"
	cd report && env $(PERSISTENT_ENV) node --test history-append.test.mjs
	if test ! -f $(QUALIFICATION_HISTORY_SCOPE)/receipts/$(QUALIFICATION_RUN_ID); then env $(PERSISTENT_ENV) GONKACTL_TEST_RUN_ID=$(QUALIFICATION_RUN_ID) go run ./cmd/m0report; cd report && env $(PERSISTENT_ENV) GONKACTL_TEST_HISTORY_SCOPE=$(QUALIFICATION_HISTORY_SCOPE) GONKACTL_TEST_PROTOCOL_HISTORY_ID=$(QUALIFICATION_RUN_ID)-protocol GONKACTL_TEST_EVIDENCE_HISTORY_ID=$(QUALIFICATION_RUN_ID)-evidence bash render-transaction.sh $(DATA_ROOT) $(QUALIFICATION_RUN_ID); fi
	if test ! -f $(QUALIFICATION_HISTORY_SCOPE)/receipts/$(QUALIFICATION_RUN_ID_2); then env $(PERSISTENT_ENV) GONKACTL_TEST_RUN_ID=$(QUALIFICATION_RUN_ID_2) go run ./cmd/m0report; cd report && env $(PERSISTENT_ENV) GONKACTL_TEST_HISTORY_SCOPE=$(QUALIFICATION_HISTORY_SCOPE) GONKACTL_TEST_PROTOCOL_HISTORY_ID=$(QUALIFICATION_RUN_ID_2)-protocol GONKACTL_TEST_EVIDENCE_HISTORY_ID=$(QUALIFICATION_RUN_ID_2)-evidence bash render-transaction.sh $(DATA_ROOT) $(QUALIFICATION_RUN_ID_2); fi
	test "$$(wc -l < $(QUALIFICATION_HISTORY_SCOPE)/history.jsonl)" -eq 2
	cd report && env $(PERSISTENT_ENV) GONKACTL_TEST_REPORT_OUTPUT=$(QUALIFICATION_RERENDER_ROOT) GONKACTL_TEST_HISTORY_PATH=$(QUALIFICATION_HISTORY_SCOPE)/history.jsonl GONKACTL_TEST_APPEND_HISTORY=false ./node_modules/.bin/allure generate --config allurerc.mjs $(DATA_ROOT)/report/results/$(QUALIFICATION_RUN_ID_2)
	env -u XDG_CACHE_HOME -u XDG_CONFIG_HOME -u TMP -u TEMP $(BROWSER_ENV) bash report/browser-smoke.sh $(DATA_ROOT) $(QUALIFICATION_RUN_ID_2) $(QUALIFICATION_RERENDER_ROOT)
	@{ printf 'target=test-report\ncommand=make test-report\nexit_code=0\nhead=%s\ntree=%s\nevidence=%s\nbundle=%s\nbrowser_receipt=%s\n' "$$(git rev-parse HEAD)" "$$(git rev-parse 'HEAD^{tree}')" "$(QUALIFICATION_HISTORY_SCOPE)/receipts/$(QUALIFICATION_RUN_ID)" "$(QUALIFICATION_RERENDER_ROOT)/awesomeBDD" "$(DATA_ROOT)/report/browser-smoke/receipt.txt"; } >$(DATA_ROOT)/terminal-receipts/test-report.receipt

test-storage: test-report
	mkdir -p $(PERSISTENT_DIRS) $(DATA_ROOT)/storage-prefix
	@set -e; bundle=$$(sed -n 's/^bundle=//p' $(DATA_ROOT)/terminal-receipts/test-report.receipt); test -n "$$bundle"; test -d "$$bundle"; set +e; env -u XDG_CACHE_HOME -u XDG_CONFIG_HOME -u TMP -u TEMP $(BROWSER_ENV) GONKACTL_TEST_STORAGE_INTEGRATION=1 GONKACTL_TEST_STORAGE_DATA_ROOT=$(DATA_ROOT)/storage-prefix GONKACTL_TEST_ALLURE_BUNDLE="$$bundle" go test ./report -run '^TestStoragePrefixIntegration$$' -count=1 -v >$(DATA_ROOT)/storage-prefix/test-storage.log 2>&1; status=$$?; cat $(DATA_ROOT)/storage-prefix/test-storage.log; if test $$status -eq 0; then printf 'target=test-storage\nexit_code=0\nlog=%s\nbundle=%s\nbrowser_http_receipt=%s\nbrowser_https_receipt=%s\n' '$(DATA_ROOT)/storage-prefix/test-storage.log' "$$bundle" '$(DATA_ROOT)/storage-prefix/browser-http/receipt.txt' '$(DATA_ROOT)/storage-prefix/browser-https/receipt.txt' >$(DATA_ROOT)/storage-prefix/test-storage.receipt; fi; exit "$$status"

check: test-contracts test-bindings test-stand test-report
