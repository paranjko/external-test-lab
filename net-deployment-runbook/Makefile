SHELLCHECK_VERSION ?= v0.11.0
SHELLCHECK_IMAGE := koalaman/shellcheck:$(SHELLCHECK_VERSION)
SHELL_SCRIPTS := $(shell find . -type f -name '*.sh' -not -path './vendor/*' -print | LC_ALL=C sort)
DEVCONTAINER_CLI ?= npx --yes --loglevel=silent @devcontainers/cli
CLEANROOM_DEVCONTAINER_CONFIG := .devcontainer/cleanroom/devcontainer.json
NODE_HOST_DEVCONTAINER_CONFIG := .devcontainer/node-host/devcontainer.json
BATS ?= bats
BATS_DOCKER_IMAGE ?= gdc-runbook-bats:local
BATS_DIND_IMAGE ?= gdc-runbook-bats-dind:local
cmd ?= bash
authorized_key_file ?=

.PHONY: bats bats-docker bats-dind cleanroom cleanroom-reset node-host node-host-reset node-host-authorize shellcheck site-js site-js-check test edge-integration verify-upstream-profiles install-git-hooks

cleanroom: cleanroom-reset
	@$(DEVCONTAINER_CLI) exec --config $(CLEANROOM_DEVCONTAINER_CONFIG) --workspace-folder . $(cmd)

cleanroom-reset:
	@$(DEVCONTAINER_CLI) up --config $(CLEANROOM_DEVCONTAINER_CONFIG) --workspace-folder . --remove-existing-container

node-host: node-host-reset

node-host-reset:
	@$(DEVCONTAINER_CLI) up --config $(NODE_HOST_DEVCONTAINER_CONFIG) --workspace-folder . --remove-existing-container

node-host-authorize: node-host
	@test -n "$(authorized_key_file)" && test -r "$(authorized_key_file)" || { echo 'set authorized_key_file=/path/to/operator.pub' >&2; exit 2; }
	@cat "$(authorized_key_file)" | $(DEVCONTAINER_CLI) exec --config $(NODE_HOST_DEVCONTAINER_CONFIG) --workspace-folder . sh -ceu 'install -d -m 0700 /root/.ssh; cat >>/root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys'

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
	@./scripts/test-run-lineage-contract.sh
	@./scripts/test-lifecycle-gate-b-contract.sh
	@./scripts/test-join-acceptance-contract.sh
	@./scripts/test-reset-evidence.sh
	@./scripts/test-upgrade-blocked-verdict.sh
	@./scripts/test-upgrade-state-comparison.sh
	@./scripts/test-upgrade-proposal-binding.sh
	@./scripts/test-gateway-continuity-verdict.sh
	@./scripts/test-recovery-readiness-predicate.sh
	@./scripts/test-capture-poc-snapshot.sh
	@node ./scripts/test-gateway-site-state.js
	@node ./scripts/test-software-versions.js
	@./scripts/test-gateway-health-probe.sh
	@./scripts/test-firewall-policy.sh
	@./scripts/test-public-grafana-targets.sh
	@./scripts/test-public-gpu-freshness.sh
	@python3 ./scripts/test-gateway-admission-proxy.py
	@./scripts/test-host-sync-verdict.sh
	@./scripts/test-gateway-reserve-policy.sh
	@./scripts/test-inference-until-ready.sh
	@./scripts/test-gateway-escrow-reconciler.sh
	@./scripts/test-faucet-caddy-config.sh
	@./scripts/test-reconcile-join-bootstrap.sh
	@./scripts/test-public-edge-single-listener.sh
	@./scripts/test-public-homepage-rendered-asset.sh
	@./scripts/test-participant-poc-caddy-config.sh
	@python3 ./scripts/test-devnet-faucet.py
	@./scripts/test-telegram-bot-deployment.sh
	@python3 ./scripts/test-telegram-bot.py
	@./scripts/test-genesis-identity-contract.sh
	@./scripts/test-validator-backup-contract.sh
	@./scripts/test-genesis-role-config.sh
	@./scripts/test-prepare-join-role-config.sh
	@./scripts/test-role-separation.sh
	@./scripts/test-domain-cli.sh
	@./scripts/test-explicit-public-host.sh
	@./scripts/test-cleanroom-contract.sh

edge-integration:
	@./scripts/test-public-edge-static-site.sh

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
