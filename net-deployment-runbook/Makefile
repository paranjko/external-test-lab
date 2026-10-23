SHELLCHECK_VERSION ?= v0.11.0
SHELLCHECK_IMAGE := koalaman/shellcheck:$(SHELLCHECK_VERSION)

SHELL_SCRIPTS := $(shell find . -path './vendor' -prune -o -path './.data' -prune -o -type f -name '*.sh' -print | LC_ALL=C sort)
shellcheck_shard ?= 0
shellcheck_shards ?= 1
DEVCONTAINER_CLI ?= npx --yes --loglevel=silent @devcontainers/cli
# Docker Desktop for Mac cannot bind-mount the launchd ssh-agent socket that
# $SSH_AUTH_SOCK points to; it exposes the host agent at a fixed path inside
# its VM instead. The devcontainer mounts ${localEnv:SSH_AUTH_SOCK}, so point
# it there on macOS. Override CLEANROOM_SSH_AUTH_SOCK for other setups.
CLEANROOM_SSH_AUTH_SOCK ?= /run/host-services/ssh-auth.sock
ifeq ($(shell uname -s),Darwin)
cleanroom cleanroom-reset cleanroom-shell: export SSH_AUTH_SOCK := $(CLEANROOM_SSH_AUTH_SOCK)
endif
CLEANROOM_DEVCONTAINER_CONFIG := .devcontainer/cleanroom/devcontainer.json
NODE_HOST_DEVCONTAINER_CONFIG := .devcontainer/node-host/devcontainer.json
BATS ?= bats
BATS_DOCKER_IMAGE ?= gdc-runbook-bats:local
BATS_DIND_IMAGE ?= gdc-runbook-bats-dind:local
cmd ?= bash
upstream_source ?= $(CURDIR)/.data/upstream/gonka
authorized_key_file ?=
site_release_dir ?= $(CURDIR)/.data/site-release
site_publish_prefix ?=
site_revision ?=
deploy_host ?=
deploy_user ?=
map_evidence_dir ?= $(CURDIR)/.data/validator-map-regressions
chrome_bin ?= google-chrome
site_serve_host ?= 127.0.0.1
site_serve_port ?= 8080
site_serve_origin ?= https://gonka-dev.net
preview_number ?=
preview_revision ?=
preview_backend_image ?=
preview_source_repository ?= $(CURDIR)/..
preview_inventory ?= $(CURDIR)/../ops/preview/status-renderer-inventory.env
preview_backend_dir ?= $(site_release_dir)-backend
preview_base_revision ?=
site_origin ?= https://gonka-dev.net
preview_origin ?= https://preview.gonka-dev.net
python_test_venv ?= $(CURDIR)/.python-test-venv
python_test ?= $(python_test_venv)/bin/python
site_preview_expected_card_count ?= 0
site_preview_expected_node_states ?=

.PHONY: bats bats-docker bats-docker-image bats-dind test-join-cleanroom test-join-dind test-recovery-contract test-recovery-rehearsal cleanroom cleanroom-reset cleanroom-shell node-host node-host-reset node-host-authorize shellcheck site-vendor site-js site-js-check site-serve test-site-serve site-host-requirements-check test-browser-devtools test-gateway-site-state test-network-selection test-validator-map test-site-release-paths test-site-release-verifier test-site-publisher test-site-preview-context test-site-preview-live test-site-preview-plan test-site-preview-generation test-site-preview-endpoints test-site-preview-platform test-preview-isolation test-preview-lifecycle test-preview-provision test-preview-status-renderer test-preview-frontend-builder test-isolated-preview-ci test-isolated-preview-ci-artifact test-record-site-preview-deployment test-verify-isolated-site-preview-live test-isolated-preview-runtime-config test-isolated-preview-publish test-prepare-isolated-preview-composition test-prepare-isolated-site-preview-artifact test-prepare-public-preview-inventory test-node-observation-guard test-edge-install-ownership prepare-static-site prepare-site-preview-artifact prepare-isolated-site-preview-artifact prepare-isolated-preview-ci prepare-isolated-preview-ci-artifact write-isolated-preview-deploy-env publish-site-release publish-site-preview publish-isolated-site-preview publish-isolated-preview-ci rollback-site-preview remove-site-release remove-isolated-site-preview verify-site-release verify-site-preview-artifact verify-isolated-preview-ci-artifact verify-isolated-site-preview-live verify-site-preview-live verify-site-preview-endpoints smoke-site-preview record-site-preview-deployment site-preview-publish-context site-preview-cleanup-context test test-command-dependency-contract test-verify-post-sync-join-state test-verify-post-sync-join-state-layouts test-network-ml-endpoints edge-integration verify-upstream-profiles verify-candidate-workflow install-git-hooks test-amd-mlnode-build test-amd-mlnode-trial test-amd-mlnode-ci-publish amd-mlnode-ci-publish
.PHONY: bats bats-docker bats-dind test-join-cleanroom test-join-dind test-recovery-contract test-recovery-rehearsal cleanroom cleanroom-reset cleanroom-shell node-host node-host-reset node-host-authorize shellcheck site-vendor site-js site-js-check site-host-requirements-check test-browser-devtools test-gateway-site-state test-validator-map test-site-release-paths test-site-release-verifier test-site-publisher test-site-preview-context test-site-preview-live test-site-preview-plan test-site-preview-generation test-site-preview-endpoints test-site-preview-platform test-preview-isolation test-preview-lifecycle test-preview-provision test-preview-status-renderer test-preview-frontend-builder test-isolated-preview-ci test-isolated-preview-ci-artifact test-record-site-preview-deployment test-verify-isolated-site-preview-live test-isolated-preview-runtime-config test-isolated-preview-publish test-prepare-isolated-preview-composition test-prepare-isolated-site-preview-artifact test-prepare-public-preview-inventory test-node-observation-guard test-edge-install-ownership prepare-static-site prepare-site-preview-artifact prepare-isolated-site-preview-artifact prepare-isolated-preview-ci prepare-isolated-preview-ci-artifact write-isolated-preview-deploy-env publish-site-release publish-site-preview publish-isolated-site-preview publish-isolated-preview-ci rollback-site-preview remove-site-release remove-isolated-site-preview verify-site-release verify-site-preview-artifact verify-isolated-preview-ci-artifact verify-isolated-site-preview-live verify-site-preview-live verify-site-preview-endpoints smoke-site-preview record-site-preview-deployment site-preview-publish-context site-preview-cleanup-context test test-command-dependency-contract install-python-test-dependencies test-bifrost-key-broker test-bifrost-protocol-edge test-bifrost-provision test-bifrost-broker-container test-bifrost-pinned-lifecycle test-bifrost-deployment-contract edge-integration verify-upstream-profiles verify-candidate-workflow install-git-hooks test-amd-mlnode-build test-amd-mlnode-trial test-amd-mlnode-ci-publish amd-mlnode-ci-publish

cleanroom: cleanroom-reset
	@$(DEVCONTAINER_CLI) exec --config $(CLEANROOM_DEVCONTAINER_CONFIG) --workspace-folder . $(cmd)

cleanroom-reset:
	@$(DEVCONTAINER_CLI) up --config $(CLEANROOM_DEVCONTAINER_CONFIG) --workspace-folder . --remove-existing-container

cleanroom-shell:
	@$(DEVCONTAINER_CLI) exec --config $(CLEANROOM_DEVCONTAINER_CONFIG) --workspace-folder . $(cmd)

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
	@./scripts/verify-release-profiles.sh "$(upstream_source)"
	@bash ./scripts/verify-bootstrap-upstream.sh "$(upstream_source)"

shellcheck:
	@bash ./scripts/run-shellcheck.sh "$(SHELLCHECK_IMAGE)" "$(shellcheck_shard)" "$(shellcheck_shards)"

# Keep the complete inventory available for shard coverage checks.
.PHONY: shellcheck-files
shellcheck-files:
	@printf '%s\n' $(SHELL_SCRIPTS)

test-amd-mlnode-build:
	@./scripts/test-build-amd-mlnode.sh

.PHONY: test-inspect-devshard-runtime
test-inspect-devshard-runtime:
	@python3 ./scripts/test-inspect-devshard-runtime.py

test-ci-gateways: test-inspect-devshard-runtime

.PHONY: test-devshard-runtime-monitoring
test-devshard-runtime-monitoring:
	@python3 ./scripts/test-devshard-runtime-monitoring.py

test-ci-gateways: test-devshard-runtime-monitoring

.PHONY: test-v6-admission-deployment
.PHONY: test-dapi-version-policy
test-dapi-version-policy:
	@python3 scripts/test-dapi-version-policy.py

test-v6-admission-deployment: bats-docker-image
	@python3 scripts/test-v6-observer-binding.py
	@python3 scripts/test-v6-provider-rebind.py
	@python3 scripts/test-v6-model-migration.py
	@python3 scripts/test-serving-observation-model.py
	@python3 ./scripts/test-render-v6-admission.py
	@docker run --rm --network none --tmpfs /srv/dai:rw,exec -e GDC_TEST_DISPOSABLE_ROOT=true --volume "$(CURDIR):/source:ro" --entrypoint python3 $(BATS_DOCKER_IMAGE) /source/scripts/test-v6-admission-install.py

test-ci-gateways: test-v6-admission-deployment

.PHONY: test-devshard-502-reader
test-devshard-502-reader:
	@python3 ./scripts/test-devshard-502-reader.py

test-devshard-502-fixture-contract: test-devshard-502-reader

.PHONY: test-devshard-cache-policy
test-devshard-cache-policy:
	@python3 ./scripts/test-devshard-cache-policy.py

test-ci-gateways: test-devshard-cache-policy

.PHONY: test-devshard-cache-ledger test-devshard-cache-lifecycle
test-devshard-cache-ledger:
	@python3 ./scripts/test-devshard-cache-ledger.py

test-devshard-cache-lifecycle: test-devshard-cache-ledger
	@python3 ./scripts/test-devshard-cache-drain.py
	@python3 ./scripts/test-devshard-cache-lifecycle.py
	@python3 ./scripts/test-devshard-cache-runtime.py

test-ci-gateways: test-devshard-cache-lifecycle

.PHONY: test-devshard-cache-apply
test-devshard-cache-apply: test-devshard-cache-lifecycle
	@python3 ./scripts/test-devshard-cache-apply.py
	@python3 ./scripts/test-devshard-cache-apply-launcher.py

test-ci-gateways: test-devshard-cache-apply

.PHONY: test-faucet-policy
test-faucet-policy:
	@python3 ./scripts/test-faucet-policy.py

test-ci-gateways: test-faucet-policy

.PHONY: test-faucet-policy-http
test-faucet-policy-http:
	@python3 ./scripts/test-faucet-policy-http.py

test-ci-gateways: test-faucet-policy-http

.PHONY: test-telegram-delivery
test-telegram-delivery: test-gateway-traffic
	@python3 ./scripts/test-telegram-bot.py
	@python3 ./scripts/test-telegram-admission-summary.py

.PHONY: test-gateway-traffic
test-gateway-traffic:
	@python3 ./scripts/test-gateway-traffic.py

test-amd-mlnode-trial:
	@./scripts/test-run-amd-mlnode-trial.sh

test-amd-mlnode-ci-publish:
	@./scripts/test-publish-amd-mlnode-ci.sh

test-network-ml-endpoints:
	@./scripts/test-network-ml-endpoints.sh

amd-mlnode-ci-publish:
	@./scripts/publish-amd-mlnode-ci.sh profiles/amd-mlnode/gfx1201.json

site-vendor:
	@./scripts/install-site-vendor.sh

site-js:
	@./scripts/build-site-js.sh --write

site-js-check:
	@./scripts/build-site-js.sh --check

site-serve: site-vendor site-js
	@node ./scripts/serve-site.mjs 04-ops/site "$(site_serve_host)" "$(site_serve_port)" "$(site_serve_origin)"

test-site-serve:
	@node ./scripts/test-serve-site.mjs

site-host-requirements-check:
	@node ./scripts/verify-devnet-hardware-profile.mjs profiles/devnet-hadware.json 04-ops/site/index.html

test-browser-devtools:
	@node --check ./scripts/capture-homepage-viewport.mjs
	@node ./scripts/test-chrome-devtools.mjs

test-gateway-site-state: site-vendor site-js-check test-browser-devtools test-production-network-browser test-site-snapshot-acceptance
	@node ./scripts/test-gateway-site-state.js

.PHONY: test-stable-gateway-site
test-stable-gateway-site: site-js-check
	@node ./scripts/test-stable-gateway-site.js

test-ci-site: test-stable-gateway-site

.PHONY: test-production-network-browser test-site-snapshot-acceptance test-verify-network-observer verify-network-observer
test-production-network-browser: site-vendor site-js
	@node ./scripts/test-production-network-browser.mjs

test-site-snapshot-acceptance: site-vendor site-js
	@node ./scripts/test-site-snapshot-acceptance.mjs

test-verify-network-observer:
	@node ./scripts/test-verify-network-observer.mjs

verify-network-observer:
	@node ./scripts/verify-network-observer.mjs --base-url "$(site_origin)"

test-network-selection: site-js-check
	@node ./scripts/test-network-selection.js 04-ops/site

test-validator-map: site-vendor site-js site-host-requirements-check
	@mkdir -p "$(map_evidence_dir)"
	@CHROME_BIN="$(chrome_bin)" node ./scripts/test-validator-map-fixture.mjs \
		04-ops/site "$(map_evidence_dir)"

prepare-static-site: site-vendor site-host-requirements-check
	@mkdir -p "$(site_release_dir)"
	@rsync -a --exclude src/ --exclude .gitignore 04-ops/site/ "$(site_release_dir)/"
	@install -m 0755 ../install_inferenced.sh "$(site_release_dir)/install_inferenced.sh"
	@SITE_REVISION="$(site_revision)" ./scripts/render-site-revision.sh 04-ops/site/index.html "$(site_release_dir)/index.html"
	@./scripts/build-site-js.sh --output "$(site_release_dir)"
	@rm -f "$(site_release_dir)/config.js"
	@revision="$(site_revision)"; test -n "$$revision" || revision="$$(git rev-parse HEAD)"; ./scripts/render-site-build-info.sh "$(site_release_dir)" "$$revision"
	@test -s "$(site_release_dir)/index.html"
	@test -x "$(site_release_dir)/install_inferenced.sh"
	@test ! -e "$(site_release_dir)/config.js"

prepare-site-preview-artifact:
	@./scripts/prepare-site-preview-artifact.sh

prepare-isolated-site-preview-artifact:
	@./scripts/prepare-isolated-site-preview-artifact.sh "$(preview_source_repository)" "$(site_release_dir)" "$(preview_base_revision)" "$(site_revision)" "$(preview_inventory)" "$(preview_number)" "$(preview_backend_dir)" "$(preview_backend_image)"

prepare-isolated-preview-ci:
	@./scripts/prepare-isolated-preview-ci.sh

prepare-isolated-preview-ci-artifact:
	@./scripts/prepare-isolated-preview-ci-artifact.sh

write-isolated-preview-deploy-env:
	@./scripts/write-isolated-preview-deploy-env.sh

publish-isolated-preview-ci:
	@./scripts/publish-isolated-preview-ci.sh

publish-site-release:
	@./scripts/site-release.sh publish "$(site_release_dir)" "$(site_publish_prefix)" "$(deploy_host)" "$(deploy_user)"

publish-site-preview:
	@GDC_SITE_PREVIEW_ENV_FILE="$${GDC_SITE_PREVIEW_ENV_FILE:-}" ./scripts/site-release.sh publish-preview "$(site_release_dir)" "$(site_publish_prefix)" "$(deploy_host)" "$(deploy_user)"

publish-isolated-site-preview:
	@GDC_SITE_PREVIEW_ENV_FILE="$${GDC_SITE_PREVIEW_ENV_FILE:-}" ./scripts/isolated-preview-publish.sh publish "$(site_release_dir)" "$(preview_number)" "$(preview_revision)" "$(preview_backend_image)"

rollback-site-preview:
	@GDC_SITE_PREVIEW_ENV_FILE="$${GDC_SITE_PREVIEW_ENV_FILE:-}" ./scripts/site-release.sh rollback-preview '' "$(site_publish_prefix)" "$(deploy_host)" "$(deploy_user)"

remove-site-release:
	@./scripts/site-release.sh remove '' "$(site_publish_prefix)" "$(deploy_host)" "$(deploy_user)"

remove-isolated-site-preview:
	@GDC_SITE_PREVIEW_ENV_FILE="$${GDC_SITE_PREVIEW_ENV_FILE:-}" ./scripts/isolated-preview-publish.sh remove '' "$(preview_number)" "$(preview_revision)"

test-site-release-paths:
	@./scripts/test-site-release-paths.sh

test-site-release-verifier:
	@./scripts/test-site-release-verifier.sh

test-site-publisher: test-site-preview-context test-site-preview-live
	@./scripts/test-site-publisher.sh

test-site-preview-context: test-verify-removed-site-preview-live
	@./scripts/test-site-preview-context.sh

.PHONY: verify-removed-site-preview-live test-verify-removed-site-preview-live
verify-removed-site-preview-live:
	@preview_number="$(preview_number)" bash ./scripts/verify-removed-site-preview-live.sh

test-verify-removed-site-preview-live:
	@bash ./scripts/test-verify-removed-site-preview-live.sh

test-site-preview-live:
	@bash ./scripts/test-site-preview-live.sh

test-site-preview-plan:
	@python3 ./scripts/test-plan-site-preview.py

test-site-preview-generation:
	@./scripts/test-site-preview-generation.sh

test-site-preview-endpoints:
	@./scripts/test-site-preview-endpoints.sh

test-site-preview-platform: site-vendor test-site-release-paths test-site-preview-plan test-site-preview-generation test-site-preview-endpoints test-site-publisher
	@./scripts/test-public-edge-static-site.sh

.PHONY: test-status-openapi test-public-gpu-freshness test-public-edge-static-site test-site-preview-acceptance

test-status-openapi:
	@node ./scripts/test-status-openapi.js

test-public-gpu-freshness:
	@./scripts/test-public-gpu-freshness.sh

test-public-edge-static-site:
	@./scripts/test-public-edge-static-site.sh

test-site-preview-acceptance: site-vendor
	@$(MAKE) test-gateway-site-state test-site-release-paths test-site-preview-plan test-site-preview-generation test-site-preview-endpoints test-site-publisher test-status-openapi
	@node ./scripts/test-software-versions.js
	@./scripts/test-public-gpu-freshness.sh
	@./scripts/test-public-edge-static-site.sh

test-preview-isolation:
	@./scripts/test-preview-isolation.sh

test-preview-lifecycle:
	@./scripts/test-preview-lifecycle.sh

test-preview-provision:
	@./scripts/test-preview-provision.sh

test-preview-status-renderer:
	@./scripts/test-preview-status-renderer.sh

test-preview-frontend-builder:
	@./scripts/test-preview-frontend-builder.sh

test-isolated-preview-ci:
	@./scripts/test-isolated-preview-ci.sh

test-isolated-preview-ci-artifact:
	@./scripts/test-isolated-preview-ci-artifact.sh

test-record-site-preview-deployment:
	@./scripts/test-record-site-preview-deployment.sh

test-verify-isolated-site-preview-live:
	@./scripts/test-verify-isolated-site-preview-live.sh

test-prepare-public-preview-inventory:
	@./scripts/test-prepare-public-preview-inventory.sh

test-node-observation-guard:
	@./scripts/test-node-observation-guard.sh

test-isolated-preview-runtime-config:
	@./scripts/test-isolated-preview-runtime-config.sh

test-prepare-isolated-site-preview-artifact:
	@./scripts/test-prepare-isolated-site-preview-artifact.sh

test-isolated-preview-publish:
	@./scripts/test-isolated-preview-publish.sh

test-prepare-isolated-preview-composition:
	@./scripts/test-prepare-isolated-preview-composition.sh

test-edge-install-ownership:
	@./scripts/test-edge-install-ownership.sh

verify-site-release:
	@test -d "$(site_release_dir)" || { echo 'run prepare-static-site first' >&2; exit 2; }
	@./scripts/verify-site-release.sh "$(site_release_dir)" "$(site_origin)"

verify-site-preview-artifact:
	@./scripts/verify-site-preview-artifact.sh "$(site_release_dir)" "$(preview_revision)"

verify-isolated-preview-ci-artifact:
	@./scripts/verify-isolated-preview-ci-artifact.sh

verify-isolated-site-preview-live:
	@./scripts/verify-isolated-site-preview-live.sh

verify-site-preview-live:
	@./scripts/verify-site-preview-live.sh "$(site_release_dir)" "$(site_publish_prefix)" "$(preview_revision)" "$(site_origin)"

verify-site-preview-endpoints:
	@./scripts/verify-site-preview-endpoints.sh "$(site_release_dir)" "$(site_publish_prefix)" "$(site_origin)"

.PHONY: smoke-site-preview-acceptance

smoke-site-preview-acceptance:
	@app_digest="$$(sed -n 's/.*"appDigest":"\([0-9a-f]\{64\}\)".*/\1/p' "$(site_release_dir)/site-build.js")"; test -n "$$app_digest"; GDC_EXPECT_SITE_REVISION="$(preview_revision)" GDC_EXPECT_APP_DIGEST="$$app_digest" GDC_EXPECT_STATUS_PREFIX="/$(preview_number)/status/" GDC_EXPECT_NETWORK_SNAPSHOT=true GDC_EXPECT_GATEWAY_STATE=UNAVAILABLE GDC_EXPECT_CARD_COUNT="$(site_preview_expected_card_count)" GDC_EXPECT_NODE_STATES="$(site_preview_expected_node_states)" node ./scripts/capture-homepage-viewport.mjs "$(preview_origin)/$(preview_number)/" 1280 900 "$(site_release_dir).png" 0

smoke-site-preview:
	@app_digest="$$(sed -n 's/.*"appDigest":"\([0-9a-f]\{64\}\)".*/\1/p' "$(site_release_dir)/site-build.js")"; test -n "$$app_digest"; GDC_EXPECT_SITE_REVISION="$(preview_revision)" GDC_EXPECT_APP_DIGEST="$$app_digest" node ./scripts/capture-homepage-viewport.mjs "$(site_origin)/$(site_publish_prefix)/" 1280 900 "$(site_release_dir).png" 0

record-site-preview-deployment:
	@PREVIEW_NUMBER="$(preview_number)" PREVIEW_REVISION="$(preview_revision)" ./scripts/record-site-preview-deployment.sh

site-preview-publish-context:
	@./scripts/site-preview-context.sh publish

site-preview-cleanup-context:
	@./scripts/site-preview-context.sh cleanup

.PHONY: test-devshard-two-gateways test-devshard-502-fixture-contract test-devshard-workload test-devshard-transport test-devshard-observe test-devshard-public-workload
test-devshard-two-gateways: test-devshard-workload
	@python3 ./scripts/test-devshard-two-gateways.py
	@python3 ./scripts/test-devshard-settings.py

test-devshard-workload: test-devshard-transport test-devshard-observe test-devshard-public-workload
	@python3 ./scripts/test-devshard-workload.py

test-devshard-observe:
	@python3 ./scripts/test-devshard-observe.py

test-devshard-transport:
	@python3 ./scripts/test-devshard-transport.py

test-devshard-public-workload:
	@python3 ./scripts/test-devshard-public-workload.py

test-devshard-502-fixture-contract:
	@python3 ./scripts/test-devshard-502-fixture.py
	@python3 ./scripts/test-devshard-502-pair.py
	@python3 ./scripts/test-devshard-502-exercise.py
	@python3 ./scripts/test-devshard-502-state.py

install-python-test-dependencies:
	@python3 -m venv "$(python_test_venv)"
	@"$(python_test)" -m pip install --disable-pip-version-check --requirement dependencies/python-test-requirements.txt

test-bifrost-key-broker:
	@"$(python_test)" ./scripts/test-bifrost-key-broker.py

test-bifrost-protocol-edge:
	@"$(python_test)" ./scripts/test-bifrost-protocol-edge.py

test-bifrost-provision:
	@"$(python_test)" ./scripts/test-bifrost-provision.py

test-bifrost-broker-container:
	@./scripts/test-bifrost-broker-container.sh

.PHONY: test-bifrost-fake-inference
test-bifrost-fake-inference:
	@python3 ./scripts/test-bifrost-fake-inference.py

test-bifrost-pinned-lifecycle: test-bifrost-fake-inference
	@./scripts/test-bifrost-pinned-lifecycle.sh

test-bifrost-deployment-contract:
	@./scripts/test-bifrost-deployment-contract.sh

test-bifrost-gdc-preview-launcher:
	@./scripts/test-bifrost-gdc-preview-launcher.sh


test-ci-gateways: test-command-dependency-contract test-devshard-two-gateways test-devshard-502-fixture-contract test-gateway-settings-deployment test-monitoring-firewall-deployment test-install-inferenced test-bifrost-key-broker test-bifrost-protocol-edge test-bifrost-provision test-bifrost-broker-container test-bifrost-pinned-lifecycle test-bifrost-deployment-contract test-bifrost-gdc-preview-launcher

# Each CI group runs sequentially in its own checkout. In particular, site
# builders and fixed-port HTTP fixtures must not share a parallel checkout.
RUNBOOK_CI_GROUPS := bootstrap core site join gateways
HOST_LIFECYCLE_SHARED_TESTS := test-command-results test-verify-lineage-trust-fresh-boundaries test-verify-state-sync-config test-wait-state-sync-canary test-post-sync-join-helper test-verify-post-sync-join-state test-verify-post-sync-join-state-layouts test-reset-then-join-entry test-join-resume-new-canonical test-join-resume-post-sync-shared test-join-resume-restore-post-sync-refusal test-join-resume-restore-membership test-join-resume-membership-funding test-phase-ml-add-ownership test-node-container-control test-prepare-accelerator-binding test-node-container-lending-docker test-ml-lend-generic-pairs test-ml-lending-two-hosts test-detach-network-ml-host test-validator-ml-lifecycle
.PHONY: $(addprefix test-ci-,$(RUNBOOK_CI_GROUPS)) test-ci-layout
test: test-ci-layout $(addprefix test-ci-,$(RUNBOOK_CI_GROUPS)) $(HOST_LIFECYCLE_SHARED_TESTS) test-host-upgrade-lifecycle test-clean-join-target-lifecycle

test-ci-layout:
	@python3 ./scripts/test-runbook-ci.py

test-ci-bootstrap: test-command-dependency-contract test-bootstrap-publication test-network-bootstrap test-core-release-profile test-recovery-contract test-participants-proxy test-network-observer test-registration-failover test-proxy-ingress-layouts test-reconcile-proxy-ingress-remote

test-ci-core: test-command-dependency-contract test-ci-route test-devshard-release test-devshard-artifacts test-gonka-pr-unified-release test-ci-release-helpers test-host-models test-host-upgrade test-ml-callback test-start-ml-transport test-genesis-config-import test-genesis-config-builder test-genesis-candidate test-genesis-software test-verify-genesis test-profile-model-args test-host-special-cli test-model-worker-add test-model-primary-reconfigure test-ops-faucet-isolation test-genesis-runtime-install test-repair-genesis-startup test-replace-unstarted-genesis test-new-genesis-reset-join-gate test-clean-join-empty-generation-parent test-reset-genesis-host test-shared-gpu-layout-renderer
	@bash ./scripts/test-node-container-lending.sh
	@bash ./scripts/test-upstream-isolation.sh
	@python3 ./scripts/test-release-candidate.py
	@python3 ./scripts/test-patch-candidate-dapi-dockerfile.py
	@./scripts/test-package-candidate-binary.sh
	@./scripts/test-generate-candidate-binary-sbom.sh
	@./scripts/test-write-upgrade-marker.sh
	@./scripts/test-upgrade-target-binding.sh
	@./scripts/test-verify-candidate-release-target.sh
	@./scripts/test-candidate-workflow.sh
	@./scripts/test-candidate-release-notes-template.sh
	@python3 ./scripts/test-render-candidate-release-notes.py
	@./scripts/test-v0216-hash-dapi-candidate.sh
	@./scripts/test-composition-manifest.sh
	@./scripts/test-devshard-governance-proposal-selection.sh
	@./scripts/test-fetch-governance-proposals.sh
	@./scripts/test-governance-vote-evidence.sh
	@./scripts/test-validate-devshard-governance-protocols.sh
	@./scripts/test-verify-approved-devshard-version.sh
	@./scripts/test-candidate-gateway-compose.sh
	@./scripts/test-build-gateway-image.sh
	@./scripts/test-build-amd-mlnode.sh
	@./scripts/test-run-amd-mlnode-trial.sh
	@./scripts/test-publish-amd-mlnode-ci.sh
	@./scripts/test-gdc-home.sh
	@./scripts/test-ensure-inferenced-cli-output.sh
	@bash ./scripts/test-inferenced-config-isolation.sh
	@./scripts/test-ensure-warm-key.sh
	@./scripts/test-launcher-root-contract.sh
	@./scripts/test-gdc-github-report.sh
	@./scripts/test-gdc-github-signer-diagnostic.sh
	@./scripts/test-monitoring-inventory-drift.sh
	@./scripts/test-diagnostic-envelope.sh
	@./scripts/test-diagnostic-summaries-publishable.sh
	@./scripts/test-phase-diagnostic-adapter.sh
	@./scripts/test-classify-join-state.sh
	@./scripts/test-classify-join-reentry.sh
	@./scripts/test-join-identity-diagnostics.sh
	@./scripts/test-join-existing-participant-rebind.sh
	@./scripts/test-replace-retained-validator-identity.sh
	@./scripts/test-authorize-retained-validator-replacement.sh
	@./scripts/test-join-refusal-diagnostics.sh
	@./scripts/test-join-blocklist-preflight.sh
	@./scripts/test-join-run-log-lifecycle.sh
	@./scripts/test-join-signer-diagnostic.sh
	@./scripts/test-join-ml-qualification.sh
	@bash ./scripts/test-ml-qualification-evidence.sh
	@bash ./scripts/test-ml-qualification-failure.sh
	@python3 scripts/test-prefetch-ml.py
	@bash ./scripts/test-host-join-profile-resolution.sh
	@./scripts/test-host-reset-no-env.sh
	@./scripts/test-host-identity-layout-probe.sh
	@./scripts/test-profiles.sh
	@./scripts/test-official-devshard-profile.sh
	@./scripts/test-api-entrypoint.sh
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

test-ci-site: test-command-dependency-contract test-isolated-preview-ci-artifact site-js-check test-network-selection site-host-requirements-check test-site-serve test-gateway-site-state test-site-release-verifier test-site-preview-platform
	@node ./scripts/test-software-versions.js
	@./scripts/test-gateway-health-probe.sh
	@./scripts/test-public-traffic-readiness.sh
	@./scripts/test-gateway-admission-deployment.sh
	@./scripts/test-suspend-gateway-admission.sh
	@./scripts/test-firewall-policy.sh
	@./scripts/test-join-early-host-readiness.sh
	@./scripts/test-prepare-nvidia-kernel-modules.sh
	@./scripts/test-prepare-amd-rocm.sh
	@./scripts/test-public-grafana-targets.sh
	@./scripts/test-dashboard-generator.sh
	@./scripts/test-public-gpu-freshness.sh
	@python3 ./scripts/test-gateway-admission-observer.py
	@$(MAKE) test-gateway-readiness test-gateway-readiness-lifecycle
	@python3 ./scripts/test-gateway-admission-proxy.py
	@python3 ./scripts/test-gateway-route-proxy.py
	@./scripts/test-gateway-migration.sh
	@bash ./scripts/test-gateway-poc-windows.sh
	@./scripts/test-host-sync-verdict.sh
	@./scripts/test-ensure-account-balance.sh
	@./scripts/test-gateway-reserve-policy.sh
	@./scripts/test-select-compatible-gateway-escrows.sh
	@./scripts/test-inference-until-ready.sh
	@./scripts/test-gateway-escrow-reconciler.sh
	@./scripts/test-faucet-caddy-config.sh
	@./scripts/test-claim-devnet-faucet.sh
	@./scripts/test-participant-edge-start.sh
	@./scripts/test-public-edge-single-listener.sh
	@./scripts/test-public-homepage-rendered-asset.sh
	@./scripts/test-participant-poc-caddy-config.sh
	@python3 ./scripts/test-devnet-faucet.py
	@./scripts/test-telegram-bot-deployment.sh
	@$(MAKE) test-telegram-registration-lifecycle
	@./scripts/test-telegram-consumer-probe-loop.sh
	@$(MAKE) test-telegram-delivery

test-ci-join: test-command-dependency-contract test-register-join-monitoring-targets test-join-monitoring-runtime test-clean-join-target-lifecycle test-phase-join-full-sync-export test-compose-optional-second-rpc test-join-identity-ready-resume-dind
	@bash ./scripts/test-join-model-selection.sh
	@./scripts/test-genesis-identity-contract.sh
	@./scripts/test-host-backup-context.sh
	@./scripts/test-inspect-accelerator.sh
	@./scripts/test-accelerator-profile.sh
	@./scripts/test-amd-preflight-order.sh
	@./scripts/test-select-nvidia-driver.sh
	@./scripts/test-validator-backup-contract.sh
	@./scripts/test-observe-network-composition.sh
	@./scripts/test-observe-network-state.sh
	@./scripts/test-select-runtime-majority.sh
	@./scripts/test-observe-network-peer-discovery.sh
	@./scripts/test-probe-public-peer.sh
	@./scripts/test-join-profile.sh
	@./scripts/test-join-transition-receipts.sh
	@./scripts/test-read-join-mnemonic.sh
	@./scripts/test-resolve-join-components.sh
	@./scripts/test-resolve-join-profile.sh
	@./scripts/test-host-join-plan.sh
	@./scripts/test-join-preflight-diagnostics.sh
	@./scripts/test-join-lineage-preflight.sh
	@./scripts/test-join-lineage-quorum-adversarial.sh
	@./scripts/test-host-join-state-sync.sh
	@bash ./scripts/test-validator-backup-layout.sh
	@./scripts/test-verify-canonical-join-state.sh
	@./scripts/test-host-join-resume-canonical.sh
	@./scripts/test-recover-incident-flat-layout.sh
	@./scripts/test-host-join-resume-signer-readback.sh
	@./scripts/test-phase-ml-attach-completion.sh
	@./scripts/test-network-ml-endpoints.sh
	@./scripts/test-resolve-reset-dai-backup.sh
	@./scripts/test-verify-inactive-validator-key.sh
	@./scripts/test-verify-complete-join-state.sh
	@./scripts/test-promote-state-sync-generation.sh
	@./scripts/test-record-state-sync-canary.sh
	@./scripts/test-verify-tmkms-signing-state.sh
	@bash ./scripts/test-consensus-recovery-preparation.sh
	@bash ./scripts/test-consensus-signer-install.sh
	@bash ./scripts/test-consensus-recovery-inputs.sh
	@bash ./scripts/test-consensus-signer-recovery.sh
	@bash ./scripts/test-phase-consensus-signer-recovery.sh
	@./scripts/test-tmkms-state-schema-agreement.sh
	@./scripts/test-signer-activation-gate.sh
	@./scripts/test-verify-participant-validator-key.sh
	@./scripts/test-join-registered-key-refusal.sh
	@./scripts/test-init-identity-restore-diagnostics.sh
	@./scripts/test-collect-identities-transport-resume.sh
	@./scripts/test-cleanroom-no-python-restore.sh
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

test-command-dependency-contract:
	@./scripts/test-command-dependency-contract.sh

.PHONY: test-genesis-config-import test-genesis-config-builder test-genesis-candidate test-genesis-software test-verify-genesis test-profile-model-args test-host-special-cli test-model-worker-add test-model-primary-reconfigure test-ops-faucet-isolation test-phase-join-full-sync-export test-compose-optional-second-rpc test-join-identity-ready-resume test-join-identity-ready-resume-dind test-repair-genesis-startup test-replace-unstarted-genesis test-new-genesis-reset-join-gate test-clean-join-empty-generation-parent test-reset-genesis-host test-reset-genesis-host-root test-shared-gpu-layout-renderer
test-genesis-config-import:
	@bash ./scripts/test-genesis-config-import.sh

test-genesis-config-builder:
	@bash ./scripts/test-genesis-config-builder.sh

test-genesis-candidate:
	@bash ./scripts/test-genesis-candidate.sh

test-genesis-software:
	@bash ./scripts/test-genesis-software.sh

test-verify-genesis:
	@bash ./scripts/test-verify-genesis.sh

test-profile-model-args:
	@bash ./scripts/test-profile-model-args.sh

test-host-special-cli:
	@bash ./scripts/test-host-special-cli.sh

test-model-worker-add:
	@bash ./scripts/test-model-worker-add.sh

test-model-primary-reconfigure:
	@bash ./scripts/test-model-primary-reconfigure.sh

test-ops-faucet-isolation:
	@bash ./scripts/test-ops-faucet-isolation.sh

test-phase-join-full-sync-export:
	@bash ./scripts/test-phase-join-full-sync-export.sh

test-join-identity-ready-resume:
	@bash ./scripts/test-join-identity-ready-resume.sh

test-join-identity-ready-resume-dind:
	@docker build --file test/Dockerfile.host-upgrade --tag gdc-clean-target-dind:local ..
	@docker run --rm --entrypoint bash gdc-clean-target-dind:local scripts/test-join-identity-ready-resume.sh

test-compose-optional-second-rpc:
	@bash ./scripts/test-compose-optional-second-rpc.sh

test-repair-genesis-startup:
	@bash ./scripts/test-repair-genesis-startup.sh

test-replace-unstarted-genesis:
	@bash ./scripts/test-replace-unstarted-genesis.sh

test-new-genesis-reset-join-gate:
	@bash ./scripts/test-new-genesis-reset-join-gate.sh

test-clean-join-empty-generation-parent:
	@bash ./scripts/test-clean-join-empty-generation-parent.sh

test-shared-gpu-layout-renderer:
	@bash ../devnet/model-layouts/shared-gpu/test.sh

test-gateway-settings-deployment:
	@./scripts/test-gateway-settings-deployment.sh

.PHONY: test-gateway-readiness test-gateway-readiness-lifecycle
test-gateway-readiness:
	@python3 ./scripts/test-gateway-readiness.py

test-gateway-readiness-lifecycle:
	@python3 ./scripts/test-gateway-readiness-lifecycle.py

test-gateway-observation:
	bash scripts/test-gateway-observation.sh

test-gateway-observation-runtime:
	bash scripts/test-gateway-observation-runtime.sh

test-monitoring-target-reconcile:
	bash scripts/test-monitoring-target-reconcile.sh

test-monitoring-firewall-deployment: test-monitoring-target-reconcile test-gateway-observation test-gateway-observation-runtime
	@./scripts/test-monitoring-firewall-deployment.sh

test-install-inferenced:
	@./scripts/test-install-inferenced.sh

.PHONY: test-host-models
.PHONY: test-host-upgrade test-host-upgrade-lifecycle test-clean-join-target-lifecycle
test-host-upgrade:
	@bash ./scripts/test-host-upgrade.sh

test-host-upgrade-lifecycle:
	@docker build --file test/Dockerfile.host-upgrade --tag gdc-host-upgrade-test:local ..
	@docker run --rm --privileged -e GDC_HOST_UPGRADE_DIND=true --entrypoint bash gdc-host-upgrade-test:local scripts/test-host-upgrade-lifecycle.sh

test-clean-join-target-lifecycle:
	@docker build --file test/Dockerfile.host-upgrade --tag gdc-clean-target-dind:local ..
	@docker run --rm --privileged -e GDC_CLEAN_TARGET_DIND=true -e DOCKER_DRIVER=vfs --entrypoint bash gdc-clean-target-dind:local scripts/test-join-target-clean-dind.sh

test-host-models: bats-docker-image
	@docker run --rm --network none --tmpfs /srv/dai:rw,exec -e GDC_HOST_MODELS_FIXTURE=true --entrypoint python3 $(BATS_DOCKER_IMAGE) scripts/test-host-models.py

test-verify-post-sync-join-state:
	@./scripts/test-verify-post-sync-join-state.sh

# This executes the remote post-sync body in an isolated container. It is
# separate from the hermetic unit fixture because it exercises /srv/dai's
# flat promoted pointer and proves a legacy directory fails closed.
test-verify-post-sync-join-state-layouts:
	@./scripts/test-verify-post-sync-join-state-layouts.sh

verify-candidate-workflow:
	@./scripts/test-candidate-workflow.sh

edge-integration: site-vendor
	@./scripts/test-public-edge-static-site.sh
	@python3 ./scripts/test-devshard-runtime-status.py

# The Bootstrap installer is only exercised in an ephemeral container with a
# new /srv/dai mount, never against an operator Host
.PHONY: test-bootstrap-install test-bootstrap-install-root test-genesis-runtime-install test-genesis-runtime-install-root
test-bootstrap-install:
	@docker build --file test/Dockerfile.bootstrap --tag gdc-bootstrap-install-test ..
	@docker run --rm --network none --tmpfs /srv/dai:rw,exec -e GDC_TEST_DISPOSABLE_ROOT=true gdc-bootstrap-install-test

test-bootstrap-install-root:
	@python3 ./scripts/test-bootstrap-install.py

test-genesis-runtime-install:
	@docker build --file test/Dockerfile.bootstrap --tag gdc-genesis-runtime-install-test ..
	@docker run --rm --network none --tmpfs /srv/dai:rw,exec -e GDC_TEST_DISPOSABLE_ROOT=true --entrypoint make gdc-genesis-runtime-install-test test-genesis-runtime-install-root

test-genesis-runtime-install-root:
	@bash ./scripts/test-genesis-runtime-install.sh

test-reset-genesis-host:
	@docker build --file test/Dockerfile.bootstrap --tag gdc-genesis-reset-host-test ..
	@docker run --rm --network none --tmpfs /srv:rw,exec -e GDC_TEST_DISPOSABLE_ROOT=true --entrypoint make gdc-genesis-reset-host-test test-reset-genesis-host-root

test-reset-genesis-host-root:
	@bash ./scripts/test-reset-genesis-host.sh

# Bats remains test-only. These two targets exercise the JOIN contracts in a
# disposable host-shaped container; no production host, key or GPU is used.
bats:
	@$(BATS) test

bats-docker-image:
	@docker build --file test/Dockerfile --tag $(BATS_DOCKER_IMAGE) ..

bats-docker: bats-docker-image
	@docker run --rm --user root -e GDC_BATS_CONTAINER=true $(BATS_DOCKER_IMAGE) test

bats-dind:
	@docker build --file test/Dockerfile.dind --tag $(BATS_DIND_IMAGE) ..
	@docker run --rm --privileged -e GDC_BATS_CONTAINER=true -e GDC_BATS_DIND=true $(BATS_DIND_IMAGE) test

# Named JOIN gates stay local and disposable. The cleanroom contract exercises
# the no-Python restore path plus planning with all remote tools poisoned;
# DinD runs the repository's containerised JOIN contracts, including
# test/join_reliability.bats for the promotion, trust, signer and re-entry
# safety contracts.
test-join-cleanroom:
	@./scripts/test-cleanroom-contract.sh
	@./scripts/test-cleanroom-no-python-restore.sh
	@./scripts/test-host-join-plan.sh

test-join-dind: bats-dind

test-recovery-contract: test-recover-incident
	@python3 ./scripts/test-network-recovery-schemas.py
	@./scripts/test-network-recovery-contract.sh

.PHONY: test-recover-incident
.PHONY: bootstrap-schema-dependencies

bootstrap-schema-dependencies:
	@python3 -m pip install --disable-pip-version-check --requirement dependencies/bootstrap-schema-requirements.txt

.PHONY: bootstrap-publication-dependencies test-bootstrap-publication test-network-bootstrap test-core-release-profile prepare-bootstrap-release publish-bootstrap-release
bootstrap_release_dir ?= $(CURDIR)/.data/bootstrap-release
bootstrap_revision ?= $(shell git rev-parse HEAD)

bootstrap-publication-dependencies: bootstrap-schema-dependencies
	@command -v ssh >/dev/null && command -v rsync >/dev/null || { echo 'Install openssh-client and rsync on the publication runner' >&2; exit 2; }

test-network-bootstrap:
	@python3 ./scripts/test-network-bootstrap.py
	@bash ./scripts/test-network-bootstrap-shell.sh
	@python3 ./scripts/test-bootstrap-software.py

test-core-release-profile:
	@bash ./scripts/test-core-release-profile.sh

test-bootstrap-publication:
	@python3 ./scripts/test-bootstrap-release.py

.PHONY: test-bootstrap-publisher-ownership
test-bootstrap-publisher-ownership:
	@python3 ./scripts/test-bootstrap-publisher-ownership.py

prepare-bootstrap-release:
	@python3 ./scripts/bootstrap-release.py prepare "$(CURDIR)/.." "$(bootstrap_release_dir)" "$(bootstrap_revision)"

publish-bootstrap-release:
	@bash ./scripts/publish-bootstrap-release.sh "$(bootstrap_release_dir)" "$(deploy_host)" "$(deploy_user)"

.PHONY: test-command-results test-post-sync-join-helper test-phase-ml-add-ownership test-phase-ml-remove-ownership test-phase-ml-status test-phase-node-stop-lifecycle test-node-container-control test-node-container-lending-docker test-prepare-accelerator-binding test-reset-then-join-entry test-verify-lineage-trust-fresh-boundaries test-verify-state-sync-config test-wait-state-sync-canary test-join-resume-new-canonical test-join-resume-post-sync-shared test-join-resume-restore-post-sync-refusal test-join-resume-restore-membership test-join-resume-membership-funding test-ml-lend-generic-pairs test-ml-lending-two-hosts test-detach-network-ml-host test-wait-dapi-worker-removal test-validator-ml-lifecycle test-read-lent-ml-record test-two-host-lifecycle-locks test-pinned-dapi-worker-removal test-host-lifecycle
test-command-results:
	@bash ./scripts/test-command-results.sh

test-post-sync-join-helper:
	@bash ./scripts/test-post-sync-join-helper.sh

test-phase-ml-add-ownership:
	@bash ./scripts/test-phase-ml-add-ownership.sh

test-phase-ml-remove-ownership:
	@bash ./scripts/test-phase-ml-remove-ownership.sh

test-phase-ml-status:
	@bash ./scripts/test-phase-ml-status.sh

test-node-container-lending-docker:
	@bash ./scripts/test-node-container-lending-docker.sh

test-phase-node-stop-lifecycle:
	@bash ./scripts/test-phase-node-stop-lifecycle.sh

test-node-container-control:
	@bash ./scripts/test-node-container-control.sh

test-prepare-accelerator-binding:
	@bash ./scripts/test-prepare-accelerator-binding.sh

test-ml-lend-generic-pairs:
	@bash ./scripts/test-ml-lend-generic-pairs.sh

test-ml-lending-two-hosts:
	@bash ./scripts/test-ml-lending-two-hosts.sh

.PHONY: test-ml-callback
test-ml-callback:
	@bash ./scripts/test-ml-callback.sh

.PHONY: test-start-ml-transport
test-start-ml-transport:
	@bash ./scripts/test-start-ml-transport.sh

test-detach-network-ml-host:
	@bash ./scripts/test-detach-network-ml-host.sh

test-wait-dapi-worker-removal:
	@bash ./scripts/test-wait-dapi-worker-removal.sh

test-validator-ml-lifecycle:
	@bash ./scripts/test-validator-ml-lifecycle.sh

test-read-lent-ml-record:
	@bash ./scripts/test-read-lent-ml-record.sh

test-two-host-lifecycle-locks:
	@bash ./scripts/test-two-host-lifecycle-locks.sh

test-pinned-dapi-worker-removal: bats-docker-image
	@bash ./scripts/test-pinned-dapi-worker-removal.sh

test-host-lifecycle: $(HOST_LIFECYCLE_SHARED_TESTS) test-join-resume-caught-up-canary test-phase-join-caught-up-lineage test-phase-ml-remove-ownership test-phase-ml-status test-phase-node-stop-lifecycle test-wait-dapi-worker-removal test-read-lent-ml-record test-two-host-lifecycle-locks test-pinned-dapi-worker-removal test-host-peers-lifecycle

.PHONY: test-host-peers-lifecycle
test-host-peers-lifecycle:
	@docker build --file test/Dockerfile.host-upgrade --tag gdc-host-peers-test:local ..
	@docker run --rm --privileged -e GDC_PEERS_DIND=true --entrypoint bash gdc-host-peers-test:local scripts/test-host-peers-lifecycle.sh

test-reset-then-join-entry:
	@bash ./scripts/test-reset-then-join-entry.sh

test-verify-lineage-trust-fresh-boundaries:
	@bash ./scripts/test-verify-lineage-trust-fresh-boundaries.sh

test-verify-state-sync-config:
	@bash ./scripts/test-verify-state-sync-config.sh

test-wait-state-sync-canary:
	@bash ./scripts/test-wait-state-sync-canary.sh

test-phase-join-caught-up-lineage:
	@bash ./scripts/test-phase-join-caught-up-lineage.sh

test-join-resume-new-canonical:
	@bash ./scripts/test-join-resume-new-canonical.sh

test-join-resume-post-sync-shared:
	@bash ./scripts/test-join-resume-post-sync-shared.sh

test-join-resume-restore-post-sync-refusal:
	@bash ./scripts/test-join-resume-restore-post-sync-refusal.sh

test-join-resume-restore-membership:
	@bash ./scripts/test-join-resume-restore-membership.sh

test-join-resume-membership-funding:
	@bash ./scripts/test-join-resume-membership-funding.sh

test-join-resume-caught-up-canary:
	@bash ./scripts/test-join-resume-caught-up-canary.sh

test-register-join-monitoring-targets:
	@bash ./scripts/test-register-join-monitoring-targets.sh

.PHONY: test-join-monitoring-runtime
test-join-monitoring-runtime: bats-docker-image
	@bash ./scripts/test-join-monitoring-runtime.sh

.PHONY: test-registration-failover test-proxy-ingress-layouts test-reconcile-proxy-ingress-remote
test-registration-failover:
	@bash ./scripts/test-register-participant-failover.sh

test-proxy-ingress-layouts:
	@bash ./scripts/test-proxy-ingress-layouts.sh

test-reconcile-proxy-ingress-remote:
	@bash ./scripts/test-reconcile-proxy-ingress-remote.sh

.PHONY: test-participants-proxy
test-participants-proxy:
	@node ./scripts/test-participants-proxy.mjs

.PHONY: test-network-observer test-network-observer-http test-network-observer-install
test-network-observer: test-network-observer-http test-network-observer-install test-verify-network-observer
	@node ./scripts/test-network-observer.mjs

test-network-observer-http:
	@node ./scripts/test-network-observer-http.mjs

test-network-observer-install:
	@docker build --file test/Dockerfile.bootstrap --tag gdc-network-observer-install-test ..
	@docker run --rm --network none --tmpfs /srv/dai:rw,exec \
		-e GDC_TEST_DISPOSABLE_ROOT=true --volume "$(CURDIR)/..:/source:ro" \
		--entrypoint python3 gdc-network-observer-install-test \
		/source/net-deployment-runbook/scripts/test-network-observer-install.py

test-recover-incident:
	@bash ./scripts/test-recover-incident.sh
	@bash ./scripts/test-host-peers.sh
	@bash ./scripts/test-same-host-restore.sh

.PHONY: test-recover-incident-runtime
test-recover-incident-runtime:
	@bash ./scripts/test-recover-incident-runtime.sh

.PHONY: test-recover-incident-services-runtime
test-recover-incident-services-runtime:
	@bash ./scripts/test-recover-incident-services-runtime.sh

test-recovery-rehearsal:
	@./scripts/test-network-recovery-rehearsal.sh --manifest "$(manifest)" --lab-approval "$(lab_approval)" --evidence-dir "$(evidence_dir)" --timeout-seconds "$(timeout_seconds)"

# Exact released signer, synthetic key, no live mounts and no network.
.PHONY: test-telegram-registration-lifecycle
test-telegram-registration-lifecycle:
	@python3 scripts/test-telegram-registration-lifecycle.py

.PHONY: test-tmkms-recovery-boundary
test-tmkms-recovery-boundary:
	@image="$$(docker build -q -f scripts/tmkms-boundary.Dockerfile scripts)" && \
		docker run --rm --network none --cpus 0.5 --memory 256m "$$image"

.PHONY: test-devshard-release devshard-release-prepare devshard-release-fetch devshard-release-build devshard-release-verify devshard-release-publish
test-devshard-release:
	@python3 ./scripts/test-devshard-release.py

devshard-release-prepare:
	@python3 ./scripts/devshard-release.py prepare

devshard-release-fetch:
	@python3 ./scripts/devshard-release.py fetch

devshard-release-build:
	@python3 ./scripts/devshard-release.py build

devshard-release-verify:
	@python3 ./scripts/devshard-release.py verify

devshard-release-publish:
	@python3 ./scripts/devshard-release.py publish

.PHONY: test-devshard-artifacts devshard-artifacts-prepare devshard-artifacts-fetch devshard-artifacts-build devshard-artifacts-verify devshard-artifacts-smoke devshard-artifacts-verify-reuse devshard-artifacts-publish
DEVSHARD_ARTIFACT_GROUP_ARGS := $(foreach group,$(groups),--group $(group))
test-devshard-artifacts:
	@python3 ./scripts/test-devshard-artifacts.py

devshard-artifacts-prepare:
	@python3 ./scripts/devshard-artifacts.py prepare $(DEVSHARD_ARTIFACT_GROUP_ARGS)

devshard-artifacts-fetch:
	@python3 ./scripts/devshard-artifacts.py fetch $(DEVSHARD_ARTIFACT_GROUP_ARGS)

devshard-artifacts-build:
	@python3 ./scripts/devshard-artifacts.py build $(DEVSHARD_ARTIFACT_GROUP_ARGS)

devshard-artifacts-verify:
	@python3 ./scripts/devshard-artifacts.py verify $(DEVSHARD_ARTIFACT_GROUP_ARGS)

devshard-artifacts-smoke:
	@python3 ./scripts/devshard-artifacts.py smoke $(DEVSHARD_ARTIFACT_GROUP_ARGS)

devshard-artifacts-verify-reuse:
	@python3 ./scripts/devshard-artifacts.py verify-reuse $(DEVSHARD_ARTIFACT_GROUP_ARGS)

devshard-artifacts-publish:
	@python3 ./scripts/devshard-artifacts.py publish $(DEVSHARD_ARTIFACT_GROUP_ARGS)

.PHONY: test-gonka-pr-unified-release gonka-pr-unified-release-prepare gonka-pr-unified-release-fetch gonka-pr-unified-release-build gonka-pr-unified-release-verify gonka-pr-unified-release-publish
.PHONY: test-ci-route ci-route ci-result
.PHONY: test-ci-release-helpers
test-ci-release-helpers:
	@./scripts/test-verify-devshard-archive.sh
	@python3 ./scripts/test-pin-candidate-dockerfile.py
	@python3 ./scripts/test-patch-candidate-go-mod-download.py

test-ci-route:
	@python3 ./scripts/test-ci-route.py

ci-route:
	@case "$${CI_EVENT:-}" in \
	  pull_request) python3 ./scripts/ci-route.py --changed-files "$$CI_CHANGED_FILES" --github-output "$$GITHUB_OUTPUT" ;; \
	  push) python3 ./scripts/ci-route.py --base "$$CI_BASE" --head "$$CI_HEAD" --github-output "$$GITHUB_OUTPUT" ;; \
	  *) python3 ./scripts/ci-route.py --full --github-output "$$GITHUB_OUTPUT" ;; \
	esac

ci-result:
	@python3 ./scripts/ci-result.py

test-gonka-pr-unified-release:
	@python3 ./scripts/test-gonka-pr-unified-release.py

gonka-pr-unified-release-prepare:
	@python3 ./scripts/gonka-pr-unified-release.py prepare

gonka-pr-unified-release-fetch:
	@python3 ./scripts/gonka-pr-unified-release.py fetch

gonka-pr-unified-release-build:
	@python3 ./scripts/gonka-pr-unified-release.py build

gonka-pr-unified-release-verify:
	@python3 ./scripts/gonka-pr-unified-release.py verify

gonka-pr-unified-release-publish:
	@python3 ./scripts/gonka-pr-unified-release.py publish
