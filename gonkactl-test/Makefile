.PHONY: test-contracts test-bindings test-stand test-browser-probe test-report test-storage check-deadcode generate-cli-docs check qa install docker-image clean

DATA_ROOT := $(abspath ../build/gonkactl-test)
BROWSER_TEMP_ROOT := $(abspath ../build/gonkactl-test-browser-tmp)
QUALIFICATION_RUN_ID := qualification-$(shell date -u +%Y%m%dT%H%M%SZ)-$(shell printf '%s' "$(MAKELEVEL)-$(PPID)" | sha256sum | cut -c1-8)
QUALIFICATION_RUN_ID_2 := $(QUALIFICATION_RUN_ID)-rerun
QUALIFICATION_HISTORY_SCOPE := $(DATA_ROOT)/history/$(QUALIFICATION_RUN_ID)
QUALIFICATION_RERENDER_ROOT := $(DATA_ROOT)/report/render/$(QUALIFICATION_RUN_ID_2)-final
PERSISTENT_DIRS := $(DATA_ROOT)/go-cache $(DATA_ROOT)/go-mod-cache $(DATA_ROOT)/go-tmp $(DATA_ROOT)/tmp $(DATA_ROOT)/npm-cache $(DATA_ROOT)/xdg-cache $(DATA_ROOT)/xdg-config $(DATA_ROOT)/xdg-runtime $(DATA_ROOT)/browser-cache $(DATA_ROOT)/child-home
PERSISTENT_ENV := GOCACHE=$(DATA_ROOT)/go-cache GOMODCACHE=$(DATA_ROOT)/go-mod-cache GOTMPDIR=$(DATA_ROOT)/go-tmp TMPDIR=$(DATA_ROOT)/tmp TMP=$(DATA_ROOT)/tmp TEMP=$(DATA_ROOT)/tmp NPM_CONFIG_CACHE=$(DATA_ROOT)/npm-cache XDG_CACHE_HOME=$(DATA_ROOT)/xdg-cache XDG_CONFIG_HOME=$(DATA_ROOT)/xdg-config PLAYWRIGHT_BROWSERS_PATH=$(DATA_ROOT)/browser-cache HOME=$(DATA_ROOT)/child-home JAVA_TOOL_OPTIONS=-Djava.io.tmpdir=$(DATA_ROOT)/tmp
BROWSER_RUNTIME_DIR := $(or $(XDG_RUNTIME_DIR),/run/user/$(shell id -u))
BROWSER_ENV := HOME=$(DATA_ROOT)/child-home PATH=$(PATH) GONKACTL_TEST_BROWSER_TEMP_ROOT=$(BROWSER_TEMP_ROOT) TMPDIR=. TMP=. TEMP=. XDG_RUNTIME_DIR=$(BROWSER_RUNTIME_DIR)
BIN_DIR ?= $(HOME)/.local/bin
CLEAN_DATA_ROOT := $(abspath $(DATA_ROOT))
CLEAN_BROWSER_TEMP_ROOT := $(abspath $(BROWSER_TEMP_ROOT))
CLEAN_CONTAINER_IMAGE ?= alpine:3.20
DOCKER_IMAGE ?= gonkactl-test:local

docker-image:
	docker build --file Dockerfile --tag $(DOCKER_IMAGE) .

test-contracts:
	mkdir -p $(PERSISTENT_DIRS) $(DATA_ROOT)/terminal-receipts
	@set +e; command='env $(PERSISTENT_ENV) go test ./spec'; log='$(DATA_ROOT)/terminal-receipts/test-contracts.log'; receipt='$(DATA_ROOT)/terminal-receipts/test-contracts.receipt'; env $(PERSISTENT_ENV) go test ./spec >"$$log" 2>&1; status=$$?; cat "$$log"; { printf 'target=test-contracts\ncommand=%s\nexit_code=%s\nhead=%s\ntree=%s\nlog=%s\n' "$$command" "$$status" "$$(git rev-parse HEAD)" "$$(git rev-parse 'HEAD^{tree}')" "$$log"; } >"$$receipt"; printf 'test-contracts receipt: %s\n' "$$receipt"; exit "$$status"

test-bindings:
	mkdir -p $(PERSISTENT_DIRS) $(DATA_ROOT)/terminal-receipts
	@set +e; command='env $(PERSISTENT_ENV) GONKACTL_TEST_DATA_ROOT=$(DATA_ROOT) go test -race -count=1 ./execution'; log='$(DATA_ROOT)/terminal-receipts/test-bindings.log'; receipt='$(DATA_ROOT)/terminal-receipts/test-bindings.receipt'; manifest='$(DATA_ROOT)/terminal-receipts/test-bindings-upstream.manifest'; env $(PERSISTENT_ENV) GONKACTL_TEST_DATA_ROOT=$(DATA_ROOT) go test -race -count=1 ./execution >"$$log" 2>&1; status=$$?; cat "$$log"; { printf 'target=test-bindings\ncommand=%s\nexit_code=%s\nhead=%s\ntree=%s\nlog=%s\nupstream_manifest=%s\n' "$$command" "$$status" "$$(git rev-parse HEAD)" "$$(git rev-parse 'HEAD^{tree}')" "$$log" "$$manifest"; } >"$$receipt"; { for f in $(DATA_ROOT)/process-receipts/*.json; do test -f "$$f" || continue; exit_code=$$(sed -n 's/^[[:space:]]*"exit_code": \(-\{0,1\}[0-9][0-9]*\).*/\1/p' "$$f"); interrupted=$$(sed -n 's/^[[:space:]]*"interrupted": \(true\|false\).*/\1/p' "$$f"); if test "$$interrupted" = true; then outcome=interruption; elif test "$$exit_code" = 0; then outcome=pass; else outcome=fail; fi; printf '%s outcome=%s exit_code=%s interrupted=%s\n' "$$f" "$$outcome" "$$exit_code" "$$interrupted"; done; for f in $(DATA_ROOT)/actual-child-env/child-environment-receipts/*.json $(DATA_ROOT)/runtime-path-receipts/*.json $(DATA_ROOT)/runner-archive/*/validation-receipt.json; do test -f "$$f" || continue; printf '%s\n' "$$f"; done; } >"$$manifest"; printf 'test-bindings receipt: %s\n' "$$receipt"; exit "$$status"

test-stand:
	mkdir -p $(PERSISTENT_DIRS) $(DATA_ROOT)/terminal-receipts
	@set +e; command='env $(PERSISTENT_ENV) go test ./stand ./cmd'; log='$(DATA_ROOT)/terminal-receipts/test-stand.log'; receipt='$(DATA_ROOT)/terminal-receipts/test-stand.receipt'; env $(PERSISTENT_ENV) go test ./stand ./cmd >"$$log" 2>&1; status=$$?; cat "$$log"; { printf 'target=test-stand\ncommand=%s\nexit_code=%s\nhead=%s\ntree=%s\nlog=%s\n' "$$command" "$$status" "$$(git rev-parse HEAD)" "$$(git rev-parse 'HEAD^{tree}')" "$$log"; } >"$$receipt"; printf 'test-stand receipt: %s\n' "$$receipt"; exit "$$status"

test-browser-probe:
	mkdir -p $(PERSISTENT_DIRS) $(BROWSER_TEMP_ROOT) $(DATA_ROOT)/report/browser-probe
	chmod 700 $(DATA_ROOT)/child-home
	@set +e; env -u XDG_CACHE_HOME -u XDG_CONFIG_HOME -u TMP -u TEMP $(BROWSER_ENV) $(PERSISTENT_ENV) go run ./cmd browser-probe $(DATA_ROOT); status=$$?; cat $(DATA_ROOT)/report/browser-probe/receipt.txt; exit "$$status"

test-report:
	mkdir -p $(PERSISTENT_DIRS) $(BROWSER_TEMP_ROOT) $(QUALIFICATION_HISTORY_SCOPE)/receipts $(DATA_ROOT)/terminal-receipts
	chmod 700 $(DATA_ROOT)/child-home
	@set +e; cd report && env $(PERSISTENT_ENV) npm ci --ignore-scripts; status=$$?; cd ..; printf 'target=test-report\nstage=npm-ci\nexit_code=%s\nlog_dir=%s\n' "$$status" '$(DATA_ROOT)/npm-cache/_logs' >$(DATA_ROOT)/terminal-receipts/test-report-npm.receipt; exit "$$status"
	@set +e; command='env $(PERSISTENT_ENV) go test -count=1 ./report'; env $(PERSISTENT_ENV) go test -count=1 ./report; status=$$?; printf 'target=test-report\nstage=go-test\ncommand=%s\nexit_code=%s\nhead=%s\ntree=%s\n' "$$command" "$$status" "$$(git rev-parse HEAD)" "$$(git rev-parse 'HEAD^{tree}')" >$(DATA_ROOT)/terminal-receipts/test-report-go.receipt; test $$status -eq 0
	cd report && env $(PERSISTENT_ENV) node --test history-append.test.mjs
	if test ! -f $(QUALIFICATION_HISTORY_SCOPE)/receipts/$(QUALIFICATION_RUN_ID); then env $(PERSISTENT_ENV) DATA_ROOT=$(DATA_ROOT)/report GONKACTL_TEST_RUN_ID=$(QUALIFICATION_RUN_ID) go run ./cmd report; env $(PERSISTENT_ENV) GONKACTL_TEST_HISTORY_SCOPE=$(QUALIFICATION_HISTORY_SCOPE) GONKACTL_TEST_PROTOCOL_HISTORY_ID=$(QUALIFICATION_RUN_ID)-protocol GONKACTL_TEST_EVIDENCE_HISTORY_ID=$(QUALIFICATION_RUN_ID)-evidence go run ./cmd render-transaction $(DATA_ROOT) $(QUALIFICATION_RUN_ID); fi
	if test ! -f $(QUALIFICATION_HISTORY_SCOPE)/receipts/$(QUALIFICATION_RUN_ID_2); then env $(PERSISTENT_ENV) DATA_ROOT=$(DATA_ROOT)/report GONKACTL_TEST_RUN_ID=$(QUALIFICATION_RUN_ID_2) go run ./cmd report; env $(PERSISTENT_ENV) GONKACTL_TEST_HISTORY_SCOPE=$(QUALIFICATION_HISTORY_SCOPE) GONKACTL_TEST_PROTOCOL_HISTORY_ID=$(QUALIFICATION_RUN_ID)-protocol GONKACTL_TEST_EVIDENCE_HISTORY_ID=$(QUALIFICATION_RUN_ID_2)-evidence go run ./cmd render-transaction $(DATA_ROOT) $(QUALIFICATION_RUN_ID_2); fi
	test "$$(wc -l < $(QUALIFICATION_HISTORY_SCOPE)/history.jsonl)" -eq 2
	cd report && env $(PERSISTENT_ENV) GONKACTL_TEST_REPORT_OUTPUT=$(QUALIFICATION_RERENDER_ROOT) GONKACTL_TEST_HISTORY_PATH=$(QUALIFICATION_HISTORY_SCOPE)/history.jsonl GONKACTL_TEST_APPEND_HISTORY=false ./node_modules/.bin/allure generate --config allurerc.mjs $(DATA_ROOT)/report/results/$(QUALIFICATION_RUN_ID_2)
	@set +e; command='env -u XDG_CACHE_HOME -u XDG_CONFIG_HOME -u TMP -u TEMP $(BROWSER_ENV) $(PERSISTENT_ENV) go run ./cmd browser-smoke $(DATA_ROOT) $(QUALIFICATION_RUN_ID_2) $(QUALIFICATION_RERENDER_ROOT)'; env -u XDG_CACHE_HOME -u XDG_CONFIG_HOME -u TMP -u TEMP $(BROWSER_ENV) $(PERSISTENT_ENV) go run ./cmd browser-smoke $(DATA_ROOT) $(QUALIFICATION_RUN_ID_2) $(QUALIFICATION_RERENDER_ROOT); status=$$?; if test $$status -ne 0; then { printf 'target=test-report\nstage=browser-smoke\ncommand=%s\nexit_code=%s\nhead=%s\ntree=%s\nbrowser_receipt=%s\n' "$$command" "$$status" "$$(git rev-parse HEAD)" "$$(git rev-parse 'HEAD^{tree}')" "$(DATA_ROOT)/report/browser-smoke/receipt.txt"; } >$(DATA_ROOT)/terminal-receipts/test-report.receipt; fi; exit "$$status"
	@{ printf 'target=test-report\ncommand=make test-report\nexit_code=0\nhead=%s\ntree=%s\nevidence=%s\nbundle=%s\nbrowser_receipt=%s\n' "$$(git rev-parse HEAD)" "$$(git rev-parse 'HEAD^{tree}')" "$(QUALIFICATION_HISTORY_SCOPE)/receipts/$(QUALIFICATION_RUN_ID)" "$(QUALIFICATION_RERENDER_ROOT)/awesomeBDD" "$(DATA_ROOT)/report/browser-smoke/receipt.txt"; } >$(DATA_ROOT)/terminal-receipts/test-report.receipt

test-storage: test-report
	mkdir -p $(PERSISTENT_DIRS) $(BROWSER_TEMP_ROOT) $(DATA_ROOT)/storage-data $(DATA_ROOT)/storage-evidence $(DATA_ROOT)/terminal-receipts
	@set +e; log='$(DATA_ROOT)/storage-evidence/test-storage.log'; receipt='$(DATA_ROOT)/storage-evidence/test-storage.receipt'; terminal='$(DATA_ROOT)/terminal-receipts/test-storage.receipt'; bundle=$$(sed -n 's/^bundle=//p' $(DATA_ROOT)/terminal-receipts/test-report.receipt); command='env -u XDG_CACHE_HOME -u XDG_CONFIG_HOME -u TMP -u TEMP $(BROWSER_ENV) $(PERSISTENT_ENV) GONKACTL_TEST_STORAGE_INTEGRATION=1 GONKACTL_TEST_STORAGE_DATA_ROOT=$(DATA_ROOT)/storage-data GONKACTL_TEST_STORAGE_EVIDENCE_ROOT=$(DATA_ROOT)/storage-evidence GONKACTL_TEST_BROWSER_TEMP_ROOT=$(BROWSER_TEMP_ROOT) GONKACTL_TEST_ALLURE_BUNDLE=<generated-bundle> go test ./report -run ^TestStoragePrefixIntegration$$ -count=1 -v'; if test -z "$$bundle" || test ! -d "$$bundle"; then status=64; printf 'test-storage preflight failed: generated bundle is missing: %s\n' "$$bundle" >"$$log"; else env -u XDG_CACHE_HOME -u XDG_CONFIG_HOME -u TMP -u TEMP $(BROWSER_ENV) $(PERSISTENT_ENV) GONKACTL_TEST_STORAGE_INTEGRATION=1 GONKACTL_TEST_STORAGE_DATA_ROOT=$(DATA_ROOT)/storage-data GONKACTL_TEST_STORAGE_EVIDENCE_ROOT=$(DATA_ROOT)/storage-evidence GONKACTL_TEST_BROWSER_TEMP_ROOT=$(BROWSER_TEMP_ROOT) GONKACTL_TEST_ALLURE_BUNDLE="$$bundle" go test ./report -run '^TestStoragePrefixIntegration$$' -count=1 -v >"$$log" 2>&1; status=$$?; fi; cat "$$log"; { printf 'target=test-storage\ncommand=%s\nexit_code=%s\nhead=%s\ntree=%s\nlog=%s\nbundle=%s\nbrowser_temp_root=%s\nbrowser_http_receipt=%s\nbrowser_https_receipt=%s\ncleanup_receipt=%s\n' "$$command" "$$status" "$$(git rev-parse HEAD)" "$$(git rev-parse 'HEAD^{tree}')" "$$log" "$$bundle" '$(BROWSER_TEMP_ROOT)' '$(DATA_ROOT)/storage-evidence/browser-http/receipt.txt' '$(DATA_ROOT)/storage-evidence/browser-https/receipt.txt' '$(DATA_ROOT)/storage-evidence/cleanup-receipt.json'; } >"$$receipt"; cp "$$receipt" "$$terminal"; printf 'test-storage receipt: %s\n' "$$terminal"; exit "$$status"

check-deadcode:
	mkdir -p $(PERSISTENT_DIRS) $(DATA_ROOT)/bin $(DATA_ROOT)/terminal-receipts
	@set +e; command='env $(PERSISTENT_ENV) GOBIN=$(DATA_ROOT)/bin go install golang.org/x/tools/cmd/deadcode@latest && $(DATA_ROOT)/bin/deadcode -test ./...'; log='$(DATA_ROOT)/terminal-receipts/check-deadcode.log'; findings='$(DATA_ROOT)/terminal-receipts/check-deadcode.findings'; receipt='$(DATA_ROOT)/terminal-receipts/check-deadcode.receipt'; env $(PERSISTENT_ENV) GOBIN=$(DATA_ROOT)/bin go install golang.org/x/tools/cmd/deadcode@latest >"$$log" 2>&1; status=$$?; if test $$status -eq 0; then $(DATA_ROOT)/bin/deadcode -test ./... >"$$findings" 2>&1; status=$$?; cat "$$findings" >>"$$log"; if test $$status -eq 0 && test -s "$$findings"; then status=1; fi; fi; cat "$$log"; { printf 'target=check-deadcode\ncommand=%s\nexit_code=%s\nhead=%s\ntree=%s\nlog=%s\nfindings=%s\n' "$$command" "$$status" "$$(git rev-parse HEAD)" "$$(git rev-parse 'HEAD^{tree}')" "$$log" "$$findings"; } >"$$receipt"; printf 'check-deadcode receipt: %s\n' "$$receipt"; exit "$$status"

generate-cli-docs:
	mkdir -p $(PERSISTENT_DIRS)
	env $(PERSISTENT_ENV) go run ./cmd docs docs/cli

check: test-contracts test-bindings test-stand test-report check-deadcode

# qa is the complete local quality gate, including isolated Storage HTTP/HTTPS.
qa: test-browser-probe check test-storage

# install builds the standalone fixture runner into the user's bin directory.
install:
	mkdir -p "$(BIN_DIR)" $(PERSISTENT_DIRS)
	env $(PERSISTENT_ENV) go build -o "$(BIN_DIR)/gonkactl-test" ./cmd
	@printf 'installed %s\n' "$(BIN_DIR)/gonkactl-test"

# clean removes only this harness's owned build roots. It deliberately rejects
# arbitrary DATA_ROOT overrides to avoid deleting unrelated user data.
clean:
	@case "$(CLEAN_DATA_ROOT)" in "$(abspath ../build)/gonkactl-test"|"$(abspath ../build)/gonkactl-test-"*) ;; *) echo "refusing unsafe DATA_ROOT: $(CLEAN_DATA_ROOT)" >&2; exit 2;; esac
	@case "$(CLEAN_BROWSER_TEMP_ROOT)" in "$(abspath ../build)/gonkactl-test-browser-tmp"|"$(abspath ../build)/gonkactl-test-browser-tmp-"*) ;; *) echo "refusing unsafe BROWSER_TEMP_ROOT: $(CLEAN_BROWSER_TEMP_ROOT)" >&2; exit 2;; esac
	@for root in "$(CLEAN_DATA_ROOT)" "$(CLEAN_BROWSER_TEMP_ROOT)"; do test -e "$$root" || continue; find "$$root" -user "$$(id -u)" ! -type l -exec chmod u+w {} +; if find "$$root" ! -user "$$(id -u)" -print -quit | grep -q .; then docker run --rm --pull=never --user 0:0 --volume "$$root:/owned" --entrypoint /bin/sh "$(CLEAN_CONTAINER_IMAGE)" -ec 'find /owned -mindepth 1 -delete'; fi; done
	rm -rf -- "$(CLEAN_DATA_ROOT)" "$(CLEAN_BROWSER_TEMP_ROOT)"
	@find report -maxdepth 1 \( -name '.com.google.Chrome.*' -o -name 'scoped_dir*' \) -exec rm -rf -- {} +
