.PHONY: validate package dependencies

dependencies:
	npm ci --ignore-scripts --no-audit --no-fund

validate:
	python3 -m unittest discover -s scripts -p 'test_*.py'
	bash scripts/validate.sh

package:
	python3 scripts/package.py --output ../.cache/skills/gonka-validator-diagnosis_1.0.0.zip
