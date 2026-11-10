.PHONY: install

install:
	$(MAKE) -C gonkactl-trace install

.PHONY: test-service-repair
test-service-repair:
	bash net-deployment-runbook/scripts/test-service-repair-docker.sh
	shellcheck net-deployment-runbook/scripts/node-container-control.sh net-deployment-runbook/scripts/test-service-repair-docker.sh
