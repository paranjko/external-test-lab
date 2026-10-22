#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

sed -n '/^# BEGIN verify-new-genesis-reset-receipt$/,/^# END verify-new-genesis-reset-receipt$/p' \
  "$ROOT/gdc.sh" | sed '1d;$d' >"$tmp/verify-function.sh"
sed -n '/^# BEGIN archive-new-genesis-local-identity$/,/^# END archive-new-genesis-local-identity$/p' \
  "$ROOT/gdc.sh" | sed '1d;$d' >"$tmp/archive-function.sh"
cat >"$tmp/bin-ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'called\n' >>"$GDC_TEST_SSH_CALLS"
[[ "$1" == -T && "$2" == "$GDC_TEST_ALIAS" ]]
[[ "$*" == *'sudo -n test -f '* && "$*" == *'sudo -n cat -- '* ]]
! [[ "$*" == *'docker'* || "$*" == *'systemctl'* || "$*" == *'mv '* || "$*" == *'rm '* ]]
printf '%s\n' "$(<"$GDC_TEST_RECEIPT")"
EOF
chmod 0755 "$tmp/bin-ssh"
source "$tmp/verify-function.sh"
source "$tmp/archive-function.sh"
ssh() { "$tmp/bin-ssh" "$@"; }
grep -Fq 'verify_new_genesis_reset_receipt "$join_alias" "$join_existing_home"' "$ROOT/gdc.sh"

alias_name=gdc-node3
host_home="$tmp/operator/$alias_name"
run_id=20261020T114353Z-1322902
stamp=20261020T114353Z
archive="/srv/dai-archives/$stamp-$alias_name"
receipt_path="$archive/reset-genesis-receipt.json"
run_dir="$host_home/runs/$run_id"
mkdir -p "$host_home/state" "$run_dir"
printf '%s\n' "$run_id" >"$host_home/state/active-run-id"
cat >"$run_dir/manifest.env" <<EOF
schema_version=2
run_id=$run_id
phase=host-reset-new-genesis-$alias_name
operator_data_home=$host_home
EOF
cat >"$run_dir/run.log" <<EOF
BEGIN phase=host-reset-new-genesis-$alias_name timestamp=2026-10-20T11:43:53Z run_id=$run_id
PASS new-Genesis Host reset host=$alias_name archive=$archive receipt=$receipt_path
END phase=host-reset-new-genesis-$alias_name status=0 timestamp=2026-10-20T11:43:53Z
EOF
jq -n --arg host "$alias_name" --arg archive "$archive" --arg stamp "$stamp" \
  --arg edge "gdc-edge-$alias_name" --arg monitoring "gdc-monitoring-agent-$alias_name" \
  '{schema_version:1,kind:"gdc-new-genesis-reset-receipt",host:$host,
    completed_utc:$stamp,archive:$archive,projects:[$host,$edge,$monitoring],
    systemd_units:[],containers:[],moved_paths:[],preserved_paths:[]}' \
  >"$tmp/receipt.json"
export GDC_TEST_RECEIPT="$tmp/receipt.json"
export GDC_TEST_SSH_CALLS="$tmp/ssh-calls"
export GDC_TEST_ALIAS=gdc-node3

verified="$(verify_new_genesis_reset_receipt "$alias_name" "$host_home")"
[[ "$verified" == true ]]

# A donor Host may have only reset the dedicated ML project. The receipt must
# bind that exact single project, its moved deployment tree, inactive unit,
# stopped containers, and the independently preserved service/cache roots.
ml_alias=gdc-node9
ml_project=gdc-node4-ml
ml_run=20261020T115320Z-1572790
ml_stamp=20261020T115320Z
ml_archive="/srv/dai-archives/$ml_stamp-$ml_alias"
ml_home="$tmp/operator/$ml_alias"
ml_run_dir="$ml_home/runs/$ml_run"
mkdir -p "$ml_home/state" "$ml_run_dir"
printf '%s\n' "$ml_run" >"$ml_home/state/active-run-id"
cat >"$ml_run_dir/manifest.env" <<EOF
schema_version=2
run_id=$ml_run
phase=host-reset-new-genesis-$ml_alias
operator_data_home=$ml_home
EOF
cat >"$ml_run_dir/run.log" <<EOF
BEGIN phase=host-reset-new-genesis-$ml_alias timestamp=2026-10-20T11:53:20Z run_id=$ml_run
PASS new-Genesis Host reset host=$ml_alias archive=$ml_archive receipt=$ml_archive/reset-genesis-receipt.json
END phase=host-reset-new-genesis-$ml_alias status=0 timestamp=2026-10-20T11:53:20Z
EOF
jq -n --arg host "$ml_alias" --arg archive "$ml_archive" --arg stamp "$ml_stamp" --arg project "$ml_project" \
  '{schema_version:1,kind:"gdc-new-genesis-reset-receipt",host:$host,
    completed_utc:$stamp,archive:$archive,projects:[$project],
    systemd_units:[{unit:("gdc-poc-winddown-watch@"+$project+".service"),final_state:"inactive"}],
    containers:[{id:"fixture-1",final_state:"exited",restart_policy:"no",legacy_sidecar:false},
      {id:"fixture-2",final_state:"exited",restart_policy:"no",legacy_sidecar:false}],
    moved_paths:[{before:("/srv/dai/deploy/"+$project),after:($archive+"/deploy/"+$project),device_inode:"64770:3801092"}],
    preserved_paths:["/srv/dai/backups","/srv/dai/hf-cache","/srv/hf-cache","/srv/dai/ops","/srv/dai/monitoring-agent"]}' \
  >"$tmp/ml-receipt.json"
export GDC_TEST_ALIAS="$ml_alias" GDC_TEST_RECEIPT="$tmp/ml-receipt.json"
[[ "$(verify_new_genesis_reset_receipt "$ml_alias" "$ml_home")" == true ]]
jq '.moved_paths[0].after = "/srv/dai-archives/elsewhere/deploy/gdc-node4-ml"' \
  "$tmp/ml-receipt.json" >"$tmp/ml-bad-path.json"
export GDC_TEST_RECEIPT="$tmp/ml-bad-path.json"
if verify_new_genesis_reset_receipt "$ml_alias" "$ml_home" >/dev/null; then
  echo 'JOIN reset gate accepted an ML donor receipt with an altered archive path' >&2; exit 1
fi
jq '.containers[0].final_state = "running"' "$tmp/ml-receipt.json" >"$tmp/ml-running.json"
export GDC_TEST_RECEIPT="$tmp/ml-running.json"
if verify_new_genesis_reset_receipt "$ml_alias" "$ml_home" >/dev/null; then
  echo 'JOIN reset gate accepted an ML donor receipt with a running container' >&2; exit 1
fi
export GDC_TEST_RECEIPT="$tmp/ml-receipt.json"

# The rule is role-based and receipt-bound, not a hardcoded node9/node4 pair.
second_ml_alias=gdc-node7
second_ml_project=gdc-node2-ml
second_ml_run=20261020T120520Z-24680
second_ml_stamp=20261020T120520Z
second_ml_archive="/srv/dai-archives/$second_ml_stamp-$second_ml_alias"
second_ml_home="$tmp/operator/$second_ml_alias"
second_ml_run_dir="$second_ml_home/runs/$second_ml_run"
mkdir -p "$second_ml_home/state" "$second_ml_run_dir"
printf '%s\n' "$second_ml_run" >"$second_ml_home/state/active-run-id"
cat >"$second_ml_run_dir/manifest.env" <<EOF
schema_version=2
run_id=$second_ml_run
phase=host-reset-new-genesis-$second_ml_alias
operator_data_home=$second_ml_home
EOF
cat >"$second_ml_run_dir/run.log" <<EOF
BEGIN phase=host-reset-new-genesis-$second_ml_alias timestamp=2026-10-20T12:05:20Z run_id=$second_ml_run
PASS new-Genesis Host reset host=$second_ml_alias archive=$second_ml_archive receipt=$second_ml_archive/reset-genesis-receipt.json
END phase=host-reset-new-genesis-$second_ml_alias status=0 timestamp=2026-10-20T12:05:20Z
EOF
jq --arg host "$second_ml_alias" --arg archive "$second_ml_archive" --arg stamp "$second_ml_stamp" \
  --arg project "$second_ml_project" '.host=$host | .archive=$archive | .completed_utc=$stamp |
    .projects=[$project] | .moved_paths=[{before:("/srv/dai/deploy/"+$project),
      after:($archive+"/deploy/"+$project),device_inode:"64770:3801093"}] |
    .systemd_units=[{unit:("gdc-poc-winddown-watch@"+$project+".service"),final_state:"inactive"}]' \
  "$tmp/ml-receipt.json" >"$tmp/ml-second-receipt.json"
export GDC_TEST_ALIAS="$second_ml_alias" GDC_TEST_RECEIPT="$tmp/ml-second-receipt.json"
[[ "$(verify_new_genesis_reset_receipt "$second_ml_alias" "$second_ml_home")" == true ]]

# Project-looking strings that do not match the exact ML-project grammar, or
# a receipt claiming multiple projects, are not donor-reset evidence.
jq '.projects = ["gdc-edge-node4"]' "$tmp/ml-receipt.json" >"$tmp/ml-lookalike.json"
export GDC_TEST_ALIAS="$ml_alias" GDC_TEST_RECEIPT="$tmp/ml-lookalike.json"
if verify_new_genesis_reset_receipt "$ml_alias" "$ml_home" >/dev/null; then
  echo 'JOIN reset gate accepted a non-ML donor project' >&2; exit 1
fi
jq '.projects += ["gdc-node5-ml"]' "$tmp/ml-receipt.json" >"$tmp/ml-multiple-projects.json"
export GDC_TEST_RECEIPT="$tmp/ml-multiple-projects.json"
if verify_new_genesis_reset_receipt "$ml_alias" "$ml_home" >/dev/null; then
  echo 'JOIN reset gate accepted a multi-project donor receipt' >&2; exit 1
fi

jq '.moved_paths[0].device_inode = "unknown"' "$tmp/ml-receipt.json" >"$tmp/ml-bad-inode.json"
export GDC_TEST_RECEIPT="$tmp/ml-bad-inode.json"
if verify_new_genesis_reset_receipt "$ml_alias" "$ml_home" >/dev/null; then
  echo 'JOIN reset gate accepted donor receipt without a device/inode binding' >&2; exit 1
fi

jq '.host = "gdc-node8"' "$tmp/ml-receipt.json" >"$tmp/ml-wrong-host.json"
export GDC_TEST_RECEIPT="$tmp/ml-wrong-host.json"
if verify_new_genesis_reset_receipt "$ml_alias" "$ml_home" >/dev/null; then
  echo 'JOIN reset gate accepted an ML donor receipt for another Host' >&2; exit 1
fi

export GDC_TEST_ALIAS="$alias_name" GDC_TEST_RECEIPT="$tmp/receipt.json"

jq '.host = "gdc-node8"' "$tmp/receipt.json" >"$tmp/wrong-host.json"
export GDC_TEST_RECEIPT="$tmp/wrong-host.json"
if verify_new_genesis_reset_receipt "$alias_name" "$host_home" >/dev/null; then
  echo 'JOIN reset gate accepted a receipt for a different Host' >&2; exit 1
fi
jq '.projects = ["gdc-node4-ml"]' "$tmp/receipt.json" >"$tmp/ml-only.json"
export GDC_TEST_RECEIPT="$tmp/ml-only.json"
if verify_new_genesis_reset_receipt "$alias_name" "$host_home" >/dev/null; then
  echo 'JOIN reset gate accepted an ML-only reset receipt' >&2; exit 1
fi
export GDC_TEST_RECEIPT="$tmp/receipt.json"
export GDC_TEST_ALIAS="$alias_name"

sed -i '/^END phase=/d' "$run_dir/run.log"
if verify_new_genesis_reset_receipt "$alias_name" "$host_home" >/dev/null; then
  echo 'JOIN reset gate accepted a reset log without successful END status' >&2; exit 1
fi
printf 'END phase=host-reset-new-genesis-%s status=0 timestamp=2026-10-20T11:43:53Z\n' "$alias_name" >>"$run_dir/run.log"

mkdir -p "$host_home/state/identities"
printf '{}\n' >"$host_home/state/identities/$alias_name.json"
if verify_new_genesis_reset_receipt "$alias_name" "$host_home" >/dev/null; then
  echo 'JOIN reset gate accepted retained local identity state' >&2; exit 1
fi
[[ "$(verify_new_genesis_reset_receipt "$alias_name" "$host_home" allow-partial-identity)" == true ]]

# The reset command archives the retained public identity/account only after
# remote receipt readback. Cold mnemonic/address/keyring recovery material is
# deliberately kept coherent for the next JOIN; new warm/validator identity
# is generated by the normal identity bootstrap path.
mkdir -p "$host_home/accounts" "$host_home/mnemonics" "$host_home/state/secrets"
printf '{"node_id":"0123456789abcdef0123456789abcdef01234567"}\n' >"$host_home/state/identities/$alias_name.json"
printf '{"address":"gonka1fixtureparticipant"}\n' >"$host_home/accounts/$alias_name-cold.json"
printf 'fixture cold mnemonic sentinel\n' >"$host_home/mnemonics/$alias_name-cold.mnemonic"
printf 'fixture cold address sentinel\n' >"$host_home/mnemonics/$alias_name-cold.address"
printf 'fixture keyring sentinel\n' >"$host_home/state/secrets/$alias_name.keyring"
chmod 0600 "$host_home/state/identities/$alias_name.json" "$host_home/accounts/$alias_name-cold.json" \
  "$host_home/mnemonics/$alias_name-cold.mnemonic" "$host_home/mnemonics/$alias_name-cold.address" \
  "$host_home/state/secrets/$alias_name.keyring"
identity_sha="$(sha256sum "$host_home/state/identities/$alias_name.json" | awk '{print $1}')"
account_sha="$(sha256sum "$host_home/accounts/$alias_name-cold.json" | awk '{print $1}')"
cold_mnemonic_sha="$(sha256sum "$host_home/mnemonics/$alias_name-cold.mnemonic" | awk '{print $1}')"
cold_address_sha="$(sha256sum "$host_home/mnemonics/$alias_name-cold.address" | awk '{print $1}')"
keyring_sha="$(sha256sum "$host_home/state/secrets/$alias_name.keyring" | awk '{print $1}')"
archive_new_genesis_local_identity "$alias_name" "$host_home" "$run_id" >/dev/null
[[ ! -e "$host_home/state/identities/$alias_name.json" && ! -e "$host_home/accounts/$alias_name-cold.json" ]]
[[ "$(sha256sum "$run_dir/local-reset-state/identity.json" | awk '{print $1}')" == "$identity_sha" ]]
[[ "$(sha256sum "$run_dir/local-reset-state/account.json" | awk '{print $1}')" == "$account_sha" ]]
[[ "$(stat -c %a "$run_dir/local-reset-state/identity.json")" == 600 \
  && "$(stat -c %a "$run_dir/local-reset-state/account.json")" == 600 \
  && "$(stat -c %a "$run_dir/local-reset-state")" == 700 \
  && "$(stat -c %a "$run_dir/local-reset-state/receipt.json")" == 600 ]]
[[ "$(sha256sum "$host_home/mnemonics/$alias_name-cold.mnemonic" | awk '{print $1}')" == "$cold_mnemonic_sha" ]]
[[ "$(sha256sum "$host_home/mnemonics/$alias_name-cold.address" | awk '{print $1}')" == "$cold_address_sha" ]]
[[ "$(sha256sum "$host_home/state/secrets/$alias_name.keyring" | awk '{print $1}')" == "$keyring_sha" ]]
[[ "$(verify_new_genesis_reset_receipt "$alias_name" "$host_home")" == true ]]
if archive_new_genesis_local_identity "$alias_name" "$host_home" "$run_id" >/dev/null 2>&1; then
  echo 'local reset archive unexpectedly overwrote the existing archive path' >&2; exit 1
fi

# A fresh reset state still gets an explicit empty local archive receipt.
fresh_home="$tmp/operator-fresh/$alias_name"
fresh_run=20261020T120001Z-12345
fresh_run_dir="$fresh_home/runs/$fresh_run"
mkdir -p "$fresh_home/state" "$fresh_run_dir"
printf '%s\n' "$fresh_run" >"$fresh_home/state/active-run-id"
cat >"$fresh_run_dir/manifest.env" <<EOF
schema_version=2
run_id=$fresh_run
phase=host-reset-new-genesis-$alias_name
operator_data_home=$fresh_home
EOF
cat >"$fresh_run_dir/run.log" <<EOF
BEGIN phase=host-reset-new-genesis-$alias_name timestamp=2026-10-20T12:00:01Z run_id=$fresh_run
PASS new-Genesis Host reset host=$alias_name archive=$archive receipt=$receipt_path
END phase=host-reset-new-genesis-$alias_name status=0 timestamp=2026-10-20T12:00:01Z
EOF
archive_new_genesis_local_identity "$alias_name" "$fresh_home" "$fresh_run" >/dev/null
jq -e --arg host "$alias_name" --arg run "$fresh_run" \
  '.kind == "gdc-new-genesis-local-reset-state" and .host == $host and .reset_run_id == $run and .files == []' \
  "$fresh_run_dir/local-reset-state/receipt.json" >/dev/null

# Joined-marker state is not a stale identity pair and must remain untouched.
joined_home="$tmp/operator-joined/$alias_name"
joined_run_dir="$joined_home/runs/$fresh_run"
mkdir -p "$joined_home/state/active" "$joined_home/state/identities" "$joined_home/accounts" \
  "$joined_home/state/joined" "$joined_run_dir"
printf '%s\n' "$fresh_run" >"$joined_home/state/active-run-id"
cat >"$joined_run_dir/manifest.env" <<EOF
schema_version=2
run_id=$fresh_run
phase=host-reset-new-genesis-$alias_name
operator_data_home=$joined_home
EOF
cat >"$joined_run_dir/run.log" <<EOF
BEGIN phase=host-reset-new-genesis-$alias_name timestamp=2026-10-20T12:00:01Z run_id=$fresh_run
PASS new-Genesis Host reset host=$alias_name archive=$archive receipt=$receipt_path
END phase=host-reset-new-genesis-$alias_name status=0 timestamp=2026-10-20T12:00:01Z
EOF
printf '{"node_id":"0123456789abcdef0123456789abcdef01234567"}\n' >"$joined_home/state/identities/$alias_name.json"
printf '{"address":"gonka1fixtureparticipant"}\n' >"$joined_home/accounts/$alias_name-cold.json"
: >"$joined_home/state/joined/$alias_name"
rm -f "$GDC_TEST_SSH_CALLS"
if archive_new_genesis_local_identity "$alias_name" "$joined_home" "$fresh_run" >/dev/null 2>&1; then
  echo 'local reset archive accepted a retained joined marker' >&2; exit 1
fi
[[ -f "$joined_home/state/identities/$alias_name.json" && -f "$joined_home/accounts/$alias_name-cold.json" ]]
[[ ! -e "$GDC_TEST_SSH_CALLS" && ! -e "$joined_run_dir/local-reset-state" ]]

sed -i 's/^phase=.*/phase=host-reset-other/' "$run_dir/manifest.env"
rm -f "$GDC_TEST_SSH_CALLS"
if verify_new_genesis_reset_receipt "$alias_name" "$host_home" >/dev/null; then
  echo 'JOIN reset gate accepted a receipt bound to another lifecycle phase' >&2; exit 1
fi
[[ ! -e "$GDC_TEST_SSH_CALLS" ]] || { echo 'unbound reset manifest triggered remote receipt access' >&2; exit 1; }

echo 'PASS new-Genesis reset receipt JOIN gate'
