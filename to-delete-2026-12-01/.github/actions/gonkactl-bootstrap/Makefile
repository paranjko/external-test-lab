# CI transport only. All bootstrap validation lives in the installed Go CLI.
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.ONESHELL:
.PHONY: install validate inventory notify

install:
	@directory=$$(mktemp -d "$${RUNNER_TEMP:-/tmp}/gonkactl-user.XXXXXXXX")
	install_dir="$$directory/bin"
	curl --proto '=https' --proto-redir '=https' --fail --location --silent --show-error --connect-timeout 15 --max-time 60 https://gonka-dev.net/ctl/install.sh -o "$$directory/install.sh"
	env -i PATH="$$PATH" GONKACTL_INSTALL_DIR="$$install_dir" GONKACTL_VERSION=1.0.0-alpha.6 sh "$$directory/install.sh"
	binary="$$install_dir/gonkactl"
	test "$$("$$binary" --version)" = 1.0.0-alpha.6
	"$$binary" version | grep -Fx 'commit: 8ad8880b7b3a5e1fa1504360429f3d569f9b67a9'
	printf 'binary-path=%s\n' "$$binary" >> "$$GITHUB_OUTPUT"

validate:
	@[[ "$$BOOTSTRAP_CHAIN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$$ ]]
	[[ "$$BOOTSTRAP_REPORT" != *$$'\n'* && "$$BOOTSTRAP_REPORT" != *$$'\r'* ]]
	mkdir -p "$$(dirname "$$BOOTSTRAP_REPORT")"
	code=0
	"$$BOOTSTRAP_BINARY" bootstrap validate "$$BOOTSTRAP_CHAIN_ID" --compare-published "$$BOOTSTRAP_INVENTORY" --base-url "$$BOOTSTRAP_ORIGIN" --timeout "$$BOOTSTRAP_TIMEOUT" --json > "$$BOOTSTRAP_REPORT" || code=$$?
	# Launch/input errors may precede a native report; retain them as failures.
	if ! jq -e --arg chain "$$BOOTSTRAP_CHAIN_ID" '.schema_version == 1 and (.results | type == "array" and length == 1) and .results[0].chain_id == $$chain and (.results[0].ok | type == "boolean")' "$$BOOTSTRAP_REPORT" >/dev/null 2>&1; then
		code=2
		jq -n --arg chain "$$BOOTSTRAP_CHAIN_ID" --arg origin "$$BOOTSTRAP_ORIGIN" '{schema_version:1,results:[{chain_id:$$chain,bootstrap_url:($$origin+"/"+$$chain+"/bootstrap.json"),ok:false,checks:[{stage:"execution",ok:false,error:"CLI installation, invocation or report output failed"}]}]}' > "$$BOOTSTRAP_REPORT"
	fi
	if ((code == 0)) && ! jq -e '.results[0].ok == true' "$$BOOTSTRAP_REPORT" >/dev/null; then code=2; fi
	failed=false; if ((code != 0)); then failed=true; fi
	printf 'failed=%s\nreport-path=%s\nexit-code=%s\n' "$$failed" "$$BOOTSTRAP_REPORT" "$$code" >> "$$GITHUB_OUTPUT"
	exit "$$code"

inventory:
	@chains=$$(jq -n -c '[inputs | input_filename | split("/")[-1] | rtrimstr(".json")] | if length == 0 then error("empty bootstrap inventory") else . end' bootstrap/*.json)
	printf 'chains=%s\n' "$$chains" >> "$$GITHUB_OUTPUT"

notify:
	@[[ "$$GDC_TELEGRAM_BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$$ ]]
	: "$${GDC_TELEGRAM_NOTIFICATION:?missing notification chat}"
	: "$${GITHUB_RUN_ID:?missing workflow run}"
	: "$${GITHUB_REPOSITORY:?missing repository}"
	shopt -s nullglob
	reports=(net-deployment-runbook/.data/bootstrap-monitor/*.json)
	(($${#reports[@]} > 0))
	failed=0
	for report in "$${reports[@]}"; do
		if jq -e '.results | length > 0 and all(.ok == true)' "$$report" >/dev/null; then continue; fi
		# jq performs JSON and HTML escaping; never log credential-bearing errors.
		payload=$$(jq -c --arg chat "$$GDC_TELEGRAM_NOTIFICATION" --arg run "https://github.com/$$GITHUB_REPOSITORY/actions/runs/$$GITHUB_RUN_ID" --arg id "$$GITHUB_RUN_ID" '.results[] | select(.ok == false) | {chat_id:$$chat,parse_mode:"HTML",text:("<b>⚠️ Warning:</b> The Bootstrap <a href=\""+(.bootstrap_url|@html)+"\">"+(.chain_id|@html)+"</a> needs to be updated, validation for <a href=\""+($$run|@html)+"\">"+($$id|@html)+"</a> failed")}' "$$report")
		if ! curl --proto '=https' --fail --silent --connect-timeout 15 --max-time 30 -H 'Content-Type: application/json' --data-binary "$$payload" "https://api.telegram.org/bot$$GDC_TELEGRAM_BOT_TOKEN/sendMessage" 2>/dev/null | jq -e '.ok == true' >/dev/null; then
			printf '%s\n' 'Bootstrap notification failed' >&2; failed=1
		fi
	done
	exit "$$failed"
