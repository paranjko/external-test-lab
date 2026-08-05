SHELLCHECK_VERSION ?= v0.11.0
SHELLCHECK_IMAGE := koalaman/shellcheck:$(SHELLCHECK_VERSION)
SHELL_SCRIPTS := $(shell find . -type f -name '*.sh' -not -path './vendor/*' -print | LC_ALL=C sort)

.PHONY: shellcheck test

shellcheck:
	@docker run --rm \
		--volume "$(CURDIR):/mnt:ro" \
		--workdir /mnt \
		$(SHELLCHECK_IMAGE) \
		--external-sources \
		--severity=warning \
		$(SHELL_SCRIPTS)

test:
	@./scripts/test-profiles.sh
