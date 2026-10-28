# Standalone site build and publication entrypoint, independent of GDC targets
site_release_dir ?= $(CURDIR)/.data/site-release
site_publish_prefix ?=
site_revision ?=
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
site_preview_expected_card_count ?= 0
site_preview_expected_node_states ?=
deploy_host ?=
deploy_user ?=

.PHONY: site-vendor site-js site-js-check site-serve test-site-serve site-host-requirements-check test-browser-devtools test-gateway-site-state test-stable-gateway-site test-ci-site test-production-network-browser test-site-snapshot-acceptance test-verify-network-observer verify-network-observer test-network-selection test-validator-map prepare-static-site prepare-site-preview-artifact prepare-isolated-site-preview-artifact prepare-isolated-preview-ci prepare-isolated-preview-ci-artifact write-isolated-preview-deploy-env publish-isolated-preview-ci publish-site-release publish-site-preview publish-isolated-site-preview rollback-site-preview remove-site-release remove-isolated-site-preview test-site-release-paths test-site-release-verifier test-site-publisher test-site-preview-context verify-removed-site-preview-live test-verify-removed-site-preview-live test-site-preview-live test-site-preview-plan test-site-preview-generation test-site-preview-endpoints test-site-preview-platform test-status-openapi test-public-gpu-freshness test-public-edge-static-site test-site-preview-acceptance test-preview-isolation test-preview-lifecycle test-preview-provision test-preview-status-renderer test-preview-frontend-builder test-isolated-preview-ci test-isolated-preview-ci-artifact test-record-site-preview-deployment test-verify-isolated-site-preview-live test-prepare-public-preview-inventory test-node-observation-guard test-isolated-preview-runtime-config test-prepare-isolated-site-preview-artifact test-isolated-preview-publish test-prepare-isolated-preview-composition test-edge-install-ownership verify-site-release verify-site-preview-artifact verify-isolated-preview-ci-artifact verify-isolated-site-preview-live verify-site-preview-live verify-site-preview-endpoints smoke-site-preview-acceptance smoke-site-preview record-site-preview-deployment site-preview-publish-context site-preview-cleanup-context

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
	@$(MAKE) -f make/site.mk test-gateway-site-state test-site-release-paths test-site-preview-plan test-site-preview-generation test-site-preview-endpoints test-site-publisher test-status-openapi
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


.PHONY: test-site-make-isolation
test-site-make-isolation:
	@bash ./scripts/test-site-make-isolation.sh
