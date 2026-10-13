.PHONY: all build test vet install qualify perfetto-ui release qualify-perfetto qualify-history qualify-ui ui-deps demo

export GOWORK := off
export GOCACHE := $(CURDIR)/.cache/go-build
export GOTMPDIR := $(CURDIR)/.cache/go-tmp
export TMPDIR := $(GOTMPDIR)

VERSION ?= dev
COMMIT ?= $(shell git rev-parse HEAD)
BUILD_DATE ?= $(shell git show -s --format=%cI HEAD)
LDFLAGS := -X main.version=$(VERSION) -X main.commit=$(COMMIT) -X main.buildDate=$(BUILD_DATE)

all: test vet build qualify-ui test-release

ui-deps:
	npm ci --ignore-scripts --no-audit --no-fund

demo: build
	python3 examples/synthetic.py
	./gonkactl-trace report --input .cache/synthetic/dataset.json

build:
	mkdir -p $(GOCACHE) $(GOTMPDIR)
	go build -trimpath -buildvcs=false -ldflags '$(LDFLAGS)' -o gonkactl-trace .

install:
	mkdir -p $(GOCACHE) $(GOTMPDIR)
	go install -trimpath -buildvcs=false -ldflags '$(LDFLAGS)' .

test:
	mkdir -p $(GOCACHE) $(GOTMPDIR)
	go test -race ./...

vet:
	mkdir -p $(GOCACHE) $(GOTMPDIR)
	go vet ./...

qualify:
	mkdir -p $(GOCACHE) $(GOTMPDIR)
	GONKACTL_TRACE_REQUIRE_SAMPLE=1 go test -race -run TestSavedConsensusSample -v .

perfetto-ui:
	python3 ui/build_perfetto.py

release: perfetto-ui all

.PHONY: release-archives release-publish test-release qualify-page
qualify-page:
	node scripts/check_page.mjs

release-archives:
	mkdir -p $(GOCACHE) $(GOTMPDIR)
	python3 scripts/release.py build

release-publish:
	python3 scripts/release.py publish

test-release:
	python3 -m unittest discover -s scripts -p 'test_*.py'
	sh -n ../net-deployment-runbook/04-ops/site/trace/install.sh

qualify-perfetto:
	mkdir -p $(GOCACHE) $(GOTMPDIR)
	GONKACTL_TRACE_REQUIRE_SAMPLE=1 GONKACTL_TRACE_REQUIRE_UI=1 go test -race -run TestPerfetto -v .

qualify-history:
	test -n "$(HISTORY_ANALYSIS)"
	mkdir -p $(GOCACHE) $(GOTMPDIR)
	GONKACTL_HISTORY_ANALYSIS="$(HISTORY_ANALYSIS)" go test -race -run TestPerfettoExtendedHistoryArtifact -v .

qualify-ui:
	node ui/responsiveness.test.cjs
	node ui/epoch-bands.test.cjs
	node ui/participants.test.cjs
	node ui/matrix.test.mjs
	node ui/causal.test.mjs
	node ui/matrix-i18n.test.mjs
