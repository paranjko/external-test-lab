.PHONY: all build test vet qualify perfetto-ui release qualify-perfetto qualify-history qualify-ui ui-deps demo

export GOWORK := off
export GOCACHE := $(CURDIR)/.cache/go-build
export GOTMPDIR := $(CURDIR)/.cache/go-tmp
export TMPDIR := $(GOTMPDIR)

all: test vet build qualify-ui

ui-deps:
	npm ci --ignore-scripts --no-audit --no-fund

demo: build
	python3 examples/synthetic.py
	./gonkactl-trace report --input .cache/synthetic/dataset.json

build:
	mkdir -p $(GOCACHE) $(GOTMPDIR)
	go build -o gonkactl-trace .

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
