#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
fixture="$tmp/runbook"
mkdir -p "$fixture"
tar --exclude='./.data' -C "$ROOT" -cf - . | tar -C "$fixture" -xf -
mkdir -p "$tmp/model"
cp "$ROOT/../model/"*.lock "$tmp/model/"
mkdir -p "$tmp/bin"

cat >"$fixture/scripts/reset-genesis-host.sh" <<'REMOTE'
#!/usr/bin/env bash
printf 'fixture-reset-helper\n'
REMOTE
cat >"$fixture/scripts/phase-model-worker-add.sh" <<'HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${GDC_TEST_HELPER_CALLS:?}"
HELPER
cat >"$fixture/scripts/phase-model-primary-reconfigure.sh" <<'RETUNE'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'retune %s\n' "$*" >>"${GDC_TEST_HELPER_CALLS:?}"
printf 'home=%s\nstate=%s\n' "$GDC_HOME" "$STATE" >>"${GDC_TEST_PRIMARY_CONTEXT:?}"
if [[ "${1:-}" == plan ]]; then printf '{"fixture":"plan"}\n' >"${5:?}"; fi
RETUNE
cat >"$fixture/scripts/write-genesis-role-config.sh" <<'ROLE'
#!/usr/bin/env bash
set -Eeuo pipefail
output=''
while (($#)); do case "$1" in --output) output="$2"; shift 2;; *) shift;; esac; done
mkdir -p "$(dirname "$output")"
cat >"$output" <<'EOF'
GDC_NODE_ALIASES='node0 node4'
GDC_NODE_PUBLIC_HOSTS='node0=node0.example.test node4=node4.example.test'
GDC_NODE_P2P_PORTS='node0=5000 node4=5000'
GDC_GENESIS_NODE=node0
GDC_PUBLIC_EDGE_NODE=node4
GDC_GATEWAY_NODE=node0
GDC_DEPLOYMENT_PROFILE=community-lab
GDC_OPERATOR_SERVICES_PROFILE=gdc-lab
GDC_GENESIS_ROLE_INPUT=true
EOF
ROLE
cat >"$fixture/scripts/phase-genesis.sh" <<'PHASE'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'model=%s\nscope=%s\nprepare=%s\nresume=%s\nconfig=%s\nsoftware=%s\nedge=%s\nargs=%s\n' \
  "$MODEL_ID" "$GDC_MODEL_PROFILE_SCOPE" "$GDC_GENESIS_PREPARE_ONLY" \
  "$GDC_GENESIS_RESUME_CANDIDATE" "$GDC_GENESIS_CONFIG_FILE" "$GDC_GENESIS_SOFTWARE_FILE" "$GDC_PUBLIC_EDGE_NODE" "$*" \
  >"${GDC_TEST_GENESIS_PHASE:?}"
PHASE
cat >"$tmp/bin/getent" <<'GETENT'
#!/usr/bin/env bash
printf '192.0.2.10 STREAM %s\n' "${*: -1}"
GETENT
cat >"$tmp/bin/ssh" <<'SSH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${GDC_TEST_SSH_ARGS:?}"
if [[ "${3:-}" == sudo\ -n\ bash\ -s\ --* ]]; then
  [[ "$3" =~ ^sudo\ -n\ bash\ -s\ --\ (gdc-node[0-9]+)\ ([0-9]{8}T[0-9]{6}Z)(\ --ml-project\ gdc-node4-ml)?$ ]]
  host="${BASH_REMATCH[1]}"; stamp="${BASH_REMATCH[2]}"
  archive="/srv/dai-archives/$stamp-$host"
  cat >"${GDC_TEST_SSH_STDIN:?}"
  printf 'PASS new-Genesis Host reset host=%s archive=%s receipt=%s/reset-genesis-receipt.json\n' \
    "$host" "$archive" "$archive"
elif [[ "${3:-}" == *'sudo -n test -f '* ]]; then
  [[ "$3" =~ (/srv/dai-archives/[0-9]{8}T[0-9]{6}Z-gdc-node[0-9]+) ]]
  archive="${BASH_REMATCH[1]}"; stamp="${archive##*/}"; stamp="${stamp%-gdc-node*}"
  host="$2"
  jq -n --arg host "$host" --arg archive "$archive" --arg stamp "$stamp" \
    --arg edge "gdc-edge-$host" --arg monitoring "gdc-monitoring-agent-$host" \
    '{schema_version:1,kind:"gdc-new-genesis-reset-receipt",host:$host,
      completed_utc:$stamp,archive:$archive,projects:[$host,$edge,$monitoring],
      systemd_units:[],containers:[],moved_paths:[],preserved_paths:[]}'
else
  echo "unexpected SSH command in special CLI fixture: $3" >&2
  exit 99
fi
SSH
chmod 0755 "$tmp/bin/getent" "$tmp/bin/ssh" "$fixture/scripts/reset-genesis-host.sh" \
  "$fixture/scripts/phase-model-worker-add.sh" "$fixture/scripts/phase-model-primary-reconfigure.sh" "$fixture/scripts/write-genesis-role-config.sh" \
  "$fixture/scripts/phase-genesis.sh"

run_gdc() {
  PATH="$tmp/bin:$PATH" GDC_HOME="${GDC_TEST_HOME:-$tmp/operator}" \
    GDC_TEST_SSH_ARGS="$tmp/ssh.args" GDC_TEST_SSH_STDIN="$tmp/ssh.stdin" \
    GDC_TEST_HELPER_CALLS="$tmp/helper.calls" GDC_TEST_PRIMARY_CONTEXT="$tmp/primary.context" \
    "$fixture/gdc.sh" "$@"
}
reject() {
  local label="$1"; shift
  if run_gdc "$@" >"$tmp/$label.out" 2>"$tmp/$label.err"; then
    echo "unexpected success: $label" >&2
    exit 1
  fi
  [[ ! -e "$tmp/ssh.args" ]] || { echo "unexpected SSH call while rejecting: $label" >&2; exit 1; }
  [[ ! -e "$tmp/helper.calls" ]] || { echo "unexpected helper call while rejecting: $label" >&2; exit 1; }
}

reject reset-missing host reset --new-genesis
reject reset-extra host reset --new-genesis node-a node-b
reject reset-invalid host reset --new-genesis 'node-a;touch'
reject reset-ml-wrong-host host reset --new-genesis --ml-project gdc-node4-ml node8
reject reset-ml-wrong-project host reset --new-genesis --ml-project other node9
reject reset-ml-wrong-order host reset --new-genesis node9 --ml-project gdc-node4-ml
reject worker-missing host models add-worker node-a
reject worker-invalid host models add-worker 'node-a;touch' descriptor.json
reject worker-flag host models add-worker node-a descriptor.json --unsafe
reject worker-reconcile-and-apply host models add-worker node-a descriptor.json --apply --reconcile-uncertain
printf '{}\n' >"$tmp/descriptor.json"
printf '{"model_id":"Qwen/Qwen2.5-7B-Instruct","args":["--gpu-memory-utilization","0.92"]}\n' >"$tmp/desired.json"
reject retune-missing host models retune-primary
reject retune-extra host models retune-primary plan node-a "$tmp/descriptor.json" "$tmp/desired.json" /tmp/plan.json extra
reject retune-invalid-host host models retune-primary plan 'node-a;touch' "$tmp/descriptor.json" "$tmp/desired.json" /tmp/plan.json
reject retune-nonabsolute-plan host models retune-primary plan node-a "$tmp/descriptor.json" "$tmp/desired.json" plan.json
reject retune-missing-descriptor host models retune-primary plan node-a "$tmp/missing.json" "$tmp/desired.json" /tmp/plan.json
reject retune-missing-apply-plan host models retune-primary apply node-a "$tmp/descriptor.json" "$tmp/desired.json" "$tmp/missing-plan.json"
reject retune-release-overlay --release v2026.10.06 host models retune-primary plan node-a "$tmp/descriptor.json" "$tmp/desired.json" /tmp/plan.json
reject retune-composition-overlay --composition fixture host models retune-primary plan node-a "$tmp/descriptor.json" "$tmp/desired.json" /tmp/plan.json
reject retune-model-overlay --model fixture host models retune-primary plan node-a "$tmp/descriptor.json" "$tmp/desired.json" /tmp/plan.json

printf '{}\n' >"$tmp/config.json"
printf '{}\n' >"$tmp/software.json"
config_sha="$(sha256sum "$tmp/config.json" | awk '{print $1}')"
software_sha="$(sha256sum "$tmp/software.json" | awk '{print $1}')"
candidate_sha="$(printf 'd%.0s' {1..64})"
reject resume-missing-software network genesis node0 --resume-installed-candidate "$candidate_sha" --config-file "$tmp/config.json" --config-sha256 "$config_sha"
reject resume-defer network genesis node0 --resume-installed-candidate "$candidate_sha" --config-file "$tmp/config.json" --config-sha256 "$config_sha" --software-file "$tmp/software.json" --software-sha256 "$software_sha" --defer-services
reject resume-time network genesis node0 --resume-installed-candidate "$candidate_sha" --time=+5m --config-file "$tmp/config.json" --config-sha256 "$config_sha" --software-file "$tmp/software.json" --software-sha256 "$software_sha"
reject resume-apply-conflict network genesis node0 --resume-installed-candidate "$candidate_sha" --apply-candidate "$candidate_sha" --config-file "$tmp/config.json" --config-sha256 "$config_sha" --software-file "$tmp/software.json" --software-sha256 "$software_sha" --defer-services

if PATH="$tmp/bin:$PATH" GDC_HOME="$tmp/qualification-operator" \
  GDC_TEST_GENESIS_PHASE="$tmp/qualification-phase.log" \
  GDC_TEST_SSH_ARGS="$tmp/qualification-ssh.args" GDC_TEST_SSH_STDIN="$tmp/qualification-ssh.stdin" \
  GDC_TEST_HELPER_CALLS="$tmp/qualification-helper.calls" \
  "$fixture/gdc.sh" --release v2026.10.06 --model qwen2.5-7b-instruct network genesis node0 \
  >"$tmp/qualification.out" 2>"$tmp/qualification.err"; then
  echo 'qualification-only model reached the Genesis phase' >&2; exit 1
fi
grep -Fq 'qualification-only' "$tmp/qualification.err" || { cat "$tmp/qualification.err" >&2; exit 1; }
[[ ! -e "$tmp/qualification-phase.log" && ! -e "$tmp/qualification-ssh.args" ]]

PATH="$tmp/bin:$PATH" GDC_HOME="$tmp/genesis-operator" \
  GDC_TEST_GENESIS_PHASE="$tmp/genesis-phase.log" \
  GDC_TEST_SSH_ARGS="$tmp/genesis-ssh.args" GDC_TEST_SSH_STDIN="$tmp/genesis-ssh.stdin" \
  GDC_TEST_HELPER_CALLS="$tmp/genesis-helper.calls" \
  "$fixture/gdc.sh" --release v2026.10.06 --model qwen2.5-7b-instruct-devnet network genesis node0 \
  --prepare-only --config-file "$tmp/config.json" --config-sha256 "$config_sha" \
  --software-file "$tmp/software.json" --software-sha256 "$software_sha" \
  --public-host node0.example.test --public-edge node4 >"$tmp/genesis.out"
grep -Fxq 'model=Qwen/Qwen2.5-7B-Instruct' "$tmp/genesis-phase.log"
grep -Fxq 'scope=network' "$tmp/genesis-phase.log"
grep -Fxq 'prepare=true' "$tmp/genesis-phase.log"
grep -Fxq "config=$tmp/config.json" "$tmp/genesis-phase.log"
grep -Fxq "software=$tmp/software.json" "$tmp/genesis-phase.log"
grep -Fxq 'edge=node4' "$tmp/genesis-phase.log"
[[ ! -e "$tmp/genesis-ssh.args" ]]

GDC_HOME="$tmp/resume-operator" PATH="$tmp/bin:$PATH" \
  GDC_TEST_GENESIS_PHASE="$tmp/resume-phase.log" GDC_TEST_SSH_ARGS="$tmp/resume-ssh.args" \
  GDC_TEST_SSH_STDIN="$tmp/resume-ssh.stdin" GDC_TEST_HELPER_CALLS="$tmp/resume-helper.calls" \
  "$fixture/gdc.sh" --release v2026.10.06 --model qwen2.5-7b-instruct-devnet network genesis node0 \
  --resume-installed-candidate "$candidate_sha" --config-file "$tmp/config.json" --config-sha256 "$config_sha" \
  --software-file "$tmp/software.json" --software-sha256 "$software_sha" \
  --public-host node0.example.test --public-edge node4 >"$tmp/resume.out"
grep -Fxq "resume=$candidate_sha" "$tmp/resume-phase.log"
grep -Fxq "config=$tmp/config.json" "$tmp/resume-phase.log"
grep -Fxq "software=$tmp/software.json" "$tmp/resume-phase.log"
[[ ! -e "$tmp/resume-ssh.args" ]]

mkdir -p "$tmp/operator/gdc-node3/state/identities" "$tmp/operator/gdc-node3/accounts" \
  "$tmp/operator/gdc-node3/mnemonics" "$tmp/operator/gdc-node3/state/secrets"
printf '{"node_id":"0123456789abcdef0123456789abcdef01234567"}\n' >"$tmp/operator/gdc-node3/state/identities/gdc-node3.json"
printf '{"address":"gonka1fixtureparticipant"}\n' >"$tmp/operator/gdc-node3/accounts/gdc-node3-cold.json"
printf 'fixture retained cold recovery record\n' >"$tmp/operator/gdc-node3/mnemonics/gdc-node3-cold.mnemonic"
printf 'fixture retained cold address\n' >"$tmp/operator/gdc-node3/mnemonics/gdc-node3-cold.address"
printf 'fixture retained keyring\n' >"$tmp/operator/gdc-node3/state/secrets/gdc-node3.keyring"
chmod 0600 "$tmp/operator/gdc-node3/state/identities/gdc-node3.json" "$tmp/operator/gdc-node3/accounts/gdc-node3-cold.json" \
  "$tmp/operator/gdc-node3/mnemonics/gdc-node3-cold.mnemonic" "$tmp/operator/gdc-node3/mnemonics/gdc-node3-cold.address" \
  "$tmp/operator/gdc-node3/state/secrets/gdc-node3.keyring"
identity_sha="$(sha256sum "$tmp/operator/gdc-node3/state/identities/gdc-node3.json" | awk '{print $1}')"
account_sha="$(sha256sum "$tmp/operator/gdc-node3/accounts/gdc-node3-cold.json" | awk '{print $1}')"
cold_mnemonic_sha="$(sha256sum "$tmp/operator/gdc-node3/mnemonics/gdc-node3-cold.mnemonic" | awk '{print $1}')"
run_gdc host reset --new-genesis gdc-node3 >"$tmp/reset.out"
grep -Fq "printf 'fixture-reset-helper" "$tmp/ssh.stdin"
grep -Eq '^-T gdc-node3 sudo -n bash -s -- gdc-node3 [0-9]{8}T[0-9]{6}Z$' "$tmp/ssh.args"
host_run="$(<"$tmp/operator/gdc-node3/state/active-run-id")"
[[ -s "$tmp/operator/gdc-node3/runs/$host_run/run.log" ]]
[[ -s "$tmp/operator/gdc-node3/runs/$host_run/manifest.env" ]]
[[ ! -e "$tmp/operator/gdc-node3/state/identities/gdc-node3.json" \
  && ! -e "$tmp/operator/gdc-node3/accounts/gdc-node3-cold.json" ]]
[[ "$(sha256sum "$tmp/operator/gdc-node3/runs/$host_run/local-reset-state/identity.json" | awk '{print $1}')" == "$identity_sha" ]]
[[ "$(sha256sum "$tmp/operator/gdc-node3/runs/$host_run/local-reset-state/account.json" | awk '{print $1}')" == "$account_sha" ]]
[[ "$(sha256sum "$tmp/operator/gdc-node3/mnemonics/gdc-node3-cold.mnemonic" | awk '{print $1}')" == "$cold_mnemonic_sha" ]]
[[ -e "$tmp/operator/gdc-node3/state/.lifecycle.lock" ]]
[[ ! -e "$tmp/operator/runs" && ! -e "$tmp/operator/network-owner" ]]

GDC_TEST_HOME="$tmp/ml-reset-operator" run_gdc host reset --new-genesis --ml-project gdc-node4-ml gdc-node9 >"$tmp/ml-reset.out"
grep -Eq '^-T gdc-node9 sudo -n bash -s -- gdc-node9 [0-9]{8}T[0-9]{6}Z --ml-project gdc-node4-ml$' "$tmp/ssh.args"

GDC_TEST_HOME="$tmp/retune-operator" run_gdc host models retune-primary plan node-a \
  "$tmp/descriptor.json" "$tmp/desired.json" "$tmp/retune-plan.json" >"$tmp/retune-plan.out"
grep -Fxq "retune plan node-a $tmp/descriptor.json $tmp/desired.json $tmp/retune-plan.json" "$tmp/helper.calls"
grep -Fxq "home=$tmp/retune-operator/node-a" "$tmp/primary.context"
grep -Fxq "state=$tmp/retune-operator/node-a/state" "$tmp/primary.context"
[[ -s "$tmp/retune-plan.json" ]]
retune_ssh_count="$(wc -l <"$tmp/ssh.args")"
GDC_TEST_HOME="$tmp/retune-operator" run_gdc host models retune-primary apply node-a \
  "$tmp/descriptor.json" "$tmp/desired.json" "$tmp/retune-plan.json" >"$tmp/retune-apply.out"
grep -Fxq "retune apply node-a $tmp/descriptor.json $tmp/desired.json $tmp/retune-plan.json" "$tmp/helper.calls"
retune_run="$(<"$tmp/retune-operator/node-a/state/active-run-id")"
[[ -s "$tmp/retune-operator/node-a/runs/$retune_run/run.log" ]]
[[ -e "$tmp/retune-operator/node-a/state/.lifecycle.lock" ]]
[[ ! -e "$tmp/retune-operator/runs" && ! -e "$tmp/retune-operator/network-owner" ]]
[[ "$(wc -l <"$tmp/ssh.args")" == "$retune_ssh_count" ]]

GDC_TEST_HOME="$tmp/model-operator" run_gdc host models add-worker node-a "$tmp/descriptor.json" >"$tmp/plan.out"
grep -Fxq "node-a $tmp/descriptor.json" "$tmp/helper.calls"
[[ ! -e "$tmp/model-operator/node-a/state/.lifecycle.lock" ]]

GDC_TEST_HOME="$tmp/model-operator" run_gdc host models add-worker node-a "$tmp/descriptor.json" --reconcile-uncertain >"$tmp/reconcile.out"
grep -Fxq "node-a $tmp/descriptor.json --reconcile-uncertain" "$tmp/helper.calls"
[[ ! -e "$tmp/model-operator/node-a/state/.lifecycle.lock" ]]
reconcile_ssh_count="$(wc -l <"$tmp/ssh.args")"

GDC_TEST_HOME="$tmp/model-operator" run_gdc host models add-worker node-a "$tmp/descriptor.json" --apply >"$tmp/apply.out"
grep -Fxq "node-a $tmp/descriptor.json --apply" "$tmp/helper.calls"
model_run="$(<"$tmp/model-operator/node-a/state/active-run-id")"
[[ -s "$tmp/model-operator/node-a/runs/$model_run/run.log" ]]
[[ -e "$tmp/model-operator/node-a/state/.lifecycle.lock" ]]
[[ "$(wc -l <"$tmp/ssh.args")" == "$reconcile_ssh_count" ]]

printf 'PASS host new-Genesis reset, model-worker, and primary-retune CLI boundaries\n'
