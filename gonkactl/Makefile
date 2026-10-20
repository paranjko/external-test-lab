GO ?= go
export GOTOOLCHAIN := local
export GOWORK := off
VERSION ?= devel
COMMIT ?= $(shell git rev-parse HEAD)
BUILD_DATE ?= $(shell git show -s --format=%cI HEAD)
VERSION_PACKAGE := github.com/paranjko/external-test-lab/gonkactl/internal/cli
LDFLAGS := -X $(VERSION_PACKAGE).Version=$(VERSION) -X $(VERSION_PACKAGE).Commit=$(COMMIT) -X $(VERSION_PACKAGE).BuildDate=$(BUILD_DATE)

.PHONY: all check toolchain portable-env fmt fmt-check test vet race build smoke

all: check

# Source-snapshot checks only; this is not the recovery/JOIN acceptance gate.
check: fmt-check test vet race smoke recovery-native

toolchain:
	@case "$$($(GO) env GOVERSION)" in go1.27.*) ;; *) echo 'Go 1.27.x is required for this snapshot' >&2; exit 1;; esac

portable-env:
	@test -z "$${GONKACTL_TEST_ENV}" -a -z "$${GONKACTL_TEST_RECEIPT}" || { echo 'Run portable checks without acceptance environment/receipt variables' >&2; exit 1; }

fmt:
	find cmd internal tests -type f -name '*.go' -exec gofmt -w {} +

fmt-check:
	@files="$$(find cmd internal tests -type f -name '*.go' -exec gofmt -l {} +)"; test -z "$$files" || { printf '%s\n' "$$files"; exit 1; }

test: toolchain portable-env
	$(GO) test -count=1 ./...

vet: toolchain
	$(GO) vet ./...

race: toolchain portable-env
	$(GO) test -race -count=1 ./...

build: toolchain
	mkdir -p build
	$(GO) build -trimpath -buildvcs=false -ldflags '$(LDFLAGS)' -o build/gonkactl ./cmd/gonkactl

smoke: build
	./build/gonkactl --help
	./build/gonkactl version

.PHONY: test-release release-archives release-publish
test-release:
	python3 -m unittest discover -s scripts -p 'test_*.py'
	sh -n ../net-deployment-runbook/04-ops/site/ctl/install.sh

release-archives: toolchain
	python3 scripts/release.py build

release-publish:
	python3 scripts/release.py publish

.PHONY: test-release-native
test-release-native:
	python3 scripts/check_native_install.py

.PHONY: qualify-page
qualify-page:
	node scripts/check_page.mjs

# Local protocol gates. These do not qualify Core repair or a live incident.
.PHONY: recovery-contract recovery-lifecycle recovery-core-rehearsal recovery-incident-rehearsal recovery-acceptance
recovery-contract: toolchain portable-env
	$(GO) test -count=1 ./internal/rehearsal ./internal/rehearsal/contract ./internal/rehearsal/input ./internal/rehearsal/evidence
	$(GO) test -count=1 ./internal/cli -run Rehearsal

recovery-lifecycle: toolchain portable-env
	$(GO) test -race -count=1 ./internal/rehearsal/lifecycle

.PHONY: recovery-native
recovery-native: toolchain portable-env
	$(GO) test -race -count=1 -tags gnklab0002_live ./internal/incidenthost ./internal/cli
	$(GO) vet -tags gnklab0002_live ./internal/incidenthost ./internal/cli

recovery-core-rehearsal recovery-incident-rehearsal:
	@echo 'BLOCKED: runtime qualification adapter and qualified Core artifacts are not available' >&2
	@exit 2

recovery-acceptance: recovery-contract recovery-lifecycle recovery-core-rehearsal recovery-incident-rehearsal check
