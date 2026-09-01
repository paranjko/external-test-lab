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
site_release_dir ?= $(CURDIR)/.data/site-release
site_publish_prefix ?=
site_revision ?=
deploy_host ?=
deploy_user ?=
map_evidence_dir ?= $(CURDIR)/.data/validator-map-regressions
chrome_bin ?= google-chrome
preview_number ?=
preview_revision ?=
site_origin ?= http://gonka-dev.net

.PHONY: bats bats-docker bats-dind cleanroom cleanroom-reset node-host node-host-reset node-host-authorize shellcheck site-vendor site-js site-js-check test-gateway-site-state test-validator-map test-site-release-paths test-site-publisher test-site-preview-context prepare-static-site publish-site-release remove-site-release verify-site-release verify-site-preview-artifact verify-site-preview-live smoke-site-preview record-site-preview-deployment site-preview-publish-context site-preview-cleanup-context test edge-integration verify-upstream-profiles verify-candidate-workflow install-git-hooks

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

site-vendor:
	@./scripts/install-site-vendor.sh

site-js:
	@./scripts/build-site-js.sh --write

site-js-check:
	@./scripts/build-site-js.sh --check

test-gateway-site-state: site-js-check
	@node ./scripts/test-gateway-site-state.js

test-validator-map: site-vendor site-js-check
	@mkdir -p "$(map_evidence_dir)"
	@CHROME_BIN="$(chrome_bin)" node ./scripts/test-validator-map-fixture.mjs \
		04-ops/site "$(map_evidence_dir)"

prepare-static-site: site-vendor
	@mkdir -p "$(site_release_dir)"
	@rsync -a --exclude src/ 04-ops/site/ "$(site_release_dir)/"
	@SITE_REVISION="$(site_revision)" ./scripts/render-site-revision.sh 04-ops/site/index.html "$(site_release_dir)/index.html"
	@./scripts/build-site-js.sh --output "$(site_release_dir)"
	@rm -f "$(site_release_dir)/config.js"
	@revision="$(site_revision)"; test -n "$$revision" || revision="$$(git rev-parse HEAD)"; ./scripts/render-site-build-info.sh "$(site_release_dir)" "$$revision"
	@test -s "$(site_release_dir)/index.html"
	@test ! -e "$(site_release_dir)/config.js"

publish-site-release:
	@./scripts/site-release.sh publish "$(site_release_dir)" "$(site_publish_prefix)" "$(deploy_host)" "$(deploy_user)"

remove-site-release:
	@./scripts/site-release.sh remove '' "$(site_publish_prefix)" "$(deploy_host)" "$(deploy_user)"

test-site-release-paths:
	@./scripts/test-site-release-paths.sh

test-site-publisher: test-site-preview-context
	@./scripts/test-site-publisher.sh

test-site-preview-context:
	@./scripts/test-site-preview-context.sh

verify-site-release:
	@test -d "$(site_release_dir)" || { echo 'run prepare-static-site first' >&2; exit 2; }
	@GDC_SITE_RENDERED_ASSETS="$(site_release_dir)" ./scripts/verify-public-homepage.sh

verify-site-preview-artifact:
	@./scripts/verify-site-preview-artifact.sh "$(site_release_dir)" "$(preview_revision)"

verify-site-preview-live:
	@./scripts/verify-site-preview-live.sh "$(site_release_dir)" "$(site_publish_prefix)" "$(preview_revision)" "$(site_origin)"

smoke-site-preview:
	@app_digest="$$(sed -n 's/.*"appDigest":"\([0-9a-f]\{64\}\)".*/\1/p' "$(site_release_dir)/site-build.js")"; test -n "$$app_digest"; GDC_EXPECT_SITE_REVISION="$(preview_revision)" GDC_EXPECT_APP_DIGEST="$$app_digest" node ./scripts/capture-homepage-viewport.mjs "$(site_origin)/$(site_publish_prefix)/" 1280 900 "$(site_release_dir).png" 0

record-site-preview-deployment:
	@PREVIEW_NUMBER="$(preview_number)" PREVIEW_REVISION="$(preview_revision)" ./scripts/record-site-preview-deployment.sh

site-preview-publish-context:
	@./scripts/site-preview-context.sh publish

site-preview-cleanup-context:
	@./scripts/site-preview-context.sh cleanup

test: site-js-check
	@python3 ./scripts/test-release-candidate.py
	@python3 ./scripts/test-network-bootstrap.py
	@./scripts/test-network-bootstrap-shell.sh
	@python3 ./scripts/test-pin-candidate-dockerfile.py
	@python3 ./scripts/test-patch-candidate-dapi-dockerfile.py
	@./scripts/test-package-candidate-binary.sh
	@./scripts/test-generate-candidate-binary-sbom.sh
	@./scripts/test-write-upgrade-marker.sh
	@./scripts/test-upgrade-target-binding.sh
	@./scripts/test-verify-candidate-release-target.sh
	@./scripts/test-candidate-workflow.sh
	@./scripts/test-v0216-hash-dapi-candidate.sh
	@./scripts/test-composition-manifest.sh
	@./scripts/test-devshard-governance-proposal-selection.sh
	@./scripts/test-fetch-governance-proposals.sh
	@./scripts/test-governance-vote-evidence.sh
	@./scripts/test-validate-devshard-governance-protocols.sh
	@./scripts/test-verify-devshard-archive.sh
	@./scripts/test-verify-approved-devshard-version.sh
	@./scripts/test-candidate-gateway-compose.sh
	@./scripts/test-build-gateway-image.sh
	@./scripts/test-gdc-home.sh
	@./scripts/test-ensure-inferenced-cli-output.sh
	@./scripts/test-gdc-github-report.sh
	@./scripts/test-diagnostic-envelope.sh
	@./scripts/test-phase-diagnostic-adapter.sh
	@./scripts/test-classify-join-state.sh
	@bash ./scripts/test-host-join-profile-resolution.sh
	@./scripts/test-host-reset-no-env.sh
	@./scripts/verify-release-profiles.sh
	@./scripts/test-profiles.sh
	@./scripts/test-network-verify-identity-resolution.sh
	@./scripts/test-phase-verify-broker-models.sh
	@./scripts/test-deployed-ml-evidence.sh
	@./scripts/test-participant-state.sh
	@./scripts/test-runtime-identity.sh
	@./scripts/test-validation-weight-evidence.sh
	@./scripts/test-run-lineage-contract.sh
	@./scripts/test-lifecycle-gate-b-contract.sh
	@./scripts/test-public-upgrade-candidate-cli.sh
	@./scripts/test-join-acceptance-contract.sh
	@./scripts/test-reset-evidence.sh
	@./scripts/test-upgrade-blocked-verdict.sh
	@./scripts/test-upgrade-state-comparison.sh
	@./scripts/test-upgrade-proposal-binding.sh
	@./scripts/test-gateway-continuity-verdict.sh
	@./scripts/test-recovery-readiness-predicate.sh
	@./scripts/test-capture-poc-snapshot.sh
	@$(MAKE) test-gateway-site-state
	@$(MAKE) test-site-release-paths test-site-publisher
	@node ./scripts/test-software-versions.js
	@./scripts/test-gateway-health-probe.sh
	@./scripts/test-gateway-admission-deployment.sh
	@./scripts/test-suspend-gateway-admission.sh
	@./scripts/test-firewall-policy.sh
	@./scripts/test-public-grafana-targets.sh
	@./scripts/test-public-gpu-freshness.sh
	@python3 ./scripts/test-gateway-admission-observer.py
	@python3 ./scripts/test-gateway-admission-proxy.py
	@./scripts/test-host-sync-verdict.sh
	@./scripts/test-ensure-account-balance.sh
	@./scripts/test-gateway-reserve-policy.sh
	@./scripts/test-select-compatible-gateway-escrows.sh
	@./scripts/test-inference-until-ready.sh
	@./scripts/test-gateway-escrow-reconciler.sh
	@./scripts/test-faucet-caddy-config.sh
	@./scripts/test-public-edge-single-listener.sh
	@./scripts/test-public-homepage-rendered-asset.sh
	@./scripts/test-participant-poc-caddy-config.sh
	@python3 ./scripts/test-devnet-faucet.py
	@./scripts/test-telegram-bot-deployment.sh
	@./scripts/test-telegram-consumer-probe-loop.sh
	@python3 ./scripts/test-telegram-bot.py
	@./scripts/test-genesis-identity-contract.sh
	@./scripts/test-validator-backup-contract.sh
	@./scripts/test-validator-identity-restore-command.sh
	@./scripts/test-running-host-deployment-secrets.sh
	@./scripts/test-running-host-recovery-state.sh
	@./scripts/test-running-host-recovery-publication.sh
	@./scripts/test-running-host-recovery-orchestration.sh
	@./scripts/test-genesis-role-config.sh
	@./scripts/test-prepare-join-role-config.sh
	@./scripts/test-role-separation.sh
	@./scripts/test-domain-cli.sh
	@./scripts/test-explicit-public-host.sh
	@./scripts/test-cleanroom-contract.sh

verify-candidate-workflow:
	@./scripts/test-candidate-workflow.sh

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
