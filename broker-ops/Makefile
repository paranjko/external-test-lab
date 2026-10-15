.PHONY: test-v6-budget-rotation
test-v6-budget-rotation: test-v6-first-token-tuning test-v6-gateway-release-switch
	python3 -m unittest $(sort $(wildcard test_v6_budget_*.py))

.PHONY: test-v6-first-token-tuning
test-v6-first-token-tuning:
	python3 -m unittest discover -s . -p 'test_v6_first_token_tuning.py'

.PHONY: test-v6-gateway-release-switch
test-v6-gateway-release-switch:
	python3 -m unittest discover -s . -p 'test_v6_gateway_release_switch.py'

.PHONY: test-v6-stable-receipt
test-v6-stable-receipt:
	python3 -m unittest discover -s . -p 'test_v6_stable_receipt.py'

# Explicit source qualification; not part of ordinary source-independent CI.
.PHONY: test-v6-ha-migration
test-v6-ha-migration:
	bash ./test-v6-ha-migration.sh
