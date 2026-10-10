#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$JOIN_SSH_LOG"
cat >/dev/null
if [[ "${READINESS_RESULT:?}" == target_not_clean && "$(wc -l <"$JOIN_SSH_LOG")" -eq 2 ]]; then
  printf 'JOIN_TARGET_NOT_CLEAN retained_host_preparation=/etc/gonka/host.env\n'
  exit 196
fi
case "${READINESS_RESULT:?}" in
  reboot) printf 'REBOOT_REQUIRED pending_host_package_updates\n'; exit 194 ;;
  action) printf 'OPERATOR_ACTION_REQUIRED package_manager_unresolved\n'; exit 195 ;;
  target_not_clean) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod 0755 "$tmp/bin/ssh"

cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'network access must not follow a failed Host readiness check' >&2
exit 97
EOF
chmod 0755 "$tmp/bin/curl"

run_case() {
  local name="$1" expected_rc="$2" operator rc result
  operator="$tmp/$name-operator"
  if READINESS_RESULT="$name" JOIN_SSH_LOG="$tmp/$name.ssh" PATH="$tmp/bin:$PATH" GDC_HOME="$operator" \
    "$ROOT/gdc.sh" host join --public-host validator.example.test validator-a >"$tmp/$name.out" 2>"$tmp/$name.err"; then
    echo "$name readiness check unexpectedly continued JOIN" >&2
    exit 1
  else
    rc=$?
  fi
  [[ "$rc" -eq "$expected_rc" ]]
  result="$(find "$operator" -path '*/join-validator-a/join-result.v1.json' -type f -print -quit)"
  [[ -n "$result" ]]
  jq -e --argjson rc "$expected_rc" '
    .outcome == "refused" and .phase == "profile" and .category == "host" and
    .reason == "join_preflight_failed" and .exit_code == $rc and
    .mutation == "none" and .signer_state == "absent" and .resume == "new_profile"
  ' "$result" >/dev/null
}

run_case reboot 194 REBOOT_REQUIRED
run_case action 195 OPERATOR_ACTION_REQUIRED

operator="$tmp/target-not-clean-operator"
if READINESS_RESULT=target_not_clean JOIN_SSH_LOG="$tmp/target-not-clean.ssh" PATH="$tmp/bin:$PATH" GDC_HOME="$operator" \
  "$ROOT/gdc.sh" host join --public-host validator.example.test validator-a >"$tmp/target-not-clean.out" 2>"$tmp/target-not-clean.err"; then
  echo 'non-clean target unexpectedly continued JOIN' >&2
  exit 1
else
  rc=$?
fi
[[ "$rc" -eq 196 ]]
[[ "$(<"$tmp/target-not-clean.err")" == 'JOIN cannot continue because the Host retains state from an earlier GDC preparation' ]]
[[ ! -e "$operator/reporting/failures/latest-failure" ]]
result="$(find "$operator" -path '*/join-validator-a/join-result.v1.json' -type f -print -quit)"
[[ -n "$result" ]]
jq -e '
  .outcome == "refused" and .phase == "profile" and .category == "host" and
  .reason == "join_preflight_failed" and .exit_code == 196 and
  .mutation == "none" and .signer_state == "absent" and .resume == "new_profile"
' "$result" >/dev/null

printf 'PASS JOIN stops on known Host readiness prerequisites before network observation\n'
