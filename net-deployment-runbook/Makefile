SHELLCHECK_VERSION ?= v0.11.0
SHELLCHECK_IMAGE := koalaman/shellcheck:$(SHELLCHECK_VERSION)
SHELL_SCRIPTS := $(shell find . -type f -name '*.sh' -not -path './vendor/*' -print | LC_ALL=C sort)
DEVCONTAINER_CLI ?= npx --yes --loglevel=silent @devcontainers/cli
cmd ?= bash

.PHONY: cleanroom cleanroom-fresh cleanroom-reset shellcheck site-js site-js-check test verify-upstream-profiles install-git-hooks

cleanroom: cleanroom-reset
	@$(DEVCONTAINER_CLI) exec --workspace-folder . $(cmd)

cleanroom-fresh: cleanroom

cleanroom-reset:
	@$(DEVCONTAINER_CLI) up --workspace-folder . --remove-existing-container

install-git-hooks:
	@git config core.hooksPath .githooks
	@echo 'Git hooks enabled from .githooks'

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

site-js:
	@./scripts/build-site-js.sh --write

site-js-check:
	@./scripts/build-site-js.sh --check

test:
	@./scripts/build-site-js.sh --check
	@./scripts/test-gdc-home.sh
	@./scripts/test-host-reset-no-env.sh
	@./scripts/verify-release-profiles.sh
	@./scripts/test-profiles.sh
	@./scripts/test-participant-state.sh
	@./scripts/test-reset-evidence.sh
	@./scripts/test-upgrade-blocked-verdict.sh
	@./scripts/test-upgrade-state-comparison.sh
	@./scripts/test-upgrade-proposal-binding.sh
	@./scripts/test-gateway-continuity-verdict.sh
	@node ./scripts/test-gateway-site-state.js
	@node ./scripts/test-software-versions.js
	@./scripts/test-gateway-health-probe.sh
	@./scripts/test-gateway-escrow-reconciler.sh
	@./scripts/test-faucet-caddy-config.sh
	@python3 ./scripts/test-devnet-faucet.py
	@./scripts/test-telegram-bot-deployment.sh
	@python3 ./scripts/test-telegram-bot.py
	@./scripts/test-genesis-identity-contract.sh
	@./scripts/test-genesis-role-config.sh
	@./scripts/test-role-separation.sh
	@./scripts/test-domain-cli.sh
