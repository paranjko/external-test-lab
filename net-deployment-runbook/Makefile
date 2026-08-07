SHELLCHECK_VERSION ?= v0.11.0
SHELLCHECK_IMAGE := koalaman/shellcheck:$(SHELLCHECK_VERSION)
SHELL_SCRIPTS := $(shell find . -type f -name '*.sh' -not -path './vendor/*' -print | LC_ALL=C sort)

.PHONY: shellcheck test verify-upstream-profiles

verify-upstream-profiles:
	@./scripts/verify-release-profiles.sh

shellcheck:
	@docker run --rm \
		--volume "$(CURDIR):/mnt:ro" \
		--workdir /mnt \
		$(SHELLCHECK_IMAGE) \
		--external-sources \
		--severity=warning \
		$(SHELL_SCRIPTS)

test:
	@./scripts/verify-release-profiles.sh
	@./scripts/test-profiles.sh
	@./scripts/test-participant-state.sh
	@./scripts/test-reset-evidence.sh
	@./scripts/test-upgrade-blocked-verdict.sh
	@./scripts/test-upgrade-state-comparison.sh
	@./scripts/test-gateway-continuity-verdict.sh
	@node ./scripts/test-gateway-site-state.js
	@./scripts/test-gateway-health-probe.sh
	@./scripts/test-genesis-identity-contract.sh
