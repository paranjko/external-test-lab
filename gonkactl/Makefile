GO ?= go
export GOTOOLCHAIN := local

.PHONY: all check toolchain portable-env fmt fmt-check test vet race build smoke

all: check

# Source-snapshot checks only; this is not the recovery/JOIN acceptance gate.
check: fmt-check test vet race smoke

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
	$(GO) build -trimpath -o build/gonkactl ./cmd/gonkactl

smoke: build
	./build/gonkactl --help
	./build/gonkactl version
