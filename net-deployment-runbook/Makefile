SHELLCHECK_VERSION ?= v0.11.0
SHELLCHECK_IMAGE := koalaman/shellcheck:$(SHELLCHECK_VERSION)
SHELL_SCRIPTS := $(shell find . -type f -name '*.sh' -not -path './vendor/*' -print | LC_ALL=C sort)
DEVCONTAINER_CLI ?= npx --yes --loglevel=silent @devcontainers/cli
BATS ?= bats
BATS_DOCKER_IMAGE ?= gdc-runbook-bats:local
BATS_DIND_IMAGE ?= gdc-runbook-bats-dind:local
cmd ?= bash

.PHONY: bats bats-docker bats-dind cleanroom cleanroom-fresh cleanroom-reset shellcheck site-js site-js-check test verify-upstream-profiles install-git-hooks

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
	@./scripts/test-runtime-identity.sh
	@./scripts/test-validation-weight-evidence.sh
	@./scripts/test-join-acceptance-contract.sh
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
	@./scripts/test-explicit-public-host.sh
	@./scripts/test-cleanroom-contract.sh

# Bats remains test-only. These two targets exercise the JOIN contracts in a
# disposable host-shaped container; no production host, key or GPU is used.
bats:
	@$(BATS) test

bats-docker:
	@docker build --file test/Dockerfile --tag $(BATS_DOCKER_IMAGE) .
	@docker run --rm --user root -e GDC_BATS_CONTAINER=true $(BATS_DOCKER_IMAGE) test

bats-dind:
	@docker build --file test/Dockerfile.dind --tag $(BATS_DIND_IMAGE) .
	@docker run --rm --privileged -e GDC_BATS_CONTAINER=true -e GDC_BATS_DIND=true $(BATS_DIND_IMAGE) test
